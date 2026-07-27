//go:build !linux

package screencast

import "fmt"

// Non-Linux daemons can't source a screen through this package (macOS has the
// Swift app; Windows capture is a documented follow-up). The stub keeps the
// core cross-compiling and the capability honestly un-advertised.
type unavailableCapturer struct{}

func NewCapturer() Capturer { return unavailableCapturer{} }

func (unavailableCapturer) Available() (bool, string) {
	return false, "screen capture is implemented for Linux/X11 only in the Go core"
}
func (unavailableCapturer) Backend() string     { return "none" }
func (unavailableCapturer) PixelFormat() string { return "bgra" }
func (unavailableCapturer) Source() (CaptureSource, error) {
	return CaptureSource{}, fmt.Errorf("no capturer on this platform")
}
func (unavailableCapturer) Start(CaptureConfig, func([]byte, uint64)) error {
	return fmt.Errorf("no capturer on this platform")
}
func (unavailableCapturer) Stop() {}
