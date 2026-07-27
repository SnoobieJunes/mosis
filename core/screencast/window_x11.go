//go:build linux

package screencast

import (
	"encoding/binary"
	"fmt"
	"sync"

	"github.com/jezek/xgb"
	"github.com/jezek/xgb/xproto"
)

// X11 viewer window: create a window sized to the stream, PutImage decoded
// BGRA frames into it 1:1, and translate its input events for the wire.
//
// v1 draws UNSCALED at the window's top-left and pins the window size with
// min==max WM size hints. That keeps the pointer mapping exact with zero
// pure-Go pixel scaling: the picture rectangle is always (0,0,streamW,streamH),
// so the engine's container size never changes (no UIResize is emitted). A
// tiling WM that resizes the window anyway crops or bares the edge — mapping
// stays correct for the visible region. Scaled drawing is a follow-up.
//
// Like the capture side, NONE of this has run on a real X server yet —
// compiles under GOOS=linux, semantics from the protocol docs. Device-gated.
type x11Window struct {
	mu     sync.Mutex
	conn   *xgb.Conn
	win    xproto.Window
	gc     xproto.Gcontext
	width  int
	height int
	depth  byte
	// Bytes a single PutImage may carry (server max request length minus
	// header), for strip-wise blits.
	maxDataBytes int
	wmDelete     xproto.Atom

	events    chan UIEvent
	lastFrame []byte // for Expose redraws

	// keycode → keysym columns 0/1.
	minKeycode xproto.Keycode
	keysyms    []xproto.Keysym
	perKeycode byte

	closeOnce sync.Once
}

// NewWindow returns the platform window (X11 on Linux).
func NewWindow() Window { return &x11Window{events: make(chan UIEvent, 64)} }

func (w *x11Window) Open(width, height int, title string) error {
	conn, err := xgb.NewConn()
	if err != nil {
		return fmt.Errorf("cannot connect to X server: %v (is DISPLAY set?)", err)
	}
	setup := xproto.Setup(conn)
	if setup.ImageByteOrder != xproto.ImageOrderLSBFirst {
		conn.Close()
		return fmt.Errorf("X server is MSB-first; only LSB-first pixel order is supported")
	}
	screen := setup.DefaultScreen(conn)
	if screen.RootDepth != 24 && screen.RootDepth != 32 {
		conn.Close()
		return fmt.Errorf("root depth %d unsupported (need 24/32-bit truecolor)", screen.RootDepth)
	}

	wid, err := xproto.NewWindowId(conn)
	if err != nil {
		conn.Close()
		return err
	}
	mask := uint32(xproto.EventMaskKeyPress | xproto.EventMaskKeyRelease |
		xproto.EventMaskButtonPress | xproto.EventMaskButtonRelease |
		xproto.EventMaskPointerMotion | xproto.EventMaskStructureNotify |
		xproto.EventMaskExposure)
	if err := xproto.CreateWindowChecked(conn, screen.RootDepth, wid, screen.Root,
		0, 0, uint16(width), uint16(height), 1,
		xproto.WindowClassInputOutput, screen.RootVisual,
		xproto.CwBackPixel|xproto.CwEventMask,
		[]uint32{screen.BlackPixel, mask}).Check(); err != nil {
		conn.Close()
		return fmt.Errorf("create window: %v", err)
	}

	gcid, err := xproto.NewGcontextId(conn)
	if err != nil {
		conn.Close()
		return err
	}
	if err := xproto.CreateGCChecked(conn, gcid, xproto.Drawable(wid),
		xproto.GcForeground, []uint32{screen.BlackPixel}).Check(); err != nil {
		conn.Close()
		return fmt.Errorf("create gc: %v", err)
	}

	// Title (legacy WM_NAME is enough for every WM that matters here).
	xproto.ChangeProperty(conn, xproto.PropModeReplace, wid, xproto.AtomWmName,
		xproto.AtomString, 8, uint32(len(title)), []byte(title))

	// Pin the size: min == max WM_NORMAL_HINTS (see the file comment).
	hints := make([]byte, 18*4)
	binary.LittleEndian.PutUint32(hints[0:], 1<<4|1<<5) // PMinSize | PMaxSize
	binary.LittleEndian.PutUint32(hints[5*4:], uint32(width))
	binary.LittleEndian.PutUint32(hints[6*4:], uint32(height))
	binary.LittleEndian.PutUint32(hints[7*4:], uint32(width))
	binary.LittleEndian.PutUint32(hints[8*4:], uint32(height))
	xproto.ChangeProperty(conn, xproto.PropModeReplace, wid,
		xproto.AtomWmNormalHints, xproto.AtomWmSizeHints, 32, 18, hints)

	// Close-button protocol.
	protoAtom, err1 := xproto.InternAtom(conn, false, uint16(len("WM_PROTOCOLS")), "WM_PROTOCOLS").Reply()
	delAtom, err2 := xproto.InternAtom(conn, false, uint16(len("WM_DELETE_WINDOW")), "WM_DELETE_WINDOW").Reply()
	if err1 == nil && err2 == nil {
		var buf [4]byte
		binary.LittleEndian.PutUint32(buf[:], uint32(delAtom.Atom))
		xproto.ChangeProperty(conn, xproto.PropModeReplace, wid, protoAtom.Atom,
			xproto.AtomAtom, 32, 1, buf[:])
		w.wmDelete = delAtom.Atom
	}

	if err := w.loadKeyboardMapping(conn, setup); err != nil {
		conn.Close()
		return err
	}

	xproto.MapWindow(conn, wid)

	w.mu.Lock()
	w.conn = conn
	w.win = wid
	w.gc = gcid
	w.width, w.height = width, height
	w.depth = screen.RootDepth
	// MaximumRequestLength is in 4-byte units; leave generous header room.
	w.maxDataBytes = int(setup.MaximumRequestLength)*4 - 64
	w.mu.Unlock()

	go w.eventLoop()
	return nil
}

func (w *x11Window) loadKeyboardMapping(conn *xgb.Conn, setup *xproto.SetupInfo) error {
	count := byte(setup.MaxKeycode - setup.MinKeycode + 1)
	reply, err := xproto.GetKeyboardMapping(conn, setup.MinKeycode, count).Reply()
	if err != nil {
		return fmt.Errorf("keyboard mapping: %v", err)
	}
	w.mu.Lock()
	w.minKeycode = setup.MinKeycode
	w.keysyms = reply.Keysyms
	w.perKeycode = reply.KeysymsPerKeycode
	w.mu.Unlock()
	return nil
}

// keysymColumns returns keysym columns 0 and 1 for a keycode.
func (w *x11Window) keysymColumns(kc xproto.Keycode) (uint32, uint32) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.perKeycode == 0 || kc < w.minKeycode {
		return 0, 0
	}
	base := int(kc-w.minKeycode) * int(w.perKeycode)
	if base >= len(w.keysyms) {
		return 0, 0
	}
	k0 := uint32(w.keysyms[base])
	k1 := uint32(0)
	if int(w.perKeycode) > 1 && base+1 < len(w.keysyms) {
		k1 = uint32(w.keysyms[base+1])
	}
	return k0, k1
}

// Blit draws a stream-sized BGRA frame, split into horizontal strips that fit
// the server's maximum request length (no BIG-REQUESTS dependency).
func (w *x11Window) Blit(bgra []byte, fw, fh int) error {
	w.mu.Lock()
	conn, win, gc, depth := w.conn, w.win, w.gc, w.depth
	maxData := w.maxDataBytes
	w.lastFrame = bgra
	w.mu.Unlock()
	if conn == nil {
		return fmt.Errorf("window closed")
	}
	if fw <= 0 || fh <= 0 || len(bgra) < fw*fh*4 {
		return fmt.Errorf("bad frame: %d bytes for %dx%d", len(bgra), fw, fh)
	}
	rowBytes := fw * 4
	rowsPerStrip := maxData / rowBytes
	if rowsPerStrip < 1 {
		rowsPerStrip = 1
	}
	for y := 0; y < fh; y += rowsPerStrip {
		rows := rowsPerStrip
		if y+rows > fh {
			rows = fh - y
		}
		data := bgra[y*rowBytes : (y+rows)*rowBytes]
		if err := xproto.PutImageChecked(conn, xproto.ImageFormatZPixmap,
			xproto.Drawable(win), gc,
			uint16(fw), uint16(rows), 0, int16(y),
			0, depth, data).Check(); err != nil {
			return fmt.Errorf("put image: %v", err)
		}
	}
	return nil
}

func (w *x11Window) Events() <-chan UIEvent { return w.events }

func (w *x11Window) eventLoop() {
	defer close(w.events)
	for {
		w.mu.Lock()
		conn := w.conn
		w.mu.Unlock()
		if conn == nil {
			return
		}
		ev, xerr := conn.WaitForEvent()
		if ev == nil && xerr == nil {
			return // connection closed
		}
		if xerr != nil {
			continue
		}
		switch e := ev.(type) {
		case xproto.MotionNotifyEvent:
			w.emit(UIEvent{Kind: UIMotion, X: float64(e.EventX), Y: float64(e.EventY), Modifiers: e.State})
		case xproto.ButtonPressEvent:
			w.buttonEvent(int(e.Detail), uint16(e.State), float64(e.EventX), float64(e.EventY), true)
		case xproto.ButtonReleaseEvent:
			w.buttonEvent(int(e.Detail), uint16(e.State), float64(e.EventX), float64(e.EventY), false)
		case xproto.KeyPressEvent:
			k0, k1 := w.keysymColumns(e.Detail)
			w.emit(UIEvent{Kind: UIKeyDown, KeysymUnshifted: k0, KeysymShifted: k1, Modifiers: e.State})
		case xproto.KeyReleaseEvent:
			k0, k1 := w.keysymColumns(e.Detail)
			w.emit(UIEvent{Kind: UIKeyUp, KeysymUnshifted: k0, KeysymShifted: k1, Modifiers: e.State})
		case xproto.ExposeEvent:
			w.mu.Lock()
			frame := w.lastFrame
			fw, fh := w.width, w.height
			w.mu.Unlock()
			if frame != nil {
				_ = w.Blit(frame, fw, fh)
			}
		case xproto.MappingNotifyEvent:
			w.mu.Lock()
			conn := w.conn
			w.mu.Unlock()
			if conn != nil {
				_ = w.loadKeyboardMapping(conn, xproto.Setup(conn))
			}
		case xproto.ClientMessageEvent:
			if w.wmDelete != 0 && len(e.Data.Data32) > 0 && xproto.Atom(e.Data.Data32[0]) == w.wmDelete {
				w.emit(UIEvent{Kind: UIClosed})
				return
			}
		case xproto.DestroyNotifyEvent:
			w.emit(UIEvent{Kind: UIClosed})
			return
		}
	}
}

// buttonEvent splits real buttons from wheel "buttons" 4–7. Wheel steps are
// ±40 px per detent, sign chosen to match the iOS controller's two-finger
// pan (positive dy = content up on the receiver); flagged in docs/linux.md as
// a direction to verify in the first on-device session.
func (w *x11Window) buttonEvent(button int, state uint16, x, y float64, press bool) {
	switch button {
	case 4:
		if press {
			w.emit(UIEvent{Kind: UIWheel, WheelDY: wheelStepPixels, Modifiers: state})
		}
	case 5:
		if press {
			w.emit(UIEvent{Kind: UIWheel, WheelDY: -wheelStepPixels, Modifiers: state})
		}
	case 6:
		if press {
			w.emit(UIEvent{Kind: UIWheel, WheelDX: wheelStepPixels, Modifiers: state})
		}
	case 7:
		if press {
			w.emit(UIEvent{Kind: UIWheel, WheelDX: -wheelStepPixels, Modifiers: state})
		}
	default:
		kind := UIButtonDown
		if !press {
			kind = UIButtonUp
		}
		w.emit(UIEvent{Kind: kind, Button: button, X: x, Y: y, Modifiers: state})
	}
}

// emit never blocks the X event loop; a full queue drops the oldest event
// (motion floods tolerate this, discrete events fit in 64 slots).
func (w *x11Window) emit(ev UIEvent) {
	select {
	case w.events <- ev:
	default:
		select {
		case <-w.events:
		default:
		}
		select {
		case w.events <- ev:
		default:
		}
	}
}

func (w *x11Window) Close() {
	w.closeOnce.Do(func() {
		w.mu.Lock()
		conn := w.conn
		w.conn = nil
		w.mu.Unlock()
		if conn != nil {
			conn.Close()
		}
	})
}
