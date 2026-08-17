//go:build windows

package platform

import (
	"fmt"
	"sync"
	"syscall"
	"unsafe"

	"github.com/auston/conduit-core/wire"
)

// Windows input injection via SendInput (spec §9 Phase 4 step 3). No cgo: we
// call user32!SendInput through the syscall package so this cross-compiles.
//
// **Nothing in this file has ever run.** It cross-compiles, and until 2026-08-17
// it could not have worked: the INPUT struct was laid out wrong (see below) so
// every mouse event was silently discarded by the OS, and kind:"key" had no case
// at all. Both are fixed here, by inspection against the Win32 headers — still
// device-gated until someone runs it on a Windows box.
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

	keyEventKeyUp   = 0x0002
	keyEventUnicode = 0x0004
)

// MOUSEINPUT / KEYBDINPUT exactly as declared in winuser.h.
type mouseInput struct {
	Dx        int32
	Dy        int32
	MouseData uint32
	Flags     uint32
	Time      uint32
	ExtraInfo uintptr
}

type keybdInput struct {
	Vk        uint16
	Scan      uint16
	Flags     uint32
	Time      uint32
	ExtraInfo uintptr
}

// input is Win32's INPUT: a DWORD type followed by a union.
//
// THE BUG THIS FIXES (2026-08-17): the old struct inlined the mouse fields
// straight after Type, with no allowance for the union's alignment. On a 64-bit
// build the union begins at offset 8 (it contains a ULONG_PTR, so it is
// 8-aligned), which means every field the old layout wrote landed 4 bytes early:
// dx sat in the padding, dy in dx, flags in mouseData. SendInput saw a
// zero/garbage flag word and accepted the call while doing nothing at all — so
// Windows remote control has never moved a cursor, and it failed silently rather
// than erroring, which is why it read as "cross-compiles, untested" rather than
// "broken". The explicit padding field and the size assertion below make the
// layout checkable without a Windows machine.
type input struct {
	Type uint32
	_    uint32 // union alignment padding (64-bit targets: amd64, arm64)
	// The union, sized by its largest member (MOUSEINPUT, 32 bytes on 64-bit).
	union [32]byte
}

// Compile-time size check: sizeof(INPUT) is 40 on 64-bit Windows, and SendInput
// rejects the call outright if cbSize disagrees. Nobody can run this file, so
// the layout is asserted instead of tested.
var _ = [1]struct{}{}[unsafe.Sizeof(input{})-40]

func (in *input) asMouse() *mouseInput    { return (*mouseInput)(unsafe.Pointer(&in.union[0])) }
func (in *input) asKeyboard() *keybdInput { return (*keybdInput)(unsafe.Pointer(&in.union[0])) }

func mouseEvent(mi mouseInput) input {
	in := input{Type: inputMouse}
	*in.asMouse() = mi
	return in
}

func keyEvent(ki keybdInput) input {
	in := input{Type: inputKeyboard}
	*in.asKeyboard() = ki
	return in
}

type windowsInjector struct {
	// Serializes the multi-event sequences below (press, release; modifier
	// press, key, modifier release) so two granted peers cannot interleave
	// halfway through one keystroke.
	mu sync.Mutex
}

func NewInjector() Injector { return &windowsInjector{} }

func (*windowsInjector) Available() bool { return true }
func (*windowsInjector) Backend() string { return "SendInput" }
func (*windowsInjector) Close() error    { return nil }

// send submits events and reports how many the OS accepted. The old code
// ignored the return value, which is the other half of why a wrong struct went
// unnoticed: SendInput returns the number of events inserted, and 0 means the
// call did nothing.
func (*windowsInjector) send(events ...input) error {
	if len(events) == 0 {
		return nil
	}
	n, _, err := procSendInput.Call(
		uintptr(len(events)),
		uintptr(unsafe.Pointer(&events[0])),
		unsafe.Sizeof(events[0]),
	)
	if int(n) != len(events) {
		return fmt.Errorf("SendInput inserted %d of %d events: %v", n, len(events), err)
	}
	return nil
}

func (w *windowsInjector) Inject(ev wire.InputEventBody) error {
	w.mu.Lock()
	defer w.mu.Unlock()

	switch ev.Kind {
	case "move":
		var dx, dy int32
		if ev.Dx != nil {
			dx = int32(*ev.Dx)
		}
		if ev.Dy != nil {
			dy = int32(*ev.Dy)
		}
		return w.send(mouseEvent(mouseInput{Dx: dx, Dy: dy, Flags: mouseMove}))
	case "scroll":
		if ev.Dy == nil {
			return nil
		}
		return w.send(mouseEvent(mouseInput{MouseData: uint32(int32(-*ev.Dy)), Flags: mouseWheel}))
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
			return w.send(mouseEvent(mouseInput{Flags: down}))
		case "up":
			return w.send(mouseEvent(mouseInput{Flags: up}))
		default:
			return w.send(
				mouseEvent(mouseInput{Flags: down}),
				mouseEvent(mouseInput{Flags: up}),
			)
		}
	case "key":
		return w.injectKey(ev)
	}
	return nil
}

// injectKey handles kind:"key". There was no case for this before 2026-08-17, so
// every keystroke a peer sent to a Windows daemon was accepted and dropped —
// undocumented, unlike the same gap on Linux.
func (w *windowsInjector) injectKey(ev wire.InputEventBody) error {
	// Text goes in as Unicode scan codes rather than virtual keys: no layout
	// table, and it types the character the sender meant even when the host's
	// keyboard layout differs (KEYEVENTF_UNICODE, winuser.h).
	if ev.Text != nil && *ev.Text != "" {
		var events []input
		for _, unit := range syscall.StringToUTF16(*ev.Text) {
			if unit == 0 {
				continue // the NUL terminator StringToUTF16 appends
			}
			events = append(events,
				keyEvent(keybdInput{Scan: unit, Flags: keyEventUnicode}),
				keyEvent(keybdInput{Scan: unit, Flags: keyEventUnicode | keyEventKeyUp}),
			)
		}
		return w.send(events...)
	}

	if ev.Key == nil {
		return nil
	}
	vk, ok := virtualKeys[*ev.Key]
	if !ok {
		return fmt.Errorf("SendInput: unknown key %q", *ev.Key)
	}
	var mods []uint16
	for _, name := range ev.Modifiers {
		if code, hit := modifierVirtualKeys[name]; hit {
			mods = append(mods, code)
		}
	}

	action := "tap"
	if ev.Action != nil {
		action = *ev.Action
	}
	var events []input
	switch action {
	case "down":
		for _, m := range mods {
			events = append(events, keyEvent(keybdInput{Vk: m}))
		}
		events = append(events, keyEvent(keybdInput{Vk: vk}))
	case "up":
		events = append(events, keyEvent(keybdInput{Vk: vk, Flags: keyEventKeyUp}))
		for i := len(mods) - 1; i >= 0; i-- {
			events = append(events, keyEvent(keybdInput{Vk: mods[i], Flags: keyEventKeyUp}))
		}
	default:
		for _, m := range mods {
			events = append(events, keyEvent(keybdInput{Vk: m}))
		}
		events = append(events,
			keyEvent(keybdInput{Vk: vk}),
			keyEvent(keybdInput{Vk: vk, Flags: keyEventKeyUp}),
		)
		for i := len(mods) - 1; i >= 0; i-- {
			events = append(events, keyEvent(keybdInput{Vk: mods[i], Flags: keyEventKeyUp}))
		}
	}
	return w.send(events...)
}

// The same key names MacInputInjector.virtualKey(for:) accepts, so a controller
// does not need to know which OS it is driving. Virtual-key codes from winuser.h.
var virtualKeys = map[string]uint16{
	"return": 0x0D, "enter": 0x0D,
	"tab":    0x09,
	"space":  0x20,
	"delete": 0x08, "backspace": 0x08, // VK_BACK — erases backwards
	"delete_forward": 0x2E, // VK_DELETE
	"escape":         0x1B,
	"up":             0x26, "down": 0x28, "left": 0x25, "right": 0x27,
	"home": 0x24, "end": 0x23, "page_up": 0x21, "page_down": 0x22,
	"f1": 0x70, "f2": 0x71, "f3": 0x72, "f4": 0x73, "f5": 0x74, "f6": 0x75,
	"f7": 0x76, "f8": 0x77, "f9": 0x78, "f10": 0x79, "f11": 0x7A, "f12": 0x7B,
}

var modifierVirtualKeys = map[string]uint16{
	"shift":   0x10, // VK_SHIFT
	"control": 0x11, // VK_CONTROL
	"option":  0x12, // VK_MENU (Alt)
	"command": 0x5B, // VK_LWIN
	// "function" has no Windows equivalent and is dropped rather than guessed.
}
