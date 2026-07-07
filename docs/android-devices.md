# Android tested-devices table

Wi-Fi Aware and the BluetoothHidDevice profile are OEM-flavored on Android
(spec §9 Phase 5 pitfall: "keep a tested-devices table in docs"). Record real
results here as devices are tested; don't infer support from Android version
alone — it's hardware/vendor-dependent.

## Wi-Fi Aware (`FEATURE_WIFI_AWARE`)

| Device | Android | Aware feature present | Android↔Android data path | Notes |
|---|---|---|---|---|
| — | — | — | — | Pixel 6+ and recent flagships generally report the feature; many mid-range don't. |

## Bluetooth HID peripheral (`BluetoothHidDevice`, API 28+)

The phone-as-BT-keyboard/trackpad feature. API is present on all API 28+, but
whether a given host accepts the combo HID descriptor varies.

| Phone | Android | Host tested | Keyboard | Trackpad | Notes |
|---|---|---|---|---|---|
| — | — | iPad / Apple TV / PC | — | — | Acceptance: type into an iPad with Conduit NOT installed on it. |

## Capability services

| Capability | API | Notes |
|---|---|---|
| Input receiver | `AccessibilityService#dispatchGesture` | Play review scrutiny; gated off by default, honest declaration in `accessibility_service_config.xml`. |
| Notification source | `NotificationListenerService` | Per-app filtering; user-enabled in settings. |
| Screen source | `MediaProjection` + `MediaCodec` | System consent dialog every session (by design). |
