//go:build !linux

package screencast

import "fmt"

// The viewer window is X11-only; other platforms get an honest stub so the
// binary builds everywhere and says exactly why it can't run.
type unavailableWindow struct{ events chan UIEvent }

func NewWindow() Window { return &unavailableWindow{events: make(chan UIEvent)} }

func (w *unavailableWindow) Open(int, int, string) error {
	return fmt.Errorf("the viewer window is implemented for Linux/X11 only")
}
func (w *unavailableWindow) Blit([]byte, int, int) error {
	return fmt.Errorf("no window on this platform")
}
func (w *unavailableWindow) Events() <-chan UIEvent { return w.events }
func (w *unavailableWindow) Close()                 {}
