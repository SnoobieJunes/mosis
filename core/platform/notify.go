package platform

// NotificationSource watches the OS for notifications and calls Emit for each,
// so the daemon can mirror them to paired peers (spec §9 Phase 4 step 5).
//
// Runtime backends are platform-specific and device-gated:
//   - Linux: monitor the D-Bus org.freedesktop.Notifications interface.
//   - Windows: WinRT UserNotificationListener (needs packaging identity — MSIX
//     or a sparse package; budget packaging time, not code — spec pitfall).
//
// Both require their OS to validate; this interface + the no-op keep the core
// portable. A concrete Linux D-Bus watcher is a follow-up that adds a godbus
// dependency (kept out of the core so it builds offline).
type Notification struct {
	AppName string
	Title   string
	Body    string
	ID      string
}

type NotificationSource interface {
	// Start begins watching; emit is called per notification. Returns whether
	// sourcing is actually available on this host.
	Start(emit func(Notification)) bool
	Stop()
}

// NoopNotificationSource is used where sourcing isn't wired up yet.
type NoopNotificationSource struct{}

func (NoopNotificationSource) Start(func(Notification)) bool { return false }
func (NoopNotificationSource) Stop()                         {}

// NewNotificationSource returns the platform default. Today every platform
// returns the no-op; the Linux D-Bus and Windows WinRT backends land with
// their OS validation (they can only be tested on the target OS).
func NewNotificationSource() NotificationSource { return NoopNotificationSource{} }
