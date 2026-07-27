package screencast

// Capturer is the platform screen-capture contract, mirroring the Swift
// ScreenCapturer protocol at the fidelity a headless daemon needs. The X11
// implementation lives behind a linux build tag; other platforms get an
// honest "not here" stub so the core cross-compiles everywhere (the same
// pattern as platform.Injector).
type CaptureSource struct {
	Name   string
	Width  int // native pixels
	Height int
	Kind   string // wire capture_kind: "display" (windows are a follow-up)
}

type CaptureConfig struct {
	FPS int
}

type Capturer interface {
	// Available reports whether capture can actually run here, with a
	// human-readable reason when it can't. If false, the daemon must not
	// advertise screen-source — same honesty rule as Injector.Available.
	Available() (bool, string)
	// Backend names the mechanism for the daemon's status line.
	Backend() string
	// Source describes what Start will capture (v1: the whole root window —
	// the display union on multi-head X11).
	Source() (CaptureSource, error)
	// PixelFormat is the ffmpeg rawvideo pixel format of the frames Start
	// delivers ("bgr0" for X11 ZPixmap depth-24/32 little-endian).
	PixelFormat() string
	// Start polls frames at cfg.FPS and delivers them with a millisecond
	// timestamp relative to capture start. onFrame must not retain the slice
	// past its return unless it copies. Runs until Stop.
	Start(cfg CaptureConfig, onFrame func(frame []byte, ptsMillis uint64)) error
	Stop()
}
