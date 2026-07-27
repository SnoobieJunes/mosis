package screencast

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"sync"
	"time"

	"github.com/auston/conduit-core/session"
	"github.com/auston/conduit-core/wire"
)

// Source is the source side of screen sharing for the Go daemon: on a
// viewer's SCREEN_REQUEST it captures the screen, encodes H.264 through
// ffmpeg, and streams SCREEN_FRAMEs — semantics matched to ScreenSourceEngine
// (Swift), which is the reference:
//
//   - Frames start on the SESSION link immediately (the lane that already
//     proved itself carrying the request), at a bitrate low enough not to
//     starve the keepalives riding the same connection.
//   - The dedicated reverse-dialed lane is a background UPGRADE, promoted at
//     a keyframe boundary; its failure costs quality, never the stream. This
//     is the loop 1–4 lesson: the reverse dial is the seam that fails on real
//     networks, so nothing may wait on it.
//   - Viewer SCREEN_ACKs drive keyframe recovery and (coarsely) bitrate.
//
// Where this deliberately diverges from Swift (docs/plans/09 has the full
// list): one viewer at a time (a second request is refused, like Android);
// bitrate changes and on-demand keyframes are rate-limited encoder RESTARTS
// (the ffmpeg-CLI tax — see Encoder); consent is standing for paired peers,
// matching the daemon's existing file/input posture, because a headless
// process has no screen to put a picker on.
type SourceConfig struct {
	FFmpegPath string
	Capturer   Capturer
	// MaxFPS caps the offered frame rate (default 30 — libx264 on unknown
	// CPUs; the Swift side offers 60 with hardware encode).
	MaxFPS int
	// DisableBulkLane keeps frames on the session link forever — the
	// control-lane fallback path, forced for tests.
	DisableBulkLane bool
	Log             func(string)
}

const (
	controlLaneBitrate = 2_500_000
	bulkLaneBitrate    = 8_000_000
	minBitrate         = 1_000_000
	maxLagFrames       = uint32(45)
	// Encoder restarts are the only lever ffmpeg-CLI gives us, so they are
	// rate-limited hard: keyframe requests at most 1/s, bitrate steps 1/5s.
	keyframeRestartMinGap = time.Second
	bitrateChangeMinGap   = 5 * time.Second
	bulkDialBudget        = 6 * time.Second
)

type Source struct {
	node *session.Node
	cfg  SourceConfig

	mu       sync.Mutex
	active   *sourcing
	nextWire uint16
}

type sourcing struct {
	link   *session.Link
	peerID string
	offer  wire.ScreenOfferBody
	fps    int

	enc     *Encoder
	feed    chan capturedFrame
	stopCh  chan struct{}
	stopped bool

	bulk            *session.FramedConn // promoted dedicated lane
	pendingBulk     *session.FramedConn // attached, waiting for a keyframe
	usesControlLane bool

	sentSeq        uint32
	bitrate        int
	lastKeyRestart time.Time
	lastRateChange time.Time
}

type capturedFrame struct {
	data []byte
	pts  uint64
}

func NewSource(node *session.Node, cfg SourceConfig) *Source {
	if cfg.MaxFPS <= 0 {
		cfg.MaxFPS = 30
	}
	if cfg.Log == nil {
		cfg.Log = func(string) {}
	}
	return &Source{node: node, cfg: cfg, nextWire: 1}
}

func (s *Source) logf(format string, args ...interface{}) {
	s.cfg.Log(fmt.Sprintf(format, args...))
}

// Lane names the lane currently carrying frames ("control", "bulk", "none") —
// for the status line, and for tests to assert honestly (a green test that
// doesn't check the lane proves nothing about the lane; loop-state.md).
func (s *Source) Lane() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case s.active == nil:
		return "none"
	case s.active.bulk != nil:
		return "bulk"
	case s.active.usesControlLane:
		return "control"
	default:
		return "none"
	}
}

// HandleRequest serves a viewer's SCREEN_REQUEST. Call from a goroutine —
// capture/encoder startup takes ~100 ms and must not block the link's reads.
func (s *Source) HandleRequest(deviceID string, req wire.ScreenRequestBody, l *session.Link) {
	reject := func(reason string) {
		_ = l.Send(wire.Message{Type: wire.TypeScreenReject, Body: wire.ScreenRejectBody{Reason: reason}})
		s.logf("screen request from %s rejected: %s", deviceID, reason)
	}

	s.mu.Lock()
	if s.active != nil && s.active.peerID != deviceID {
		s.mu.Unlock()
		reject("already sharing to another peer")
		return
	}
	current := s.active
	s.mu.Unlock()
	if current != nil {
		// The current viewer asking again means "restart with these params" —
		// end the old session cleanly (nil reason: not a failure) and rebuild.
		s.stopSharing(current, nil, true)
	}

	if ok, reason := s.cfg.Capturer.Available(); !ok {
		reject("cannot capture here: " + reason)
		return
	}
	if s.cfg.FFmpegPath == "" {
		reject("no encoder: ffmpeg is not available on the source")
		return
	}
	if !codecListAccepts(req.Codecs, "h264") {
		reject("source only encodes h264")
		return
	}
	src, err := s.cfg.Capturer.Source()
	if err != nil {
		reject("cannot enumerate the screen: " + err.Error())
		return
	}

	maxW, maxH := src.Width, src.Height
	if req.MaxWidth != nil && *req.MaxWidth > 0 {
		maxW = *req.MaxWidth
	}
	if req.MaxHeight != nil && *req.MaxHeight > 0 {
		maxH = *req.MaxHeight
	}
	outW, outH := fit(src.Width, src.Height, maxW, maxH)
	fps := s.cfg.MaxFPS
	if req.MaxFps != nil && *req.MaxFps > 0 && *req.MaxFps < fps {
		fps = *req.MaxFps
	}

	enc, err := StartEncoder(EncoderConfig{
		FFmpegPath: s.cfg.FFmpegPath,
		InputWidth: src.Width, InputHeight: src.Height,
		InputPixFmt: s.cfg.Capturer.PixelFormat(),
		OutputWidth: outW, OutputHeight: outH,
		FPS: fps, BitrateBps: controlLaneBitrate,
	})
	if err != nil {
		reject("encoder start failed: " + err.Error())
		return
	}

	s.mu.Lock()
	wireID := s.nextWire
	s.nextWire++
	st := &sourcing{
		link: l, peerID: deviceID, fps: fps,
		enc:    enc,
		feed:   make(chan capturedFrame, 1),
		stopCh: make(chan struct{}),
		// Frames ride the session link from the first one; the dedicated
		// lane is an upgrade (see the type comment).
		usesControlLane: true,
		bitrate:         controlLaneBitrate,
		// The brand-new encoder's first output IS a keyframe; suppress the
		// keyframe-request restart the viewer's join ack would trigger.
		lastKeyRestart: time.Now(),
	}
	st.offer = wire.ScreenOfferBody{
		ScreenSessionID: randomID(),
		WireSessionID:   wireID,
		Codec:           "h264",
		Width:           outW, Height: outH, Fps: fps,
		CaptureKind: src.Kind,
		SourceName:  src.Name,
		BulkToken:   randomID(),
	}
	s.active = st
	s.mu.Unlock()

	// Capture → drop-oldest feed → encoder. The feed depth of 1 is the
	// drop-under-load policy: a slow encoder loses frames, never gains latency.
	if err := s.cfg.Capturer.Start(CaptureConfig{FPS: fps}, func(frame []byte, pts uint64) {
		buf := append([]byte(nil), frame...)
		select {
		case st.feed <- capturedFrame{buf, pts}:
		default:
			select {
			case <-st.feed:
			default:
			}
			select {
			case st.feed <- capturedFrame{buf, pts}:
			default:
			}
		}
	}); err != nil {
		enc.Stop()
		s.mu.Lock()
		s.active = nil
		s.mu.Unlock()
		reject("capture start failed: " + err.Error())
		return
	}

	if err := l.Send(wire.Message{Type: wire.TypeScreenOffer, Body: st.offer}); err != nil {
		s.stopSharing(st, strPtr("offer send failed"), false)
		return
	}
	s.logf("sharing %s (%dx%d@%d h264) to %s on the session link",
		st.offer.SourceName, outW, outH, fps, deviceID)

	go s.runFeeder(st)
	go s.runSender(st)
	if !s.cfg.DisableBulkLane {
		go s.attemptBulkUpgrade(st)
	}
}

func (s *Source) runFeeder(st *sourcing) {
	for {
		select {
		case <-st.stopCh:
			return
		case f := <-st.feed:
			s.mu.Lock()
			enc := st.enc
			s.mu.Unlock()
			// A write error here is almost always the encoder mid-restart
			// (stdin closed under us); the frame is dropped and the next one
			// lands in the new process. A dead-for-real encoder surfaces in
			// the sender when its frame channel closes with an Err.
			_ = enc.WriteFrame(f.data, f.pts)
		}
	}
}

func (s *Source) runSender(st *sourcing) {
	var lastCh <-chan EncodedAU
	for {
		s.mu.Lock()
		if s.active != st || st.stopped {
			s.mu.Unlock()
			return
		}
		ch := st.enc.Frames()
		encErr := st.enc.Err()
		s.mu.Unlock()
		if ch == lastCh {
			// The channel that just closed is still the current encoder: it
			// died rather than being restarted. End with the real reason —
			// never freeze the viewer silently.
			reason := "encoder exited"
			if encErr != nil {
				reason = "encoder failed: " + encErr.Error()
			}
			s.stopSharing(st, &reason, true)
			return
		}
		for au := range ch {
			if !s.sendAU(st, au) {
				return
			}
		}
		lastCh = ch
	}
}

// sendAU ships one access unit; false ends the sender.
func (s *Source) sendAU(st *sourcing, au EncodedAU) bool {
	packed := wire.PackScreenFrame(au.Frame)
	if len(packed) > wire.MaxScreenData {
		// Can't ship it (the peer's frame reader would kill the connection).
		// Dropping breaks the GOP, so schedule a keyframe to repair.
		s.logf("dropping oversized frame (%d bytes > %d); requesting keyframe", len(packed), wire.MaxScreenData)
		s.maybeKeyframeRestart(st)
		return true
	}

	s.mu.Lock()
	if s.active != st || st.stopped {
		s.mu.Unlock()
		return false
	}
	// Promote a dialed-and-attached lane at a keyframe so the viewer never
	// decodes across two connections mid-GOP.
	if st.pendingBulk != nil && au.Frame.IsKeyframe {
		st.bulk = st.pendingBulk
		st.pendingBulk = nil
		st.usesControlLane = false
		s.mu.Unlock()
		s.logf("screen frames now on the direct lane")
		s.restartEncoder(st, bulkLaneBitrate)
		s.mu.Lock()
		if s.active != st || st.stopped {
			s.mu.Unlock()
			return false
		}
	}
	seq := st.sentSeq
	st.sentSeq++
	bulk := st.bulk
	frame := wire.ScreenFrame{
		SessionID:  st.offer.WireSessionID,
		Seq:        seq,
		IsKeyframe: au.Frame.IsKeyframe,
		PtsMillis:  au.PtsMillis,
		Data:       packed,
	}
	s.mu.Unlock()

	var err error
	if bulk != nil {
		err = bulk.SendScreen(frame)
	} else {
		err = st.link.SendScreenFrame(frame)
	}
	if err != nil {
		if bulk != nil {
			// The dedicated lane died; the session link is still there.
			// Demote — quality drops, the stream survives.
			s.demoteToControlLane(st, err.Error())
			return true
		}
		reason := "frame send failed: " + err.Error()
		s.stopSharing(st, &reason, false)
		return false
	}
	return true
}

// attemptBulkUpgrade reverse-dials the viewer's listener in the background.
func (s *Source) attemptBulkUpgrade(st *sourcing) {
	remote := st.link.Remote()
	host := st.link.RemoteHost()
	if remote.ListenPort == nil || host == "" {
		s.logf("no reachable viewer listener; staying on the session link")
		return
	}
	type dialResult struct {
		conn *session.FramedConn
		err  error
	}
	ch := make(chan dialResult, 1)
	go func() {
		conn, err := s.node.OpenLane(st.link.Peer(), host, *remote.ListenPort)
		ch <- dialResult{conn, err}
	}()
	var conn *session.FramedConn
	select {
	case r := <-ch:
		if r.err != nil {
			s.logf("no direct lane (%v); staying on the session link", r.err)
			return
		}
		conn = r.conn
	case <-time.After(bulkDialBudget):
		// Reclaim a connection that lands after the budget — nothing else
		// would close it (the leak the Swift side shipped and then fixed).
		go func() {
			if r := <-ch; r.conn != nil {
				r.conn.Close()
			}
		}()
		s.logf("direct-lane dial exceeded %s; staying on the session link", bulkDialBudget)
		return
	}
	if err := conn.Send(wire.Message{Type: wire.TypeScreenAttach, Body: wire.ScreenAttachBody{
		ScreenSessionID: st.offer.ScreenSessionID, BulkToken: st.offer.BulkToken,
	}}); err != nil {
		conn.Close()
		s.logf("direct lane attach failed (%v); staying on the session link", err)
		return
	}
	s.mu.Lock()
	if s.active != st || st.stopped {
		s.mu.Unlock()
		conn.Close()
		return
	}
	st.pendingBulk = conn
	s.mu.Unlock()
	go s.readLaneAcks(st, conn)
	// Promote at a clean boundary: force the keyframe the switch waits for.
	s.maybeKeyframeRestart(st)
	s.logf("direct screen lane up; switching at the next keyframe")
}

// readLaneAcks drains the dedicated lane: SCREEN_ACKs feed the adaptive loop,
// SCREEN_END ends the share, EOF demotes (or discards a never-promoted lane).
func (s *Source) readLaneAcks(st *sourcing, conn *session.FramedConn) {
	for {
		frame, ok, err := conn.NextFrame()
		if err != nil || !ok {
			break
		}
		if frame.Kind != wire.KindControl {
			continue
		}
		_, msg, err := wire.DecodeMessage(frame.Control)
		if err != nil {
			continue
		}
		switch msg.Type {
		case wire.TypeScreenAck:
			s.HandleAck(st.peerID, msg.Body.(wire.ScreenAckBody))
		case wire.TypeScreenEnd:
			s.HandleEnd(st.peerID, msg.Body.(wire.ScreenEndBody))
			return
		}
	}
	// Lane closed without an END.
	s.mu.Lock()
	if s.active != st || st.stopped {
		s.mu.Unlock()
		return
	}
	wasPending := st.pendingBulk == conn
	wasLive := st.bulk == conn
	if wasPending {
		st.pendingBulk = nil
	}
	s.mu.Unlock()
	conn.Close()
	if wasLive {
		s.demoteToControlLane(st, "lane closed")
	} else if wasPending {
		s.logf("direct lane closed before it carried frames; staying on the session link")
	}
}

func (s *Source) demoteToControlLane(st *sourcing, why string) {
	s.mu.Lock()
	if s.active != st || st.stopped || st.bulk == nil {
		s.mu.Unlock()
		return
	}
	old := st.bulk
	st.bulk = nil
	st.usesControlLane = true
	s.mu.Unlock()
	old.Close()
	s.logf("direct lane failed mid-stream (%s); falling back to the session link", why)
	// Back to the shared-lane ceiling, with the fresh keyframe a restart brings.
	s.restartEncoder(st, controlLaneBitrate)
}

// HandleAck processes viewer feedback from either lane.
func (s *Source) HandleAck(deviceID string, ack wire.ScreenAckBody) {
	s.mu.Lock()
	st := s.active
	if st == nil || st.stopped || st.peerID != deviceID || st.offer.ScreenSessionID != ack.ScreenSessionID {
		s.mu.Unlock()
		return
	}
	lag := st.sentSeq - ack.AckedSeq // wrapping arithmetic is fine here
	needKey := ack.RequestKeyframe
	needSlowdown := lag > maxLagFrames && lag < 1<<31 &&
		time.Since(st.lastRateChange) > bitrateChangeMinGap && st.bitrate > minBitrate
	var newRate int
	if needSlowdown {
		newRate = st.bitrate * 3 / 4
		if newRate < minBitrate {
			newRate = minBitrate
		}
		st.lastRateChange = time.Now()
	}
	s.mu.Unlock()

	if needSlowdown {
		s.logf("viewer %d frames behind; stepping bitrate down to %d kbps", lag, newRate/1000)
		s.restartEncoder(st, newRate) // restart emits a fresh keyframe too
	} else if needKey {
		s.maybeKeyframeRestart(st)
	}
}

// HandleEnd: the viewer ended the share.
func (s *Source) HandleEnd(deviceID string, body wire.ScreenEndBody) {
	s.mu.Lock()
	st := s.active
	s.mu.Unlock()
	if st == nil || st.peerID != deviceID || st.offer.ScreenSessionID != body.ScreenSessionID {
		return
	}
	s.stopSharing(st, nil, false)
}

// HandleSessionClosed: the peer's session dropped; tear down without
// signalling into the void.
func (s *Source) HandleSessionClosed(deviceID string) {
	s.mu.Lock()
	st := s.active
	s.mu.Unlock()
	if st == nil || st.peerID != deviceID {
		return
	}
	s.stopSharing(st, nil, false)
}

// Stop ends any active share (daemon shutdown).
func (s *Source) Stop() {
	s.mu.Lock()
	st := s.active
	s.mu.Unlock()
	if st != nil {
		s.stopSharing(st, nil, true)
	}
}

// maybeKeyframeRestart forces an IDR by restarting ffmpeg, rate-limited.
// With the ≤2 s GOP as the floor, the worst case for an unlucky joiner is
// one GOP; this makes the common case (join, glitch recovery, lane
// promotion) near-immediate.
func (s *Source) maybeKeyframeRestart(st *sourcing) {
	s.mu.Lock()
	if s.active != st || st.stopped || time.Since(st.lastKeyRestart) < keyframeRestartMinGap {
		s.mu.Unlock()
		return
	}
	st.lastKeyRestart = time.Now()
	rate := st.bitrate
	s.mu.Unlock()
	s.restartEncoder(st, rate)
}

// restartEncoder swaps in a fresh ffmpeg at the given bitrate. The new
// process's first output is an IDR with fresh SPS/PPS, so this doubles as
// "force keyframe". Costs a ~50–200 ms encode gap; both callers are
// rate-limited.
func (s *Source) restartEncoder(st *sourcing, bitrate int) {
	s.mu.Lock()
	if s.active != st || st.stopped {
		s.mu.Unlock()
		return
	}
	old := st.enc
	cfg := old.cfg
	cfg.BitrateBps = bitrate
	s.mu.Unlock()

	// Start the replacement before stopping the old one so the feeder's
	// window of dropped frames is as small as the spawn.
	fresh, err := StartEncoder(cfg)
	s.mu.Lock()
	if err != nil || s.active != st || st.stopped {
		s.mu.Unlock()
		if err == nil {
			fresh.Stop()
		} else {
			reason := "encoder restart failed: " + err.Error()
			s.stopSharing(st, &reason, true)
		}
		return
	}
	st.enc = fresh
	st.bitrate = bitrate
	st.lastKeyRestart = time.Now()
	s.mu.Unlock()
	old.Stop() // sender drains its remaining AUs, then hops to the new channel
}

// stopSharing tears the share down. notify sends SCREEN_END to the viewer on
// the session link (the lane that still exists when the dedicated one never
// came up — the blank-screen lesson) and on the bulk lane when there is one.
// reason nil = clean stop; non-nil = failure the viewer may surface.
func (s *Source) stopSharing(st *sourcing, reason *string, notify bool) {
	s.mu.Lock()
	if st.stopped {
		s.mu.Unlock()
		return
	}
	st.stopped = true
	close(st.stopCh)
	if s.active == st {
		s.active = nil
	}
	bulk, pending := st.bulk, st.pendingBulk
	st.bulk, st.pendingBulk = nil, nil
	enc := st.enc
	s.mu.Unlock()

	s.cfg.Capturer.Stop()
	enc.Stop()
	if notify {
		end := wire.Message{Type: wire.TypeScreenEnd, Body: wire.ScreenEndBody{
			ScreenSessionID: st.offer.ScreenSessionID, Reason: reason}}
		_ = st.link.Send(end)
		if bulk != nil {
			_ = bulk.Send(end)
		}
	}
	if bulk != nil {
		bulk.Close()
	}
	if pending != nil {
		pending.Close()
	}
	if reason != nil {
		s.logf("screen share ended: %s", *reason)
	} else {
		s.logf("screen share ended")
	}
}

// ---- helpers ----

func codecListAccepts(codecs []string, want string) bool {
	if len(codecs) == 0 {
		return true // an empty list constrains nothing
	}
	for _, c := range codecs {
		if c == want {
			return true
		}
	}
	return false
}

// fit scales source dimensions into max bounds without upscaling, rounded to
// even (H.264 requirement) — a port of ScreenSourceEngine.fit.
func fit(sourceW, sourceH, maxW, maxH int) (int, int) {
	scale := 1.0
	if sw := float64(maxW) / float64(sourceW); sw < scale {
		scale = sw
	}
	if sh := float64(maxH) / float64(sourceH); sh < scale {
		scale = sh
	}
	even := func(v float64) int {
		n := int(v/2+0.5) * 2
		if n < 2 {
			return 2
		}
		return n
	}
	return even(float64(sourceW) * scale), even(float64(sourceH) * scale)
}

func randomID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func strPtr(s string) *string { return &s }
