//go:build !linux && !windows

package platform

// NewInjector returns a no-op injector on platforms without an implementation
// (macOS daemon — the Mac app injects via CGEvent instead; see docs/adr/0005).
func NewInjector() Injector { return NoopInjector{} }
