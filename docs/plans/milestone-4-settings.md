# Milestone 4: settings that persist and update live

Design brief for milestone 4 of [the daily driver plan](2026-09-13-daily-driver.md).
Builds on milestones 1 to 3. Part A is delegated; part B (the Settings window
redesign) is implemented by the orchestrator after part A lands.

## Outcome

- Every setting persists the moment it changes. Nothing is lost by closing
  the window.
- Prompt, dictionary, and language changes reach the live session through
  `session.update` with a short debounce. Only an API key change reconnects.
- The app knows whether Input Monitoring is granted, can launch at login, and
  records from a chosen input device, surviving device changes.
- Connection status and validation errors are separate signals.

## Part A (delegated)

### Core

`RealtimeSessionConfiguration`:

- Replace `language: String` with `languages: [String]`. The encoder sends
  `"languages": configuration.languages`. An empty array omits the key.
- Add `public static let supportedLanguages: [(code: String, name: String)]`
  in a new `TranscriptionLanguages.swift` covering the ISO-639-1 codes the
  docs list for `gpt-live-transcribe`; if the docs do not enumerate them, use
  the Whisper language set, which the API accepts. Keep names in English.

`SettingsStore` protocol in `HubrisVoiceCore`:

```swift
public protocol SettingsStore: AnyObject, Sendable {
  func string(_ key: String) -> String?
  func stringArray(_ key: String) -> [String]?
  func bool(_ key: String) -> Bool?
  func set(_ value: Any?, for key: String)
}
public struct DictationSettings: Equatable, Sendable {
  public var languages: [String]          // default ["en"]
  public var prompt: String
  public var dictionary: [String]
  public var overlayPlacement: OverlayPlacementPreference
  public var smartLeadingSpace, trailingSpace, adjustCaseAfterComma: Bool
  public var inputDeviceUID: String?      // nil means system default
  public var launchAtLogin: Bool
  public static func load(from store: SettingsStore) -> DictationSettings
  public func save(to store: SettingsStore)
  public var sessionConfiguration: RealtimeSessionConfiguration { get }  // delay .low
}
```

The app conforms `UserDefaults` to `SettingsStore`. Keys stay as they are
today plus `audio.inputDeviceUID` and `app.launchAtLogin`.

`ConfigurationUpdatePolicy` in the core: a tiny value type that decides
whether a settings change needs `reconnect`, `sessionUpdate`, or `nothing`
given the old and new `DictationSettings` and whether the API key changed.
API key change → reconnect. Any change to `sessionConfiguration` →
sessionUpdate. Otherwise nothing.

### App: live `session.update`

- `RealtimeTranscriptionClient.updateSession(_:)` sends `session.update` on
  the live socket. It is a no-op when not ready.
- `AppModel` holds `settings: DictationSettings` as the single source of
  truth for those fields. Each `@Published` setting the views bind to writes
  through to `settings`, saves, and runs `ConfigurationUpdatePolicy`.
  `sessionUpdate` is debounced 500 ms with `DelayedActionScheduler` and, if
  a snippet is listening or pending, deferred until the session is idle.
  `reconnect` behaves as today's `saveSettings`.
- Track `configurationState: .applied | .pending | .failed(String)` for the
  status row: `.pending` when an update is scheduled or sent, `.applied` on
  the next `session.updated`, `.failed` on a server `error` that arrives
  while pending.
- `DictationSession` needs no change. `session.updated` while `.ready` is
  already ignored by the session; the model observes it for
  `configurationState` before forwarding.
- Remove `saveSettings` as the general persistence path. Keep an explicit
  `saveAPIKey()` for the key field.

### App: permissions

- `PermissionService.inputMonitoring: Bool` via `CGPreflightListenEventAccess()`
  and `requestInputMonitoring()` via `CGRequestListenEventAccess()`.
- `PermissionService.openSystemSettings(for: .microphone | .accessibility | .inputMonitoring)`
  opening the matching `x-apple.systempreferences:com.apple.preference.security?Privacy_…` URL.
- `AppModel.refreshPermissions` includes Input Monitoring. Add
  `startPermissionPolling()` and `stopPermissionPolling()` that refresh
  every 2 s; the settings view calls them on appear and disappear.

### App: launch at login

- `LoginItemService` wrapping `SMAppService.mainApp`: `status`,
  `register()`, `unregister()`. `AppModel.launchAtLogin` reflects
  `status == .enabled` on read and calls register or unregister on set;
  `requiresApproval` exposes the `.requiresApproval` status so the UI can
  say so.

### App: audio device lifecycle

`AudioCapture` changes:

- `var preferredDeviceUID: String?`. On `start()`, resolve the UID to an
  `AudioDeviceID` with `kAudioHardwarePropertyDevices` and
  `kAudioDevicePropertyDeviceUID`; fall back to the default input device
  when missing. Apply it with `kAudioOutputUnitProperty_CurrentDevice` on
  `engine.inputNode.audioUnit` before installing the tap.
- Observe `AVAudioEngineConfigurationChange` on the engine. On change while
  running: remove the tap, rebuild the converter from the new input format,
  reinstall the tap, restart the engine. If the rebuild fails, call
  `onError`.
- Observe `kAudioHardwarePropertyDefaultInputDevice` and
  `kAudioHardwarePropertyDevices` with `AudioObjectAddPropertyListenerBlock`
  to publish `onDevicesChanged`.
- `static func availableInputDevices() -> [(uid: String, name: String)]`.
- Serialize device switches through the existing `@unchecked Sendable`
  class with a lock; do not start a switch while one is in progress.

`AppModel`: `inputDevices` published list refreshed on `onDevicesChanged`
and on settings appear; selecting a device sets `preferredDeviceUID`. If the
selected device disappears mid-snippet, `AudioCapture` calls `onError` and
the session presents it as a local error.

### Tests (part A)

- `DictationSettingsTests`: load defaults from an empty store, round-trip,
  `sessionConfiguration` mapping, empty languages omitted from the encoded
  `session.update` (`RealtimeProtocolTests`).
- `ConfigurationUpdatePolicyTests`: key change → reconnect, prompt change →
  sessionUpdate, placement change → nothing, no change → nothing.
- Existing protocol tests updated for `languages`.
- No app-target tests for CoreAudio or `SMAppService`; list them as manual.

### Checkpoints (part A)

1. Core settings, languages, policy, protocol change, tests green.
2. Live update path and `configurationState`.
3. Permissions, login item, audio device lifecycle. Full validation green.
4. Self-review; report what needs a real macOS run.

## Part B (orchestrator)

Settings window redesign as a `TabView` with grouped `Form` sections
matching the approved mockup: General, Dictation, Dictionary, Shortcuts,
Permissions, History, Advanced. History and Shortcuts tabs are placeholders
until milestones 5 and 6. Status row with Reconnect, languages multi-select,
per-field validation, input device picker, launch at login toggle with the
approval note, Input Monitoring row with Open System Settings.

## Manual verification (user present)

Change the prompt while connected and confirm the next snippet reflects it
without a reconnect; edit a dictionary term mid-snippet and confirm it
applies after; unplug a USB microphone mid-snippet; switch Bluetooth
headsets; toggle launch at login and check System Settings; revoke Input
Monitoring and watch the row update within two seconds.
