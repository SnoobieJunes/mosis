//go:build linux

package platform

// Linux key codes (linux/input-event-codes.h) and the mapping from the wire's
// key vocabulary onto them.
//
// Added 2026-08-17. The uinput injector had no `kind:"key"` case at all: every
// keystroke a peer sent was accepted, acknowledged and silently dropped, which
// docs/linux.md recorded as a known gap and nothing fixed. The names below are
// exactly the ones MacInputInjector.virtualKey(for:) accepts, so a controller
// does not have to know which OS it is driving.
//
// Layout caveat, stated rather than hidden: this is a US QWERTY table. A uinput
// device reports key *positions*, and the compositor applies the user's layout —
// so on a non-US layout the character produced may differ from the character
// sent. Correct handling needs the peer's layout, or XKB on this side, and is
// still outstanding (see todo.md).
const (
	keyEsc        = 1
	key1          = 2
	keyMinus      = 12
	keyEqual      = 13
	keyBackspace  = 14
	keyTab        = 15
	keyQ          = 16
	keyLeftBrace  = 26
	keyRightBrace = 27
	keyEnter      = 28
	keyLeftCtrl   = 29
	keyA          = 30
	keySemicolon  = 39
	keyApostrophe = 40
	keyGrave      = 41
	keyLeftShift  = 42
	keyBackslash  = 43
	keyZ          = 44
	keyComma      = 51
	keyDot        = 52
	keySlash      = 53
	keyLeftAlt    = 56
	keySpace      = 57
	keyF1         = 59
	keyDelete     = 111
	keyLeftMeta   = 125
)

// namedKeys maps the protocol's special-key names to key codes.
var namedKeys = map[string]uint16{
	"return": keyEnter, "enter": keyEnter,
	"tab":   keyTab,
	"space": keySpace,
	// The wire calls the backwards-erasing key "delete" (Apple's naming) and
	// "backspace"; forward delete is separate. Getting this pair backwards
	// erases the wrong character, so both spellings are pinned deliberately.
	"delete": keyBackspace, "backspace": keyBackspace,
	"delete_forward": keyDelete,
	"escape":         keyEsc,
	"up":             103, "down": 108, "left": 105, "right": 106,
	"home": 102, "end": 107, "page_up": 104, "page_down": 109,
	"f1": keyF1, "f2": 60, "f3": 61, "f4": 62, "f5": 63, "f6": 64,
	"f7": 65, "f8": 66, "f9": 67, "f10": 68, "f11": 87, "f12": 88,
}

// modifierKeys maps the wire's modifier names to key codes. "function" has no
// injectable equivalent on Linux and is dropped rather than guessed at.
var modifierKeys = map[string]uint16{
	"shift":   keyLeftShift,
	"control": keyLeftCtrl,
	"option":  keyLeftAlt,
	"command": keyLeftMeta,
}

// unshifted maps a character to its US-layout key position.
var unshifted = map[rune]uint16{
	'1': key1, '2': 3, '3': 4, '4': 5, '5': 6, '6': 7, '7': 8, '8': 9, '9': 10, '0': 11,
	'-': keyMinus, '=': keyEqual, '[': keyLeftBrace, ']': keyRightBrace,
	';': keySemicolon, '\'': keyApostrophe, '`': keyGrave, '\\': keyBackslash,
	',': keyComma, '.': keyDot, '/': keySlash, ' ': keySpace,
	'\n': keyEnter, '\r': keyEnter, '\t': keyTab,
	'q': keyQ, 'w': 17, 'e': 18, 'r': 19, 't': 20, 'y': 21, 'u': 22, 'i': 23, 'o': 24, 'p': 25,
	'a': keyA, 's': 31, 'd': 32, 'f': 33, 'g': 34, 'h': 35, 'j': 36, 'k': 37, 'l': 38,
	'z': keyZ, 'x': 45, 'c': 46, 'v': 47, 'b': 48, 'n': 49, 'm': 50,
}

// shifted maps a character that needs Shift to the key position it sits on.
var shifted = map[rune]uint16{
	'!': key1, '@': 3, '#': 4, '$': 5, '%': 6, '^': 7, '&': 8, '*': 9, '(': 10, ')': 11,
	'_': keyMinus, '+': keyEqual, '{': keyLeftBrace, '}': keyRightBrace,
	':': keySemicolon, '"': keyApostrophe, '~': keyGrave, '|': keyBackslash,
	'<': keyComma, '>': keyDot, '?': keySlash,
}

// keyForRune returns the key position for a character and whether Shift is
// needed. Capitals go through the shifted path, matching what a real keyboard
// does — note plan 09 records that Swift takes a different route for capitals;
// this side does not copy that, deliberately.
func keyForRune(r rune) (code uint16, needsShift bool, ok bool) {
	if c, hit := unshifted[r]; hit {
		return c, false, true
	}
	if c, hit := shifted[r]; hit {
		return c, true, true
	}
	if r >= 'A' && r <= 'Z' {
		if c, hit := unshifted[r+('a'-'A')]; hit {
			return c, true, true
		}
	}
	return 0, false, false
}
