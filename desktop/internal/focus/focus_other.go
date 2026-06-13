//go:build !windows && !darwin

package focus

// Stub for Linux (macOS is implemented in focus_darwin.go). The production
// implementation would use Xlib _NET_ACTIVE_WINDOW (X11) or
// wlr-foreign-toplevel-management (Wayland).

type stubDetector struct{}

func newPlatform() Detector { return &stubDetector{} }

func (stubDetector) Current() Info { return Info{} }
func (stubDetector) Close() error  { return nil }
