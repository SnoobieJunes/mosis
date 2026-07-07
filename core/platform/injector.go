// Package platform holds OS-specific capabilities for the Go daemons: input
// injection (spec §9 Phase 4 steps 3-4) and notification sourcing. Each OS gets
// a build-tagged file; unsupported platforms get a no-op so the core stays
// portable and cross-compiles everywhere.
package platform

import "github.com/auston/conduit-core/wire"

// Injector applies remote input events to the local OS.
type Injector interface {
	// Available reports whether injection can actually run here (e.g. Wayland
	// portal granted, or /dev/uinput writable). If false, the daemon must not
	// advertise input-inject.
	Available() bool
	Inject(ev wire.InputEventBody) error
	Close() error
	// Which mechanism is in use, for the daemon's status line.
	Backend() string
}

// NoopInjector is used where injection isn't implemented (macOS daemon, etc.).
type NoopInjector struct{}

func (NoopInjector) Available() bool                  { return false }
func (NoopInjector) Inject(wire.InputEventBody) error { return nil }
func (NoopInjector) Close() error                     { return nil }
func (NoopInjector) Backend() string                  { return "none" }
