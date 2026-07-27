package screencast

import (
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/auston/conduit-core/session"
	"github.com/auston/conduit-core/wire"
)

// End-to-end over loopback: two REAL nodes (pinned mutual TLS, real framing),
// REAL ffmpeg encode and decode, the REAL source/viewer engines. What is fake
// — and this must stay written down, because a same-process loopback E2E is
// exactly the shape of test that once hid three broken features — is the
// capturer (synthetic frames, no X11) and the window (collects blits, no
// X11), plus the network being 127.0.0.1. X11 capture/blit and real-network
// behavior remain device-gated; see docs/plans/09.

type fakeCapturer struct {
	mu      sync.Mutex
	w, h    int
	b, g, r byte
	stop    chan struct{}
	running bool
}

func (f *fakeCapturer) Available() (bool, string) { return true, "" }
func (f *fakeCapturer) Backend() string           { return "fake" }
func (f *fakeCapturer) PixelFormat() string       { return "bgra" }
func (f *fakeCapturer) Source() (CaptureSource, error) {
	return CaptureSource{Name: "Fake Screen", Width: f.w, Height: f.h, Kind: "display"}, nil
}
func (f *fakeCapturer) Start(cfg CaptureConfig, onFrame func([]byte, uint64)) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.running {
		return fmt.Errorf("already running")
	}
	f.running = true
	f.stop = make(chan struct{})
	stop := f.stop
	go func() {
		start := time.Now()
		t := time.NewTicker(time.Second / time.Duration(cfg.FPS))
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				onFrame(solidBGRA(f.w, f.h, f.b, f.g, f.r), uint64(time.Since(start).Milliseconds()))
			}
		}
	}()
	return nil
}
func (f *fakeCapturer) Stop() {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.running {
		close(f.stop)
		f.running = false
	}
}

type fakeWindow struct {
	mu     sync.Mutex
	events chan UIEvent
	opened bool
	w, h   int
	blits  int
	last   []byte
}

func newFakeWindow() *fakeWindow { return &fakeWindow{events: make(chan UIEvent, 64)} }

func (f *fakeWindow) Open(w, h int, title string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.opened, f.w, f.h = true, w, h
	return nil
}
func (f *fakeWindow) Blit(bgra []byte, w, h int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.blits++
	f.last = bgra
	return nil
}
func (f *fakeWindow) Events() <-chan UIEvent { return f.events }

// Close leaves the events channel open on purpose: tests push events from
// their own goroutine, and the production x11 window owns its channel
// lifecycle itself.
func (f *fakeWindow) Close() {}

func (f *fakeWindow) blitCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.blits
}
func (f *fakeWindow) lastBlit() []byte {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.last
}

func newE2ENode(t *testing.T, name string, caps []string) *session.Node {
	t.Helper()
	dir := t.TempDir()
	id, tls, err := session.CreateIdentity(filepath.Join(dir, "id.json"), name)
	if err != nil {
		t.Fatalf("identity: %v", err)
	}
	return &session.Node{
		Name: name, DeviceClass: "desktop", AppVersion: "test",
		ID: id, TLS: tls,
		Peers:        session.LoadPeerStore(filepath.Join(dir, "peers.json")),
		ReceiveDir:   filepath.Join(dir, "recv"),
		Capabilities: caps,
	}
}

func pairAndFind(t *testing.T, a, b *session.Node) session.PinnedPeer {
	t.Helper()
	a.Confirm = func(session.PairPrompt) bool { return true }
	b.Confirm = func(session.PairPrompt) bool { return true }
	b.PairingEnabled = true
	if _, err := a.Pair("127.0.0.1", b.ListenPort()); err != nil {
		t.Fatalf("pair: %v", err)
	}
	b.PairingEnabled = false
	for _, p := range a.Peers.All() {
		if p.DeviceID == b.ID.DeviceID() {
			return p
		}
	}
	t.Fatalf("peer not pinned")
	return session.PinnedPeer{}
}

func waitFor(t *testing.T, timeout time.Duration, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// The headline flow: view a Go source's screen from a Go viewer, get promoted
// to the dedicated bulk lane, drive the pointer/keyboard back, and end
// cleanly from the viewer.
func TestScreenViewAndControlE2EOverLoopback(t *testing.T) {
	ffmpeg := requireFFmpeg(t)
	srcNode := newE2ENode(t, "src", []string{wire.CapFile, wire.CapScreenSource, wire.CapInputInject})
	viewNode := newE2ENode(t, "view", []string{wire.CapScreenView})

	capturer := &fakeCapturer{w: 320, h: 240, b: 200, g: 50, r: 100}
	source := NewSource(srcNode, SourceConfig{
		FFmpegPath: ffmpeg, Capturer: capturer, MaxFPS: 15,
		Log: func(s string) { t.Logf("[src] %s", s) },
	})
	inputs := make(chan wire.InputEventBody, 256)
	srcNode.SetHandlers(session.Handlers{
		OnScreenRequest: func(id string, req wire.ScreenRequestBody, l *session.Link) {
			go source.HandleRequest(id, req, l)
		},
		OnScreenAck:     source.HandleAck,
		OnScreenEnd:     source.HandleEnd,
		OnSessionClosed: source.HandleSessionClosed,
		OnInput:         func(_ string, ev wire.InputEventBody) { inputs <- ev },
		OnInputRequest: func(_ string, l *session.Link) {
			_ = l.Send(wire.Message{Type: wire.TypeInputStatus, Body: wire.InputStatusBody{Active: true}})
		},
	})

	win := newFakeWindow()
	viewer := NewViewer(viewNode, ViewerConfig{
		FFmpegPath: ffmpeg, Window: win, MaxWidth: 320, MaxHeight: 240, MaxFPS: 15,
		EnableInput: true,
		Log:         func(s string) { t.Logf("[view] %s", s) },
	})
	viewNode.SetHandlers(session.Handlers{
		OnScreenOffer:   viewer.HandleOffer,
		OnScreenReject:  viewer.HandleReject,
		OnScreenEnd:     viewer.HandleEnd,
		OnScreenFrame:   viewer.HandleControlFrame,
		OnInputStatus:   viewer.HandleInputStatus,
		OnSessionClosed: viewer.HandleSessionClosed,
	})

	if err := srcNode.Start(); err != nil {
		t.Fatalf("src start: %v", err)
	}
	defer srcNode.Close()
	if err := viewNode.Start(); err != nil {
		t.Fatalf("view start: %v", err)
	}
	defer viewNode.Close()
	peer := pairAndFind(t, viewNode, srcNode)

	link, err := viewNode.Connect(peer, "127.0.0.1", srcNode.ListenPort())
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	if err := viewer.Start(link); err != nil {
		t.Fatalf("viewer start: %v", err)
	}

	// Video must actually flow (blits, not just packets)…
	waitFor(t, 20*time.Second, "first blits", func() bool { return win.blitCount() >= 5 })
	// …and land on the DEDICATED lane after the background upgrade (asserting
	// the lane is the whole point — a lane-blind pass proved nothing once).
	waitFor(t, 20*time.Second, "bulk-lane promotion", func() bool {
		return viewer.Lane() == "bulk" && source.Lane() == "bulk"
	})
	// Pixels survive capture→encode→wire→decode: the fake screen is solid
	// (B=200,G=50,R=100); BT.709 both ways keeps it within a small tolerance.
	waitFor(t, 10*time.Second, "a decodable frame", func() bool { return win.lastBlit() != nil })
	last := win.lastBlit()
	if len(last) != 320*240*4 {
		t.Fatalf("blit frame is %d bytes", len(last))
	}
	var db, dg, dr int64
	for i := 0; i < len(last); i += 4 {
		db += abs64(int64(last[i]) - 200)
		dg += abs64(int64(last[i+1]) - 50)
		dr += abs64(int64(last[i+2]) - 100)
	}
	px := int64(320 * 240)
	if db/px > 12 || dg/px > 12 || dr/px > 12 {
		t.Fatalf("colour drifted across the full path: mean |Δ| B=%d G=%d R=%d", db/px, dg/px, dr/px)
	}

	// Control: the grant must arrive (INPUT_REQUEST → INPUT_STATUS active).
	waitFor(t, 10*time.Second, "input grant", viewer.Controlling)

	// Point at the centre, click, type, scroll — through the real window-event
	// path. The wire must show: an ADR 0015 absolute move (nx/ny AND dx/dy)
	// BEFORE the click's down/up, then the key, then the scroll.
	win.events <- UIEvent{Kind: UIMotion, X: 160, Y: 120}
	win.events <- UIEvent{Kind: UIButtonDown, Button: 1, X: 160, Y: 120}
	win.events <- UIEvent{Kind: UIButtonUp, Button: 1, X: 160, Y: 120}
	win.events <- UIEvent{Kind: UIKeyDown, KeysymUnshifted: 'a', KeysymShifted: 'A'}
	win.events <- UIEvent{Kind: UIKeyUp, KeysymUnshifted: 'a', KeysymShifted: 'A'}
	win.events <- UIEvent{Kind: UIWheel, WheelDY: 40}

	var got []wire.InputEventBody
	deadline := time.After(10 * time.Second)
collect:
	for {
		select {
		case ev := <-inputs:
			got = append(got, ev)
			if ev.Kind == "scroll" {
				break collect
			}
		case <-deadline:
			t.Fatalf("input events did not arrive; got %d so far: %+v", len(got), got)
		}
	}
	moveIdx, clickDownIdx := -1, -1
	for i, ev := range got {
		switch ev.Kind {
		case "move":
			if moveIdx == -1 {
				moveIdx = i
			}
			if ev.Nx == nil || ev.Ny == nil || ev.Dx == nil || ev.Dy == nil {
				t.Fatalf("ADR 0015 violation: move without both absolute and delta: %+v", ev)
			}
			if *ev.Nx < 0.47 || *ev.Nx > 0.53 || *ev.Ny < 0.47 || *ev.Ny > 0.53 {
				t.Fatalf("centre click mapped to (%v,%v)", *ev.Nx, *ev.Ny)
			}
			if ev.ScreenSessionID == nil {
				t.Fatalf("absolute move lost its screen_session_id")
			}
		case "click":
			if clickDownIdx == -1 {
				clickDownIdx = i
				if *ev.Action != "down" || *ev.Button != "left" {
					t.Fatalf("first click event wrong: %+v", ev)
				}
			}
		}
	}
	if moveIdx == -1 || clickDownIdx == -1 || moveIdx > clickDownIdx {
		t.Fatalf("click overtook the motion that positioned it: move@%d click@%d", moveIdx, clickDownIdx)
	}
	var sawKeyDown, sawKeyUp bool
	for _, ev := range got {
		if ev.Kind == "key" && ev.Text != nil && *ev.Text == "a" {
			switch *ev.Action {
			case "down":
				sawKeyDown = true
			case "up":
				sawKeyUp = true
			}
		}
	}
	if !sawKeyDown || !sawKeyUp {
		t.Fatalf("hardware key down/up did not survive: %+v", got)
	}
	lastEv := got[len(got)-1]
	if lastEv.Kind != "scroll" || *lastEv.Dy != 40 {
		t.Fatalf("scroll wrong: %+v", lastEv)
	}

	// Close from the viewer: the source must see SCREEN_END and stop.
	win.events <- UIEvent{Kind: UIClosed}
	if err := viewer.Wait(); err != nil {
		t.Fatalf("viewer end: %v", err)
	}
	waitFor(t, 10*time.Second, "source teardown", func() bool { return source.Lane() == "none" })
}

// The degraded path every real network eventually exercises: no reverse dial.
// Frames must flow on the session link and the source must stay there.
func TestScreenViewControlLaneFallback(t *testing.T) {
	ffmpeg := requireFFmpeg(t)
	srcNode := newE2ENode(t, "src", []string{wire.CapScreenSource})
	viewNode := newE2ENode(t, "view", []string{wire.CapScreenView})

	capturer := &fakeCapturer{w: 320, h: 240, b: 30, g: 180, r: 60}
	source := NewSource(srcNode, SourceConfig{
		FFmpegPath: ffmpeg, Capturer: capturer, MaxFPS: 15,
		DisableBulkLane: true, // the dial never happens; the stream must not care
		Log:             func(s string) { t.Logf("[src] %s", s) },
	})
	srcNode.SetHandlers(session.Handlers{
		OnScreenRequest: func(id string, req wire.ScreenRequestBody, l *session.Link) {
			go source.HandleRequest(id, req, l)
		},
		OnScreenAck:     source.HandleAck,
		OnScreenEnd:     source.HandleEnd,
		OnSessionClosed: source.HandleSessionClosed,
	})
	win := newFakeWindow()
	viewer := NewViewer(viewNode, ViewerConfig{
		FFmpegPath: ffmpeg, Window: win, MaxWidth: 320, MaxHeight: 240, MaxFPS: 15,
		Log: func(s string) { t.Logf("[view] %s", s) },
	})
	viewNode.SetHandlers(session.Handlers{
		OnScreenOffer:   viewer.HandleOffer,
		OnScreenReject:  viewer.HandleReject,
		OnScreenEnd:     viewer.HandleEnd,
		OnScreenFrame:   viewer.HandleControlFrame,
		OnSessionClosed: viewer.HandleSessionClosed,
	})
	if err := srcNode.Start(); err != nil {
		t.Fatalf("src start: %v", err)
	}
	defer srcNode.Close()
	if err := viewNode.Start(); err != nil {
		t.Fatalf("view start: %v", err)
	}
	defer viewNode.Close()
	peer := pairAndFind(t, viewNode, srcNode)
	link, err := viewNode.Connect(peer, "127.0.0.1", srcNode.ListenPort())
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	if err := viewer.Start(link); err != nil {
		t.Fatalf("viewer start: %v", err)
	}
	waitFor(t, 20*time.Second, "control-lane blits", func() bool { return win.blitCount() >= 5 })
	if viewer.Lane() != "control" || source.Lane() != "control" {
		t.Fatalf("expected the session-link fallback, got viewer=%s source=%s", viewer.Lane(), source.Lane())
	}
	// Source-side stop: the viewer must learn via SCREEN_END, cleanly.
	source.Stop()
	if err := viewer.Wait(); err != nil {
		t.Fatalf("viewer should end cleanly on source stop, got: %v", err)
	}
}

// A peer with no screen engine must refuse politely (the Link's built-in
// reject), and the viewer must surface that instead of hanging.
func TestViewerSurfacesPoliteRejection(t *testing.T) {
	ffmpeg := requireFFmpeg(t)
	srcNode := newE2ENode(t, "src", []string{wire.CapFile, wire.CapScreenSource}) // advertises but has no handler
	viewNode := newE2ENode(t, "view", []string{wire.CapScreenView})
	win := newFakeWindow()
	viewer := NewViewer(viewNode, ViewerConfig{FFmpegPath: ffmpeg, Window: win})
	viewNode.SetHandlers(session.Handlers{
		OnScreenOffer:  viewer.HandleOffer,
		OnScreenReject: viewer.HandleReject,
	})
	if err := srcNode.Start(); err != nil {
		t.Fatalf("src start: %v", err)
	}
	defer srcNode.Close()
	if err := viewNode.Start(); err != nil {
		t.Fatalf("view start: %v", err)
	}
	defer viewNode.Close()
	peer := pairAndFind(t, viewNode, srcNode)
	link, err := viewNode.Connect(peer, "127.0.0.1", srcNode.ListenPort())
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	if err := viewer.Start(link); err != nil {
		t.Fatalf("viewer start: %v", err)
	}
	err = viewer.Wait()
	if err == nil || !strings.Contains(err.Error(), "rejected") {
		t.Fatalf("expected a surfaced rejection, got: %v", err)
	}
}
