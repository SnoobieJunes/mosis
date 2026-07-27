//go:build linux

package screencast

import (
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/jezek/xgb"
	"github.com/jezek/xgb/xproto"
)

// X11 screen capture via core-protocol GetImage polling — pure Go (jezek/xgb),
// so the daemon cross-compiles with CGO_ENABLED=0.
//
// Deliberate v1 ceilings, all recorded in docs/plans/09 and docs/linux.md:
//   - GetImage copies every frame through the X socket (~8 MB per 1080p
//     frame). MIT-SHM would eliminate the copy and is the named follow-up;
//     polling GetImage is the version whose failure modes are boring.
//   - Whole-root capture only (the display union on multi-head). No window
//     picking yet.
//   - Wayland is NOT supported natively. XWayland serves X11 clients but
//     GetImage on the XWayland root sees only X11 windows, not the whole
//     desktop — on a Wayland session Available() still probes true while the
//     picture may be incomplete. The runbook says so out loud; the portal
//     (ScreenCast + PipeWire) is the eventual native path.
//
// NOTHING in this file has executed on a real Linux box yet: it compiles
// under GOOS=linux and its logic mirrors documented protocol, and that is the
// entire claim. Device-gated (see docs/plans/09 status table).
type x11Capturer struct {
	mu      sync.Mutex
	conn    *xgb.Conn
	screen  *xproto.ScreenInfo
	stopped chan struct{}
	running bool
}

// NewCapturer returns the platform capturer: X11 on Linux.
func NewCapturer() Capturer { return &x11Capturer{} }

func (c *x11Capturer) Backend() string { return "x11-getimage" }

func (c *x11Capturer) PixelFormat() string { return "bgr0" }

// connect dials the X server once (lazily) and validates the pixel layout the
// bgr0 assumption rests on.
func (c *x11Capturer) connect() error {
	if c.conn != nil {
		return nil
	}
	if os.Getenv("DISPLAY") == "" {
		return fmt.Errorf("DISPLAY is not set (no X11 session; Wayland-native capture is not implemented)")
	}
	conn, err := xgb.NewConn()
	if err != nil {
		return fmt.Errorf("cannot connect to X server at DISPLAY=%s: %v", os.Getenv("DISPLAY"), err)
	}
	setup := xproto.Setup(conn)
	screen := setup.DefaultScreen(conn)
	if screen.RootDepth != 24 && screen.RootDepth != 32 {
		conn.Close()
		return fmt.Errorf("root depth is %d; only 24/32-bit truecolor is supported", screen.RootDepth)
	}
	if setup.ImageByteOrder != xproto.ImageOrderLSBFirst {
		// Big-endian X servers order pixel bytes the other way; bgr0 would be
		// wrong. Rare enough that v1 refuses honestly instead of guessing.
		conn.Close()
		return fmt.Errorf("X server is MSB-first; only LSB-first pixel order is supported")
	}
	c.conn = conn
	c.screen = screen
	return nil
}

func (c *x11Capturer) Available() (bool, string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.connect(); err != nil {
		return false, err.Error()
	}
	return true, ""
}

func (c *x11Capturer) Source() (CaptureSource, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.connect(); err != nil {
		return CaptureSource{}, err
	}
	host, _ := os.Hostname()
	if host == "" {
		host = "linux"
	}
	return CaptureSource{
		Name:   fmt.Sprintf("%s (X11 %s)", host, os.Getenv("DISPLAY")),
		Width:  int(c.screen.WidthInPixels),
		Height: int(c.screen.HeightInPixels),
		Kind:   "display",
	}, nil
}

func (c *x11Capturer) Start(cfg CaptureConfig, onFrame func([]byte, uint64)) error {
	c.mu.Lock()
	if c.running {
		c.mu.Unlock()
		return fmt.Errorf("capture already running")
	}
	if err := c.connect(); err != nil {
		c.mu.Unlock()
		return err
	}
	fps := cfg.FPS
	if fps <= 0 {
		fps = 15
	}
	stop := make(chan struct{})
	c.stopped = stop
	c.running = true
	conn, screen := c.conn, c.screen
	c.mu.Unlock()

	go func() {
		start := time.Now()
		ticker := time.NewTicker(time.Second / time.Duration(fps))
		defer ticker.Stop()
		w, h := screen.WidthInPixels, screen.HeightInPixels
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				reply, err := xproto.GetImage(conn, xproto.ImageFormatZPixmap,
					xproto.Drawable(screen.Root), 0, 0, w, h, 0xffffffff).Reply()
				if err != nil {
					// Server gone (logout, crash): stop delivering; the source
					// engine notices the frame drought via its own send path
					// when the encoder EOFs.
					return
				}
				// ZPixmap 32bpp rows are naturally 4-byte aligned: len == w*h*4.
				if len(reply.Data) != int(w)*int(h)*4 {
					continue // unexpected padding/layout; skip frame
				}
				onFrame(reply.Data, uint64(time.Since(start).Milliseconds()))
			}
		}
	}()
	return nil
}

func (c *x11Capturer) Stop() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.running {
		close(c.stopped)
		c.running = false
	}
}
