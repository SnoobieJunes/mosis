//go:build linux

package platform

import (
	"encoding/binary"
	"fmt"
	"os"
	"syscall"

	"github.com/auston/conduit-core/wire"
)

// Linux input injection via /dev/uinput (spec §9 Phase 4 step 4). This is the
// no-portal fallback path: it needs write access to /dev/uinput (a udev rule or
// the input group), NOT root for the default case once permissions are set. The
// Wayland xdg-desktop-portal RemoteDesktop + libei route is the preferred path
// on modern desktops and is a documented follow-up (needs cgo/libei bindings);
// uinput works on both X11 and Wayland compositors that read kernel input.
//
// uinput ioctl constants (linux/uinput.h, linux/input.h).
const (
	uiSetEvBit   = 0x40045564 // UI_SET_EVBIT
	uiSetKeyBit  = 0x40045565 // UI_SET_KEYBIT
	uiSetRelBit  = 0x40045566 // UI_SET_RELBIT
	uiDevCreate  = 0x5501     // UI_DEV_CREATE
	uiDevDestroy = 0x5502     // UI_DEV_DESTROY

	evSyn = 0x00
	evKey = 0x01
	evRel = 0x02

	relX     = 0x00
	relY     = 0x01
	relWheel = 0x08

	btnLeft   = 0x110
	btnRight  = 0x111
	btnMiddle = 0x112

	synReport = 0x00
)

type linuxInjector struct {
	f *os.File
}

// NewInjector opens /dev/uinput and registers a virtual pointer+keyboard.
func NewInjector() Injector {
	f, err := os.OpenFile("/dev/uinput", os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		return NoopInjector{}
	}
	inj := &linuxInjector{f: f}
	if err := inj.setup(); err != nil {
		f.Close()
		return NoopInjector{}
	}
	return inj
}

func ioctl(fd, req, arg uintptr) error {
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, req, arg); errno != 0 {
		return fmt.Errorf("ioctl 0x%x: errno %d", req, errno)
	}
	return nil
}

func (l *linuxInjector) setup() error {
	fd := l.f.Fd()
	// Enable relative pointer, buttons, wheel, and a keyboard key range.
	if err := ioctl(fd, uiSetEvBit, evRel); err != nil {
		return err
	}
	for _, r := range []uintptr{relX, relY, relWheel} {
		if err := ioctl(fd, uiSetRelBit, r); err != nil {
			return err
		}
	}
	if err := ioctl(fd, uiSetEvBit, evKey); err != nil {
		return err
	}
	for _, b := range []uintptr{btnLeft, btnRight, btnMiddle} {
		if err := ioctl(fd, uiSetKeyBit, b); err != nil {
			return err
		}
	}
	for k := uintptr(1); k < 128; k++ { // common keyboard keys
		_ = ioctl(fd, uiSetKeyBit, k)
	}

	// uinput_user_dev: name[80] + input_id(8) + ff_effects_max(4) + absmax/min/fuzz/flat.
	var dev [80 + 8 + 4 + 4*64*4]byte
	copy(dev[:], "Conduit Virtual Input")
	binary.LittleEndian.PutUint16(dev[80:], 0x03) // BUS_VIRTUAL
	if _, err := l.f.Write(dev[:]); err != nil {
		return err
	}
	return ioctl(fd, uiDevCreate, 0)
}

func (l *linuxInjector) emit(typ, code uint16, value int32) error {
	// struct input_event { timeval(16) ; u16 type ; u16 code ; s32 value } on 64-bit.
	var ev [24]byte
	binary.LittleEndian.PutUint16(ev[16:], typ)
	binary.LittleEndian.PutUint16(ev[18:], code)
	binary.LittleEndian.PutUint32(ev[20:], uint32(value))
	_, err := l.f.Write(ev[:])
	return err
}

func (l *linuxInjector) sync() error { return l.emit(evSyn, synReport, 0) }

func (l *linuxInjector) Available() bool { return l.f != nil }
func (l *linuxInjector) Backend() string { return "uinput" }

func (l *linuxInjector) Inject(ev wire.InputEventBody) error {
	switch ev.Kind {
	case "move":
		if ev.Dx != nil {
			l.emit(evRel, relX, int32(*ev.Dx))
		}
		if ev.Dy != nil {
			l.emit(evRel, relY, int32(*ev.Dy))
		}
		return l.sync()
	case "scroll":
		if ev.Dy != nil {
			l.emit(evRel, relWheel, int32(*ev.Dy/10))
		}
		return l.sync()
	case "click":
		code := uint16(btnLeft)
		if ev.Button != nil {
			switch *ev.Button {
			case "right":
				code = btnRight
			case "middle":
				code = btnMiddle
			}
		}
		action := "tap"
		if ev.Action != nil {
			action = *ev.Action
		}
		switch action {
		case "down":
			l.emit(evKey, code, 1)
		case "up":
			l.emit(evKey, code, 0)
		default:
			l.emit(evKey, code, 1)
			l.sync()
			l.emit(evKey, code, 0)
		}
		return l.sync()
	}
	return nil
}

func (l *linuxInjector) Close() error {
	if l.f != nil {
		ioctl(l.f.Fd(), uiDevDestroy, 0)
		err := l.f.Close()
		l.f = nil
		return err
	}
	return nil
}
