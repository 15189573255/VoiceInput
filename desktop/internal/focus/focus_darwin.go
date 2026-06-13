//go:build darwin

package focus

/*
#cgo LDFLAGS: -framework AppKit

#include <stdlib.h>

// Implemented in workspace_darwin.m (AppKit). Each returns a newly malloc'd
// UTF-8 string (caller frees) or NULL when no app is frontmost.
char *mac_frontmost_name(void);     // localized display name
char *mac_frontmost_process(void);  // executable basename
*/
import "C"

import "unsafe"

type macDetector struct{}

func newPlatform() Detector { return &macDetector{} }

func (macDetector) Current() Info {
	return Info{
		AppName:     cStringOrEmpty(C.mac_frontmost_name()),
		ProcessName: cStringOrEmpty(C.mac_frontmost_process()),
	}
}

func (macDetector) Close() error { return nil }

// cStringOrEmpty converts a malloc'd C string to a Go string and frees it,
// yielding "" when the pointer is NULL.
func cStringOrEmpty(c *C.char) string {
	if c == nil {
		return ""
	}
	defer C.free(unsafe.Pointer(c))
	return C.GoString(c)
}
