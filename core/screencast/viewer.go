package screencast

import (
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/auston/conduit-core/session"
	"github.com/auston/conduit-core/wire"
)

// UIEventKind labels events from the viewer window.
type UIEventKind int

const (
	UIMotion UIEventKind = iota
	UIButtonDown
	UIButtonUp
	UIWheel
	UIKeyDown
	UIKeyUp
	UIResize
	UIClosed
)

// UIEvent is one input/window event, in X11 vocabulary (buttons 1/2/3 =
// left/middle/right; keysym columns as delivered by the keyboard mapping).
type UIEvent struct {
	Kind                           UIEventKind
	X, Y                           float64 // pointer position, window coords
	W, H                           float64 // window size (UIResize)
	Button                         int
	WheelDX, WheelDY               float64
	KeysymUnshifted, KeysymShifted uint32
	Modifiers                      uint16 // X state mask
}

// Window is the platform render+input surface. X11 on Linux; tests use a
// fake. Blit receives stream-sized BGRA frames.
type Window interface {
	Open(width, height int, title string) error
	Blit(bgra []byte, w, h int) error
	Events() <-chan UIEvent
	Close()
}

// Viewer is the viewer+controller side: request a peer's screen, decode into
// a window, feed SCREEN_ACKs back, and translate window input into wire
// INPUT_EVENTs (with ADR 0015 absolute coordinates alongside deltas).
//
// Lane behaviour matches the Swift/Android viewers: the source may stream on
// the session link (every source's fallback, Android's only mode) or
// reverse-dial a dedicated lane whose first frame is SCREEN_ATTACH — both are
// accepted, and acks return on whichever lane the frames used.
type ViewerConfig struct {
	FFmpegPath string
	Window     Window
	MaxWidth   int // request ceiling; 0 = don't constrain
	MaxHeight  int
	MaxFPS     int
	// EnableInput asks for control (INPUT_REQUEST) once video is up.
	EnableInput bool
	Log         func(string)
}

const (
	viewerAckInterval = 10 // frames per SCREEN_ACK, matching Swift/Kotlin
	// No decodable video within this window after the request → dead share.
	// Generous like Swift's 45 s (first-run permission prompts on the source).
	viewerStartTimeout = 45 * time.Second
	// An attached stream silent this long is dead (black-holed lane).
	viewerStallTimeout = 15 * time.Second
	wheelStepPixels    = 40.0
)

type Viewer struct {
	node *session.Node
	cfg  ViewerConfig

	mu          sync.Mutex
	link        *session.Link
	peerID      string
	offer       *wire.ScreenOfferBody
	dec         *Decoder
	bulk        *session.FramedConn
	attached    bool
	usesControl bool
	highestSeq  uint32
	sinceAck    int
	lastFrameAt time.Time
	startedAt   time.Time
	gotFrame    bool
	blitCount   int

	// Input state.
	controlling  bool
	coal         *Coalescer
	containerW   float64
	containerH   float64
	lastNX       float64
	lastNY       float64
	haveLast     bool
	secureInput  bool
	finishOnce   sync.Once
	done         chan struct{}
	finishReason error
	stopWatch    chan struct{}
}

func NewViewer(node *session.Node, cfg ViewerConfig) *Viewer {
	if cfg.Log == nil {
		cfg.Log = func(string) {}
	}
	return &Viewer{node: node, cfg: cfg, done: make(chan struct{}), stopWatch: make(chan struct{})}
}

func (v *Viewer) logf(format string, args ...interface{}) {
	v.cfg.Log(fmt.Sprintf(format, args...))
}

// Start sends the SCREEN_REQUEST on an established link. The caller must have
// wired this viewer into the node's handlers (HandleOffer etc.) first.
func (v *Viewer) Start(l *session.Link) error {
	if !l.HasCapabilityRemote(wire.CapScreenSource) {
		return fmt.Errorf("%s does not advertise screen-source", l.Peer().Name)
	}
	v.mu.Lock()
	v.link = l
	v.peerID = l.Peer().DeviceID
	v.startedAt = time.Now()
	v.mu.Unlock()

	req := wire.ScreenRequestBody{Codecs: []string{"h264"}}
	// Advertise hevc decode only if this ffmpeg really has it.
	for _, c := range DecoderCodecs(v.cfg.FFmpegPath) {
		if c == "hevc" {
			req.Codecs = append(req.Codecs, "hevc")
		}
	}
	if v.cfg.MaxWidth > 0 {
		req.MaxWidth = &v.cfg.MaxWidth
	}
	if v.cfg.MaxHeight > 0 {
		req.MaxHeight = &v.cfg.MaxHeight
	}
	if v.cfg.MaxFPS > 0 {
		req.MaxFps = &v.cfg.MaxFPS
	}
	if err := l.Send(wire.Message{Type: wire.TypeScreenRequest, Body: req}); err != nil {
		return err
	}
	go v.watchdog()
	return nil
}

// Wait blocks until the viewing session ends; nil for a clean end.
func (v *Viewer) Wait() error {
	<-v.done
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.finishReason
}

// BlitCount reports frames drawn — the honest "is video actually flowing"
// number (a green session with zero blits is a black window).
func (v *Viewer) BlitCount() int {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.blitCount
}

// Controlling reports whether an input grant is live.
func (v *Viewer) Controlling() bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.controlling
}

// Lane reports which lane frames are arriving on, for status and tests.
func (v *Viewer) Lane() string {
	v.mu.Lock()
	defer v.mu.Unlock()
	switch {
	case !v.attached:
		return "none"
	case v.usesControl:
		return "control"
	default:
		return "bulk"
	}
}

// HandleOffer: the source accepted (or pushed an unsolicited share, which the
// iOS broadcast path does).
func (v *Viewer) HandleOffer(deviceID string, offer wire.ScreenOfferBody, l *session.Link) {
	v.mu.Lock()
	if v.peerID != "" && deviceID != v.peerID {
		v.mu.Unlock()
		return // not the peer we asked
	}
	if v.offer != nil {
		// A repeated offer for the session we're waiting on is a keep-alive.
		v.mu.Unlock()
		return
	}
	if v.link == nil {
		v.link = l
		v.peerID = deviceID
		v.startedAt = time.Now()
	}
	dec, err := StartDecoder(DecoderConfig{
		FFmpegPath: v.cfg.FFmpegPath, Codec: offer.Codec,
		Width: offer.Width, Height: offer.Height,
	})
	if err != nil {
		v.mu.Unlock()
		v.finish(fmt.Errorf("decoder start failed: %v", err))
		return
	}
	o := offer
	v.offer = &o
	v.dec = dec
	v.containerW, v.containerH = float64(offer.Width), float64(offer.Height)
	v.mu.Unlock()

	if err := v.cfg.Window.Open(offer.Width, offer.Height,
		fmt.Sprintf("%s — %s", offer.SourceName, offer.Codec)); err != nil {
		v.finish(fmt.Errorf("window open failed: %v", err))
		return
	}
	v.logf("offer: %s %dx%d@%d %s (wire session %d)",
		offer.SourceName, offer.Width, offer.Height, offer.Fps, offer.Codec, offer.WireSessionID)

	// The reverse-dialed lane authenticates by token; an offer with an empty
	// token (Android sources) promises no dedicated lane at all.
	if offer.BulkToken != "" {
		v.node.RegisterScreenAttach(offer.BulkToken, func(conn *session.FramedConn, attach wire.ScreenAttachBody) bool {
			return v.adoptBulkLane(conn, attach)
		})
	}
	go v.runBlitter(dec)
	go v.runUIEvents()
	// Ask for a keyframe now (Kotlin does the same on offer): without one the
	// decoder has no parameter sets and the window stays black until the
	// encoder's next scheduled IDR.
	v.sendAck(true)
	if v.cfg.EnableInput {
		go v.requestControl()
	}
}

func (v *Viewer) HandleReject(deviceID string, body wire.ScreenRejectBody) {
	v.mu.Lock()
	known := v.peerID == "" || deviceID == v.peerID
	v.mu.Unlock()
	if known {
		v.finish(fmt.Errorf("source rejected the request: %s", body.Reason))
	}
}

// adoptBulkLane binds the source's reverse-dialed connection (routed here by
// the node via the one-time token).
func (v *Viewer) adoptBulkLane(conn *session.FramedConn, attach wire.ScreenAttachBody) bool {
	v.mu.Lock()
	if v.offer == nil || attach.ScreenSessionID != v.offer.ScreenSessionID {
		v.mu.Unlock()
		return false
	}
	v.bulk = conn
	v.attached = true
	v.usesControl = false
	v.mu.Unlock()
	v.logf("direct lane attached")
	v.sendAck(true) // keyframe request on the new lane, like Swift's attach
	go v.runLaneLoop(conn)
	return true
}

func (v *Viewer) runLaneLoop(conn *session.FramedConn) {
	for {
		frame, ok, err := conn.NextFrame()
		if err != nil || !ok {
			break
		}
		switch frame.Kind {
		case wire.KindScreenFrame:
			v.handleFrame(*frame.Screen)
		case wire.KindControl:
			_, msg, derr := wire.DecodeMessage(frame.Control)
			if derr != nil {
				continue
			}
			if msg.Type == wire.TypeScreenEnd {
				body := msg.Body.(wire.ScreenEndBody)
				v.handleEndBody(body)
				return
			}
		}
	}
	// Lane dropped without SCREEN_END: the source may demote to the session
	// link, so don't kill the session — just fall back to expecting control-
	// lane frames. The stall watchdog ends it if nothing resumes.
	v.mu.Lock()
	if v.bulk == conn {
		v.bulk = nil
		v.usesControl = true
	}
	v.mu.Unlock()
	conn.Close()
	v.logf("direct lane closed; waiting for frames on the session link")
}

// HandleControlFrame: a frame arrived on the session link (fallback lane).
func (v *Viewer) HandleControlFrame(deviceID string, frame wire.ScreenFrame, _ *session.Link) {
	v.mu.Lock()
	match := v.offer != nil && deviceID == v.peerID && frame.SessionID == v.offer.WireSessionID
	if match && !v.attached {
		v.attached = true
		v.usesControl = true
		v.logf("stream arriving on the session link (no direct lane)")
	}
	v.mu.Unlock()
	if match {
		v.handleFrame(frame)
	}
}

func (v *Viewer) handleFrame(frame wire.ScreenFrame) {
	encoded, err := wire.UnpackScreenFrame(frame.Data, frame.IsKeyframe)
	if err != nil {
		v.logf("bad screen frame: %v", err)
		return
	}
	v.mu.Lock()
	dec := v.dec
	if frame.Seq > v.highestSeq {
		v.highestSeq = frame.Seq
	}
	v.sinceAck++
	needAck := v.sinceAck >= viewerAckInterval
	if needAck {
		v.sinceAck = 0
	}
	v.mu.Unlock()
	if dec == nil {
		return
	}
	if _, err := dec.Submit(encoded); err != nil {
		v.finish(fmt.Errorf("decoder failed: %v", err))
		return
	}
	if needAck {
		v.sendAck(false)
	}
}

// sendAck reports progress on whichever lane carries the stream — a keyframe
// request dropped on the wrong lane means a glitched picture never recovers.
func (v *Viewer) sendAck(requestKeyframe bool) {
	v.mu.Lock()
	offer, link, bulk := v.offer, v.link, v.bulk
	seq := v.highestSeq
	v.mu.Unlock()
	if offer == nil || link == nil {
		return
	}
	msg := wire.Message{Type: wire.TypeScreenAck, Body: wire.ScreenAckBody{
		ScreenSessionID: offer.ScreenSessionID, AckedSeq: seq, RequestKeyframe: requestKeyframe}}
	if bulk != nil {
		_ = bulk.Send(msg)
	} else {
		_ = link.Send(msg)
	}
}

func (v *Viewer) runBlitter(dec *Decoder) {
	for frame := range dec.Frames() {
		v.mu.Lock()
		w, h := 0, 0
		if v.offer != nil {
			w, h = v.offer.Width, v.offer.Height
		}
		v.gotFrame = true
		v.lastFrameAt = time.Now()
		v.blitCount++
		v.mu.Unlock()
		if err := v.cfg.Window.Blit(frame, w, h); err != nil {
			v.finish(fmt.Errorf("blit failed: %v", err))
			return
		}
	}
	if err := dec.Err(); err != nil {
		v.finish(fmt.Errorf("decoder exited: %v", err))
	}
}

// watchdog ends a session that never produced video, or whose video stopped
// with no SCREEN_END (black-holed lane — the failure EOF-driven paths miss).
func (v *Viewer) watchdog() {
	t := time.NewTicker(2 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-v.stopWatch:
			return
		case <-t.C:
			v.mu.Lock()
			got, last, started := v.gotFrame, v.lastFrameAt, v.startedAt
			v.mu.Unlock()
			if !got {
				if time.Since(started) > viewerStartTimeout {
					v.finish(fmt.Errorf("no video within %s — the source may need permissions, or its dial back never landed", viewerStartTimeout))
					return
				}
			} else if time.Since(last) > viewerStallTimeout {
				v.finish(fmt.Errorf("video stopped arriving for %s — the connection may have dropped without closing", viewerStallTimeout))
				return
			}
		}
	}
}

func (v *Viewer) HandleEnd(deviceID string, body wire.ScreenEndBody) {
	v.mu.Lock()
	match := v.offer != nil && deviceID == v.peerID && body.ScreenSessionID == v.offer.ScreenSessionID
	v.mu.Unlock()
	if match {
		v.handleEndBody(body)
	}
}

func (v *Viewer) handleEndBody(body wire.ScreenEndBody) {
	if body.Reason != nil {
		v.finish(fmt.Errorf("source ended the share: %s", *body.Reason))
	} else {
		v.finish(nil)
	}
}

func (v *Viewer) HandleSessionClosed(deviceID string) {
	v.mu.Lock()
	mine := v.peerID == deviceID
	bulkAlive := v.bulk != nil
	v.mu.Unlock()
	if !mine {
		return
	}
	// A session drop with a live dedicated lane could in principle outlive it
	// (the iPhone broadcast case) — but acks and input ride the session link
	// here, so for this CLI viewer the honest move is to end.
	_ = bulkAlive
	v.finish(errors.New("session to the source closed"))
}

// ---- input (controller side) ----

func (v *Viewer) requestControl() {
	v.mu.Lock()
	link := v.link
	v.mu.Unlock()
	if link == nil {
		return
	}
	if !link.HasCapabilityRemote(wire.CapInputInject) {
		v.logf("view-only: %s does not advertise input-inject", link.Peer().Name)
		return
	}
	if err := link.Send(wire.Message{Type: wire.TypeInputRequest, Body: struct{}{}}); err != nil {
		v.logf("input request failed: %v", err)
	}
}

// HandleInputStatus: the receiver's grant lifecycle.
func (v *Viewer) HandleInputStatus(deviceID string, body wire.InputStatusBody) {
	v.mu.Lock()
	if deviceID != v.peerID {
		v.mu.Unlock()
		return
	}
	if body.SecureInput != nil {
		v.secureInput = *body.SecureInput
	}
	link := v.link
	if body.Active && v.coal == nil {
		v.coal = NewCoalescer(func(ev wire.InputEventBody) {
			_ = link.Send(wire.Message{Type: wire.TypeInputEvent, Body: ev})
		})
		v.controlling = true
		v.mu.Unlock()
		v.logf("control granted — pointer and keyboard now drive %s", link.Peer().Name)
		if body.SecureInput != nil && *body.SecureInput {
			v.logf("note: the remote focus is a secure-input field; keys are refused there")
		}
		return
	}
	if !body.Active {
		coal := v.coal
		v.coal = nil
		v.controlling = false
		v.mu.Unlock()
		if coal != nil {
			coal.Stop()
		}
		reason := "ended"
		if body.Reason != nil {
			reason = *body.Reason
		}
		v.logf("control not active: %s (view-only)", reason)
		return
	}
	v.mu.Unlock()
}

func (v *Viewer) runUIEvents() {
	for ev := range v.cfg.Window.Events() {
		switch ev.Kind {
		case UIResize:
			v.mu.Lock()
			v.containerW, v.containerH = ev.W, ev.H
			v.mu.Unlock()
		case UIClosed:
			// User closed the window: tell the source, then end cleanly.
			v.mu.Lock()
			offer, link := v.offer, v.link
			v.mu.Unlock()
			if offer != nil && link != nil {
				_ = link.Send(wire.Message{Type: wire.TypeScreenEnd, Body: wire.ScreenEndBody{
					ScreenSessionID: offer.ScreenSessionID}})
			}
			v.finish(nil)
			return
		case UIMotion:
			v.pointerMoved(ev.X, ev.Y)
		case UIButtonDown, UIButtonUp:
			v.button(ev)
		case UIWheel:
			v.mu.Lock()
			coal := v.coal
			v.mu.Unlock()
			if coal != nil {
				coal.Scroll(ev.WheelDX, ev.WheelDY)
			}
		case UIKeyDown, UIKeyUp:
			v.key(ev)
		}
	}
}

// pointerMoved translates a window position into an ADR 0015 absolute move:
// nx/ny normalized to the picture (un-letterboxed via geometry) plus the
// equivalent dx/dy in source pixels, so a receiver that predates the absolute
// fields still tracks the pointer.
func (v *Viewer) pointerMoved(x, y float64) {
	v.mu.Lock()
	coal, offer := v.coal, v.offer
	cw, ch := v.containerW, v.containerH
	v.mu.Unlock()
	if coal == nil || offer == nil {
		return
	}
	nx, ny, ok := Normalize(x, y, cw, ch, offer.Width, offer.Height)
	if !ok {
		// Letterbox bars: not a position on anything. End the gesture so the
		// next in-picture point doesn't inherit a stale delta origin.
		v.mu.Lock()
		v.haveLast = false
		v.mu.Unlock()
		return
	}
	v.mu.Lock()
	dx, dy := 0.0, 0.0
	if v.haveLast {
		dx, dy = Delta(v.lastNX, v.lastNY, nx, ny, offer.Width, offer.Height)
	}
	v.lastNX, v.lastNY = nx, ny
	v.haveLast = true
	v.mu.Unlock()
	coal.MoveAbsolute(nx, ny, dx, dy, offer.ScreenSessionID)
}

func (v *Viewer) button(ev UIEvent) {
	v.mu.Lock()
	coal := v.coal
	v.mu.Unlock()
	if coal == nil {
		return
	}
	// X11 wheel events are buttons 4–7; the window layer sends them as
	// UIWheel, so only 1–3 arrive here.
	var name string
	switch ev.Button {
	case 1:
		name = "left"
	case 2:
		name = "middle"
	case 3:
		name = "right"
	default:
		return
	}
	action := "down"
	if ev.Kind == UIButtonUp {
		action = "up"
	}
	one := 1
	coal.Discrete(wire.InputEventBody{
		Kind: "click", Button: &name, Action: &action, ClickCount: &one,
	})
}

func (v *Viewer) key(ev UIEvent) {
	v.mu.Lock()
	coal := v.coal
	v.mu.Unlock()
	if coal == nil {
		return
	}
	wk, ok := TranslateKey(ev.KeysymUnshifted, ev.KeysymShifted, ev.Modifiers)
	if !ok {
		return
	}
	action := "down"
	if ev.Kind == UIKeyUp {
		action = "up"
	}
	body := wire.InputEventBody{Kind: "key", Action: &action}
	if wk.Key != "" {
		body.Key = &wk.Key
	} else {
		body.Text = &wk.Text
	}
	if len(wk.Modifiers) > 0 {
		body.Modifiers = wk.Modifiers
	}
	coal.Discrete(body)
}

// finish ends the session exactly once. reason nil = clean.
func (v *Viewer) finish(reason error) {
	v.finishOnce.Do(func() {
		close(v.stopWatch)
		v.mu.Lock()
		v.finishReason = reason
		offer := v.offer
		dec := v.dec
		bulk := v.bulk
		coal := v.coal
		v.coal = nil
		v.controlling = false
		v.mu.Unlock()
		if coal != nil {
			coal.Stop()
		}
		if offer != nil && offer.BulkToken != "" {
			v.node.UnregisterScreenAttach(offer.BulkToken)
		}
		if bulk != nil {
			bulk.Close()
		}
		if dec != nil {
			dec.Stop()
		}
		v.cfg.Window.Close()
		close(v.done)
	})
}
