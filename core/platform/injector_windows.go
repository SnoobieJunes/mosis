//go:build windows

package platform

import (
	"syscall"
	"unsafe"

	"github.com/auston/conduit-core/wire"
)

// Windows input injection via SendInput (spec §9 Phase 4 step 3). No cgo: we
// call user32!SendInput through the syscall package so this cross-compiles.
var (
	user32        = syscall.NewLazyDLL("user32.dll")
	procSendInput = user32.NewProc("SendInput")
)

const (
	inputMouse    = 0
	inputKeyboard = 1

	mouseMove       = 0x0001
	mouseLeftDown   = 0x0002
	mouseLeftUp     = 0x0004
	mouseRightDown  = 0x0008
	mouseRightUp    = 0x0010
	mouseMiddleDown = 0x0020
	mouseMiddleUp   = 0x0040
	mouseWheel      = 0x0800
)

// INPUT layout for a mouse event (union padded to the keyboard-input size).
type mouseInput struct {
	Type      uint32
	Dx        int32
	Dy        int32
	MouseData uint32
	Flags     uint32
	Time      uint32
	ExtraInfo uintptr
	_         [8]byte // pad union to sizeof(INPUT)
}

type windowsInjector struct{}

func NewInjector() Injector { return windowsInjector{} }

func (windowsInjector) Available() bool { return true }
func (windowsInjector) Backend() string { return "SendInput" }
func (windowsInjector) Close() error    { return nil }

func (windowsInjector) send(in *mouseInput) {
	procSendInput.Call(1, uintptr(unsafe.Pointer(in)), unsafe.Sizeof(*in))
}

func (w windowsInjector) Inject(ev wire.InputEventBody) error {
	switch ev.Kind {
	case "move":
		var dx, dy int32
		if ev.Dx != nil {
			dx = int32(*ev.Dx)
		}
		if ev.Dy != nil {
			dy = int32(*ev.Dy)
		}
		w.send(&mouseInput{Type: inputMouse, Dx: dx, Dy: dy, Flags: mouseMove})
	case "scroll":
		if ev.Dy != nil {
			w.send(&mouseInput{Type: inputMouse, MouseData: uint32(int32(-*ev.Dy)), Flags: mouseWheel})
		}
	case "click":
		down, up := uint32(mouseLeftDown), uint32(mouseLeftUp)
		if ev.Button != nil {
			switch *ev.Button {
			case "right":
				down, up = mouseRightDown, mouseRightUp
			case "middle":
				down, up = mouseMiddleDown, mouseMiddleUp
			}
		}
		action := "tap"
		if ev.Action != nil {
			action = *ev.Action
		}
		switch action {
		case "down":
			w.send(&mouseInput{Type: inputMouse, Flags: down})
		case "up":
			w.send(&mouseInput{Type: inputMouse, Flags: up})
		default:
			w.send(&mouseInput{Type: inputMouse, Flags: down})
			w.send(&mouseInput{Type: inputMouse, Flags: up})
		}
	}
	return nil
}
