//go:build darwin

package inject

/*
#cgo LDFLAGS: -framework CoreGraphics -framework ApplicationServices -framework AppKit

#include <stdint.h>
#include <stdlib.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>

// Pasteboard helpers implemented in pasteboard_darwin.m (AppKit).
char *mac_clipboard_get(void);
void  mac_clipboard_set(const char *utf8);

// mac_post_key posts a key-down or key-up for a virtual keycode with the given
// modifier flags applied (0 for none).
static void mac_post_key(int key, unsigned long long flags, int down) {
	CGEventRef e = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)key, down ? true : false);
	if (e == NULL) {
		return;
	}
	if (flags != 0) {
		CGEventSetFlags(e, (CGEventFlags)flags);
	}
	CGEventPost(kCGHIDEventTap, e);
	CFRelease(e);
}

// mac_post_unicode posts a keyboard event carrying a UTF-16 unit sequence as a
// Unicode string, so the active input field / IME sees a normal character.
static void mac_post_unicode(uint16_t *units, int n, int down) {
	CGEventRef e = CGEventCreateKeyboardEvent(NULL, 0, down ? true : false);
	if (e == NULL) {
		return;
	}
	CGEventKeyboardSetUnicodeString(e, (UniCharCount)n, (const UniChar *)units);
	CGEventPost(kCGHIDEventTap, e);
	CFRelease(e);
}

// mac_ax_trusted reports whether the process currently has Accessibility trust,
// which CGEventPost requires to deliver synthetic events. No prompt.
static int mac_ax_trusted(void) {
	return AXIsProcessTrusted() ? 1 : 0;
}

// mac_ax_prompt_trusted is like mac_ax_trusted but also raises the system
// Accessibility authorization prompt when not yet trusted, adding the app to
// the list under System Settings.
static int mac_ax_prompt_trusted(void) {
	const void *keys[] = {kAXTrustedCheckOptionPrompt};
	const void *vals[] = {kCFBooleanTrue};
	CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	Boolean trusted = AXIsProcessTrustedWithOptions(opts);
	CFRelease(opts);
	return trusted ? 1 : 0;
}
*/
import "C"

import (
	"fmt"
	"strings"
	"time"
	"unicode/utf16"
	"unsafe"
)

// macOS virtual keycodes (Carbon kVK_*). Letter codes are positional ANSI.
const (
	macReturn        = 0x24
	macTab           = 0x30
	macSpace         = 0x31
	macDelete        = 0x33 // backspace
	macForwardDelete = 0x75
	macEscape        = 0x35
	macLeftArrow     = 0x7B
	macRightArrow    = 0x7C
	macDownArrow     = 0x7D
	macUpArrow       = 0x7E
	macKeyA          = 0x00
	macKeyV          = 0x09
)

// macOS event modifier flag masks (CGEventFlags).
const (
	flagShift   = 0x00020000
	flagControl = 0x00040000
	flagOption  = 0x00080000
	flagCommand = 0x00100000
)

// macLetterKeycodes maps a..z to their positional ANSI virtual keycodes.
var macLetterKeycodes = map[byte]int{
	'a': 0x00, 'b': 0x0B, 'c': 0x08, 'd': 0x02, 'e': 0x0E, 'f': 0x03,
	'g': 0x05, 'h': 0x04, 'i': 0x22, 'j': 0x26, 'k': 0x28, 'l': 0x25,
	'm': 0x2E, 'n': 0x2D, 'o': 0x1F, 'p': 0x23, 'q': 0x0C, 'r': 0x0F,
	's': 0x01, 't': 0x11, 'u': 0x20, 'v': 0x09, 'w': 0x0D, 'x': 0x07,
	'y': 0x10, 'z': 0x06,
}

type macInjector struct{}

func newPlatform() Injector {
	// Trigger the Accessibility authorization prompt early (no-op if already
	// trusted) so the user can grant permission before the first injection.
	C.mac_ax_prompt_trusted()
	return &macInjector{}
}

// ensureTrusted re-checks Accessibility trust before every injection so a grant
// made after launch takes effect without a restart.
func ensureTrusted() error {
	if C.mac_ax_trusted() == 0 {
		return ErrAccessibilityNotTrusted
	}
	return nil
}

func postKey(key int, flags uint64, down bool) {
	d := C.int(0)
	if down {
		d = 1
	}
	C.mac_post_key(C.int(key), C.ulonglong(flags), d)
}

func tapKey(key int, flags uint64) {
	postKey(key, flags, true)
	postKey(key, flags, false)
}

func (m *macInjector) Type(text string) error {
	if err := ensureTrusted(); err != nil {
		return err
	}
	for _, r := range text {
		units := utf16.Encode([]rune{r})
		if len(units) == 0 {
			continue
		}
		ptr := (*C.uint16_t)(unsafe.Pointer(&units[0]))
		n := C.int(len(units))
		C.mac_post_unicode(ptr, n, 1)
		C.mac_post_unicode(ptr, n, 0)
	}
	return nil
}

func (m *macInjector) Paste(text string) error {
	if err := ensureTrusted(); err != nil {
		return err
	}
	saved := getClipboardText() // best-effort; nil when no text content
	setClipboardText(text)

	tapKey(macKeyV, flagCommand)

	// Give the target app a moment to consume the paste before restoring,
	// otherwise the restored content can race in mid-paste.
	time.Sleep(200 * time.Millisecond)
	if saved != nil {
		setClipboardText(*saved)
	}
	return nil
}

func (m *macInjector) Inject(text string, mode Mode, threshold int) error {
	if text == "" {
		return nil
	}
	switch mode {
	case ModeType:
		return m.Type(text)
	case ModePaste:
		return m.Paste(text)
	default:
		if threshold <= 0 {
			threshold = DefaultThreshold
		}
		if len([]rune(text)) <= threshold {
			return m.Type(text)
		}
		return m.Paste(text)
	}
}

func (m *macInjector) Clear() error {
	if err := ensureTrusted(); err != nil {
		return err
	}
	tapKey(macKeyA, flagCommand) // Cmd+A select-all
	tapKey(macDelete, 0)         // Backspace deletes the selection
	return nil
}

func (m *macInjector) PressKey(spec string) error {
	if err := ensureTrusted(); err != nil {
		return err
	}
	// Accept either a bare key name ("enter") or a chord ("ctrl+enter",
	// "cmd+shift+enter", …). The last segment is the main key; preceding
	// segments are modifiers applied while the key fires.
	parts := strings.Split(strings.ToLower(strings.TrimSpace(spec)), "+")
	if len(parts) == 0 || parts[0] == "" {
		return nil
	}
	mainKey, err := keyNameToMac(strings.TrimSpace(parts[len(parts)-1]))
	if err != nil {
		return err
	}
	var flags uint64
	for _, mod := range parts[:len(parts)-1] {
		f, err := modifierToFlag(strings.TrimSpace(mod))
		if err != nil {
			return err
		}
		flags |= f
	}
	tapKey(mainKey, flags)
	return nil
}

func keyNameToMac(name string) (int, error) {
	switch name {
	case "enter", "return":
		return macReturn, nil
	case "tab":
		return macTab, nil
	case "space":
		return macSpace, nil
	case "backspace", "back":
		return macDelete, nil
	case "delete", "del":
		return macForwardDelete, nil
	case "escape", "esc":
		return macEscape, nil
	case "up":
		return macUpArrow, nil
	case "down":
		return macDownArrow, nil
	case "left":
		return macLeftArrow, nil
	case "right":
		return macRightArrow, nil
	}
	if len(name) == 1 {
		if code, ok := macLetterKeycodes[name[0]]; ok {
			return code, nil
		}
	}
	return 0, fmt.Errorf("unsupported key name: %q", name)
}

func modifierToFlag(name string) (uint64, error) {
	switch name {
	case "ctrl", "control":
		return flagControl, nil
	case "alt", "menu", "option":
		return flagOption, nil
	case "shift":
		return flagShift, nil
	case "cmd", "win", "super", "meta", "command":
		return flagCommand, nil
	}
	return 0, fmt.Errorf("unsupported modifier: %q", name)
}

// getClipboardText returns the current clipboard text, or nil when the
// clipboard holds no string content (mirrors the Windows save semantics).
func getClipboardText() *string {
	c := C.mac_clipboard_get()
	if c == nil {
		return nil
	}
	defer C.free(unsafe.Pointer(c))
	s := C.GoString(c)
	return &s
}

func setClipboardText(text string) {
	c := C.CString(text)
	defer C.free(unsafe.Pointer(c))
	C.mac_clipboard_set(c)
}
