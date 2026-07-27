package screencast

import "unicode"

// X11 keysym → wire key-event translation. Kept portable (keysyms are just
// numbers) so the mapping is unit-tested on any OS even though only the Linux
// window layer produces them.
//
// The wire convention is frozen by InputMessages.swift: exactly one of `key`
// (a special-key name from the shared list: return, tab, escape, backspace,
// delete_forward, up, down, left, right, home, end, page_up, page_down,
// f1…f12) or `text` (literal characters), plus the COMPLETE modifier set on
// every event (stateless by design — a lost message can never wedge a
// modifier).
//
// Character choice under modifiers follows the Swift controllers with one
// deliberate divergence, recorded in docs/plans/09: under a non-shift chord
// (control/option/command) the UNSHIFTED character is sent — ⌘⇧Z travels as
// "z" + [command, shift], which shortcut matching on the receiver needs. But
// with SHIFT alone this viewer sends the shifted character ("Z" + [shift]),
// where Swift sends the unshifted one; the receivers' text injection inserts
// the literal text, so Swift's choice would type lowercase for every
// capital. Swift's own path is device-unverified (loop-state.md), so this
// follows the receiver's actual semantics rather than mimicking bytes.

// X11 core modifier mask bits (X11/X.h).
const (
	xShiftMask   = 1 << 0
	xLockMask    = 1 << 1 // CapsLock — not translated in v1 (no wire concept)
	xControlMask = 1 << 2
	xMod1Mask    = 1 << 3 // Alt
	xMod4Mask    = 1 << 6 // Super/Windows key
)

// WireModifiers maps an X11 state mask to wire modifier names. Alt → option
// and Super → command: the receiver vocabularies are Mac-shaped
// (InputModifier), and this is the mapping a Linux hand expects when driving
// a Mac. "function" has no X11 core equivalent and is never sent.
func WireModifiers(state uint16) []string {
	var out []string
	if state&xShiftMask != 0 {
		out = append(out, "shift")
	}
	if state&xControlMask != 0 {
		out = append(out, "control")
	}
	if state&xMod1Mask != 0 {
		out = append(out, "option")
	}
	if state&xMod4Mask != 0 {
		out = append(out, "command")
	}
	return out
}

// specialKeysyms is the keysym → frozen special-name table.
var specialKeysyms = map[uint32]string{
	0xff0d: "return", // XK_Return
	0xff8d: "return", // XK_KP_Enter
	0xff09: "tab",    // XK_Tab
	0xfe20: "tab",    // XK_ISO_Left_Tab (shift+tab; shift rides in modifiers)
	0xff08: "backspace",
	0xffff: "delete_forward", // XK_Delete deletes forward on PC keyboards
	0xff1b: "escape",
	0xff51: "left",
	0xff52: "up",
	0xff53: "right",
	0xff54: "down",
	0xff50: "home",
	0xff57: "end",
	0xff55: "page_up",   // XK_Prior
	0xff56: "page_down", // XK_Next
	// Keypad navigation (NumLock off).
	0xff95: "home", 0xff96: "left", 0xff97: "up", 0xff98: "right",
	0xff99: "down", 0xff9a: "page_up", 0xff9b: "page_down", 0xff9c: "end",
	0xff9f: "delete_forward",
}

func init() {
	// XK_F1 (0xffbe) … XK_F12 (0xffc9).
	names := []string{"f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"}
	for i, n := range names {
		specialKeysyms[0xffbe+uint32(i)] = n
	}
}

// keypadChars: keypad keysyms that produce characters.
var keypadChars = map[uint32]rune{
	0xff80: ' ', 0xffaa: '*', 0xffab: '+', 0xffac: ',', 0xffad: '-',
	0xffae: '.', 0xffaf: '/', 0xffbd: '=',
}

// keysymRune converts a keysym to the character it produces, if any.
func keysymRune(ks uint32) (rune, bool) {
	switch {
	case ks >= 0x20 && ks <= 0x7e: // ASCII
		return rune(ks), true
	case ks >= 0xa0 && ks <= 0xff: // Latin-1
		return rune(ks), true
	case ks&0xff000000 == 0x01000000: // Unicode keysym: U+xxxx | 0x01000000
		r := rune(ks & 0x00ffffff)
		if unicode.IsPrint(r) {
			return r, true
		}
		return 0, false
	case ks >= 0xffb0 && ks <= 0xffb9: // KP_0…KP_9
		return rune('0' + (ks - 0xffb0)), true
	default:
		if r, ok := keypadChars[ks]; ok {
			return r, true
		}
		return 0, false
	}
}

// isModifierKeysym: keys that ARE modifiers produce no event of their own —
// their state travels on every other event instead (stateless rule).
func isModifierKeysym(ks uint32) bool {
	return ks >= 0xffe1 && ks <= 0xffee // Shift_L … Hyper_R
}

// WireKey is one translated key event ready for the wire.
type WireKey struct {
	Key       string // special-key name (exclusive with Text)
	Text      string
	Modifiers []string
}

// TranslateKey turns an X11 key press into a wire key event.
// unshifted/shifted are the keycode's keysym columns 0 and 1 from the
// keyboard mapping (X11 rule: a NoSymbol shifted column on an alphabetic key
// means "case-convert column 0"). Returns ok=false for modifier keys and
// keys with no wire meaning.
func TranslateKey(unshifted, shifted uint32, state uint16) (WireKey, bool) {
	if isModifierKeysym(unshifted) {
		return WireKey{}, false
	}
	mods := WireModifiers(state)

	// Special keys first; the name is the same in either column, except
	// ISO_Left_Tab which only appears shifted.
	if name, ok := specialKeysyms[unshifted]; ok {
		return WireKey{Key: name, Modifiers: mods}, true
	}
	if state&xShiftMask != 0 {
		if name, ok := specialKeysyms[shifted]; ok {
			return WireKey{Key: name, Modifiers: mods}, true
		}
	}

	chord := state&(xControlMask|xMod1Mask|xMod4Mask) != 0
	var r rune
	var ok bool
	switch {
	case chord:
		// Shortcut chords carry the unshifted character (⌘⇧Z = "z" +
		// [command, shift]) so the receiver's shortcut matching sees the key,
		// not an already-shifted glyph it would shift again.
		r, ok = keysymRune(unshifted)
	case state&xShiftMask != 0:
		r, ok = keysymRune(shifted)
		if !ok {
			// NoSymbol shifted column on an alphabetic key: case-convert.
			if base, baseOK := keysymRune(unshifted); baseOK {
				r, ok = unicode.ToUpper(base), true
			}
		}
	default:
		r, ok = keysymRune(unshifted)
	}
	if !ok {
		return WireKey{}, false
	}
	return WireKey{Text: string(r), Modifiers: mods}, true
}
