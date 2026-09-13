# Milestone 5: shortcuts

Design brief for milestone 5 of [the daily driver plan](2026-09-13-daily-driver.md).
Builds on milestones 1 to 4. Part A is delegated; part B (shortcut recorder
UI) is implemented by the orchestrator.

## Outcome

- The push-to-talk key is configurable, including Fn/Globe and right-side
  modifiers on their own.
- Tap-to-lock: a quick tap starts a locked recording; the next tap finishes
  it. Holding still works as before.
- An optional global "paste last transcript" shortcut inserts the most
  recent transcript at the current focus, or copies it when insertion fails.
- Bindings are detected for conflicts, and state is reconciled after a tap
  disable, sleep, or missed release.

## Core

### `ShortcutBinding`

In `InteractionPolicy.swift` (or a new `Shortcuts.swift`; keep
`GlobalShortcut` and `KeyModifiers` where they are):

```swift
public enum ModifierKey: String, CaseIterable, Codable, Sendable {
  case fn            // key code 63, CGEventFlags.maskSecondaryFn
  case rightCommand  // 54, maskCommand
  case rightOption   // 61, maskAlternate
  case rightControl  // 62, maskControl
  case rightShift    // 60, maskShift
  public var keyCode: UInt16 { get }
}

public enum ShortcutBinding: Equatable, Codable, Sendable {
  case chord(GlobalShortcut)
  case modifier(ModifierKey)
  public var displayName: String { get }   // "⌃⇧Space", "Fn", "Right ⌘"
}

public enum ShortcutRole: String, CaseIterable, Codable, Sendable {
  case pushToTalk
  case pasteLastTranscript
}

public struct ShortcutSet: Equatable, Codable, Sendable {
  public var pushToTalk: ShortcutBinding                 // default .chord(.pushToTalkDefault)
  public var pasteLastTranscript: ShortcutBinding?       // default nil (off)
  public func conflicts() -> [(ShortcutRole, ShortcutRole)]
}
```

`GlobalShortcut` gains `Codable` and a `displayName` using the standard
macOS glyph order ⌃⌥⇧⌘ plus a key name table for the common key codes
(space, letters, digits, F-keys, arrows, return, escape). Unknown key codes
display as `Key 0xNN`.

### `ShortcutGesture`

Replaces `PushToTalkGesture`. One instance per binding.

```swift
public struct ShortcutGesture: Sendable {
  public enum Action: Equatable, Sendable { case ignored, consumed, pressed, released, cancelled }
  public init(binding: ShortcutBinding)
  public mutating func handleKey(isKeyDown: Bool, keyCode: UInt16, modifiers: KeyModifiers, isRepeat: Bool) -> Action
  public mutating func handleFlagsChanged(keyCode: UInt16, modifiers: KeyModifiers) -> Action
  public mutating func cancel() -> Action
  public var isHeld: Bool { get }
}
```

Rules:

- Chord bindings behave exactly as `PushToTalkGesture` does today through
  `handleKey`; `handleFlagsChanged` is `.ignored`.
- Modifier bindings: `handleFlagsChanged` with the binding's key code and
  the modifier's flag present → `.pressed` (once); same key code with the
  flag absent → `.released` if held. Other key codes are `.ignored`.
- Modifier bindings: while held, any `handleKey(isKeyDown: true, ...)` for a
  different key returns `.cancelled` and clears the hold, so Fn+F1 and
  ⌘+key combinations keep working and do not record. The event is never
  consumed for modifier bindings; only chord bindings consume their own key
  events.
- `KeyModifiers` gains `.fn`. The app maps `CGEventFlags.maskSecondaryFn`.

### `DictationSession` changes

- `Configuration.tapToLock: Bool` (default false).
- New state `isLocked: Bool`.
- `released(held)` with `tapToLock` and `held < minimumHoldDuration` while
  listening: set `isLocked = true`, keep listening, return `[]`. The
  accidental-press discard only applies when tap-to-lock is off.
- `pressed` while listening and `isLocked`: behave as a normal release
  (`releaseListeningSnippet()`), clear `isLocked`. The matching `released`
  event that follows is ignored because nothing is listening.
- `cancelRequested` and every other path that ends listening clears
  `isLocked`.
- Presentation while locked: message "Locked · tap to finish", and
  `OverlayPresentation.isLocked` for the overlay to show a lock glyph.
- `pasteLastRequested(text: String)`: same behavior as `pasteHereRequested`
  but with supplied text and no requirement on `presented`. No-op while
  listening. Returns `[.cancelDismiss, .insertAtCurrentFocus(g, text)]`.
- The insertion outcome for a paste-last request presents exactly like a
  recovery paste: nothing on confirmed, attention on attempted or rejected.
  The app additionally copies the text to the clipboard on rejection.

Update the milestone 1 transition table for these rows.

## App

### `ShortcutMonitor` (replaces `PushToTalkMonitor`)

- Event mask adds `flagsChanged`.
- Holds `[ShortcutRole: ShortcutGesture]` behind the existing lock.
  `apply(_ set: ShortcutSet)` rebuilds the gestures; when rebuilding while a
  gesture is held, cancel it first.
- Callback `onAction: (ShortcutRole, ShortcutGesture.Action) -> Void`.
- `capturesEscape` and `onEscape` remain. Return is not intercepted; recovery
  uses the paste-last-transcript shortcut or the menu bar.
- Tap re-enable after `tapDisabledByTimeout` cancels every held gesture, as
  today. Also cancel all on `NSWorkspace.willSleepNotification` (the model
  calls `cancelAll()`).
- A modifier binding's `flagsChanged` event is never consumed.

### `AppModel`

- `settings.shortcuts: ShortcutSet` and `settings.tapToLock: Bool` stored in
  `DictationSettings` (JSON-encoded for the set). Apply to the monitor on
  change. Validate with `conflicts()`; a conflicting set is saved but the
  model exposes `shortcutConflict: String?` for the UI and does not apply
  the conflicting binding.
- `lastTranscript: String?` set on every completed transcript (before
  formatting). Milestone 6 replaces this with history.
- `pasteLastTranscript` role → `.pasteLastRequested(text: lastTranscript)`
  when non-nil; when nil, flash the attention icon and do nothing.
- Warn once in the diagnostic log when Fn is bound, since some keyboards
  route Fn through the system before the tap.

### Overlay

- Show a lock glyph next to the state title when `isLocked`. No other
  visual change.

## Tests

`ShortcutGestureTests`: chord press and release; modifier press on flag
set and release on flag clear; both Command keys: right Command held then
left Command pressed and released does not release the binding (key code
distinguishes them); other key press while a modifier is held cancels and
subsequent flag clear is ignored; cancel when not held is ignored;
`handleFlagsChanged` on a chord binding is ignored.

`ShortcutSetTests`: conflict when both roles use the same binding; no
conflict when `pasteLastTranscript` is nil; `Codable` round-trip;
`displayName` for a chord, Fn, and right Command.

`DictationSessionTests`: tap-to-lock locks and the next press finalizes; a
short release with lock off still discards; cancel while locked clears the
lock; `pasteLastRequested` allocates a generation and inserts; no-op while
listening.

`InteractionPolicyTests`: existing `PushToTalkGesture` tests move to
`ShortcutGestureTests` under the chord binding.

## Checkpoints

1. Core gesture, binding, set, session changes, tests green.
2. `ShortcutMonitor`, model wiring, settings persistence.
3. Overlay lock glyph, full validation green.
4. Self-review; report what needs a real macOS run, especially Fn behavior.

## Part B (orchestrator)

Shortcut recorder control in the Shortcuts tab: click to record, captures
the next chord or lone modifier key, shows the display name, offers Clear
for the optional binding, shows the conflict message, and the Fn warning.
Tap-to-lock toggle.

## Manual verification (user present)

Fn hold, right Command hold, chord hold; Fn+F-key still works while bound;
tap-to-lock start and finish; sleep with a key held; paste-last into a
field and into a secure field.
