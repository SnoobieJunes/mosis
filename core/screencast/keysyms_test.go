package screencast

import (
	"reflect"
	"testing"
)

// Keysym constants used by the tests (X11/keysymdef.h values).
const (
	xkA      = 0x0061 // 'a'
	xkAupper = 0x0041 // 'A'
	xk1      = 0x0031 // '1'
	xkExclam = 0x0021 // '!'
	xkReturn = 0xff0d
	xkLeft   = 0xff51
	xkF11    = 0xffc8
	xkShiftL = 0xffe1
	xkSpace  = 0x0020
	xkEuro   = 0x01000000 | 0x20AC // Unicode keysym for €
)

func TestSpecialKeysUseTheFrozenNameList(t *testing.T) {
	cases := map[uint32]string{
		xkReturn: "return", 0xff8d: "return", 0xff09: "tab", 0xff08: "backspace",
		0xffff: "delete_forward", 0xff1b: "escape",
		xkLeft: "left", 0xff52: "up", 0xff53: "right", 0xff54: "down",
		0xff50: "home", 0xff57: "end", 0xff55: "page_up", 0xff56: "page_down",
		0xffbe: "f1", xkF11: "f11", 0xffc9: "f12",
	}
	for ks, want := range cases {
		wk, ok := TranslateKey(ks, 0, 0)
		if !ok || wk.Key != want || wk.Text != "" {
			t.Fatalf("keysym %#x: got %+v ok=%v, want key %q", ks, wk, ok, want)
		}
	}
}

func TestPlainAndShiftedText(t *testing.T) {
	wk, ok := TranslateKey(xkA, xkAupper, 0)
	if !ok || wk.Text != "a" || len(wk.Modifiers) != 0 {
		t.Fatalf("plain a: %+v", wk)
	}
	// Shift alone: the SHIFTED character travels (capitals must arrive as
	// capitals — the receivers insert literal text), with shift in the set.
	wk, ok = TranslateKey(xkA, xkAupper, xShiftMask)
	if !ok || wk.Text != "A" || !reflect.DeepEqual(wk.Modifiers, []string{"shift"}) {
		t.Fatalf("shift+a: %+v", wk)
	}
	// Shifted digit row.
	wk, _ = TranslateKey(xk1, xkExclam, xShiftMask)
	if wk.Text != "!" {
		t.Fatalf("shift+1: %+v", wk)
	}
	// NoSymbol shifted column on an alphabetic key case-converts (X11 rule).
	wk, _ = TranslateKey(xkA, 0, xShiftMask)
	if wk.Text != "A" {
		t.Fatalf("case-convert fallback: %+v", wk)
	}
}

// Under a non-shift chord the UNSHIFTED character travels — ⌘⇧Z arrives as
// "z" + [command, shift], which the receiver's shortcut matching needs
// (matches the Swift controllers).
func TestChordsCarryTheUnshiftedCharacter(t *testing.T) {
	wk, ok := TranslateKey(0x007A, 0x005A, xShiftMask|xMod4Mask) // z / Z
	if !ok || wk.Text != "z" {
		t.Fatalf("cmd+shift+z: %+v", wk)
	}
	if !reflect.DeepEqual(wk.Modifiers, []string{"shift", "command"}) {
		t.Fatalf("modifiers: %v", wk.Modifiers)
	}
	wk, _ = TranslateKey(0x0063, 0x0043, xControlMask) // ctrl+c
	if wk.Text != "c" || !reflect.DeepEqual(wk.Modifiers, []string{"control"}) {
		t.Fatalf("ctrl+c: %+v", wk)
	}
}

func TestModifierKeysProduceNoEvent(t *testing.T) {
	if _, ok := TranslateKey(xkShiftL, 0, xShiftMask); ok {
		t.Fatalf("a modifier key must not travel as its own event (stateless rule)")
	}
}

func TestSpaceIsTextAndUnicodeWorks(t *testing.T) {
	wk, ok := TranslateKey(xkSpace, xkSpace, 0)
	if !ok || wk.Text != " " {
		t.Fatalf("space: %+v", wk)
	}
	wk, ok = TranslateKey(xkEuro, 0, 0)
	if !ok || wk.Text != "€" {
		t.Fatalf("unicode keysym: %+v", wk)
	}
}

func TestModifierMaskMapping(t *testing.T) {
	got := WireModifiers(xShiftMask | xControlMask | xMod1Mask | xMod4Mask)
	want := []string{"shift", "control", "option", "command"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("modifiers: %v", got)
	}
	// CapsLock and NumLock have no wire meaning.
	if mods := WireModifiers(xLockMask | 1<<4); mods != nil {
		t.Fatalf("lock masks leaked: %v", mods)
	}
}
