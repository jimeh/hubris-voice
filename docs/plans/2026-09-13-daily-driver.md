# Daily driver plan

Status: implemented on 2026-09-13 across six milestones; each has its own brief
in this directory. Manual verification with the user present is still open for
the items listed under each milestone. Originally drafted 2026-09-13 and revised
after an independent review. Builds on
[PLAN.md](../../PLAN.md), which stays the product and architecture reference.
This document covers the work needed to move Hubris Voice from a working proof
of concept to a dictation app used many times a day.

## Goals

- Dictation never silently stops working. Connection loss, sleep and wake,
  and server session limits recover without user action.
- The overlay avoids the field being dictated into wherever the target exposes
  its geometry, and disappears as soon as the text is confirmed to have landed.
- Inserted text reads as if typed: correct spacing at the caret, and direct
  insertion where the target supports it.
- A failed or rejected insertion costs one keystroke to recover from.
- Settings persist as they are changed and expose the options a daily user
  needs: shortcut, input device, sounds, overlay placement, launch at login.

Out of scope for this plan: automatic rewrites of the transcript, accounts,
backend token brokering, and App Store distribution. A "cleanup" pass is noted
as a later option only.

## Milestones

Each milestone is independently shippable. Order matters for the first three
because later milestones build on their state machine and shortcut changes.

### 1. Reliability

Problems today:

- Any socket error or close sets the session not-ready and nothing reconnects.
  After a snippet the phase shows "Connecting" with no connect in flight.
- `connect()` clears queued outbound actions, so audio captured while
  disconnected is lost rather than replayed. Buffering is also unbounded.
- An error overlay with no transcript has no Dismiss control. It stays on
  screen until a later dictation succeeds.
- Finalizing has no timeout. A lost completion event leaves the overlay in
  "Finalizing" forever, and a new press resets the assembler so a late event is
  dropped or adopted as the next item's preview. Item IDs only arrive from the
  server after commit, so an abandoned snippet cannot always be identified by
  item ID alone.
- Completion launches insertion asynchronously with no guard against a newer
  snippet having started.
- There is no way to cancel a dictation in progress, and a tap disable is
  reported as a release, which finalizes instead of cancelling.

Work:

- Add a core `DictationSession` state machine with explicit events (press,
  release, cancel, delta, completed, error, timeout, connection lost,
  connection ready). Separate connection readiness from snippet state. Each
  snippet gets a generation ID; deltas, completions, and insertion tasks that
  carry a stale generation are rejected.
- Add a connection supervisor that owns connect, reconnect with capped
  exponential backoff, and reconnect-on-press. Reconnect on
  `NSWorkspace.didWakeNotification` and on `NWPathMonitor` path changes.
- Replace the unbounded outbound queue with snippet-owned, bounded audio
  buffering. Policy: audio recorded before the session is ready is replayed on
  ready; a disconnect mid-recording keeps buffering up to the cap and replays
  on reconnect; a disconnect after commit with no completion is treated as a
  timeout. Repeated reconnect failure surfaces as an error with the best
  preview text.
- Add a finalizing deadline (initial value 8 seconds). On expiry, show the
  best preview text with Copy, abandon the snippet generation, and return to
  ready only if the connection is actually ready.
- Distinguish cancel from release in the gesture: `cancel()` yields a cancel
  action that discards the snippet and clears the audio buffer.
- Add user cancellation: Escape while listening or finalizing. Route Escape
  through the existing event tap only while the overlay is visible.
- Always render Dismiss in attention mode. Auto-dismiss error overlays after 4
  seconds unless a transcript is present.

Tests: state machine transitions for each event in each phase, stale
generation rejection, backoff schedule, finalizing timeout before and after an
item ID exists, buffer cap and replay, and a fake transport with a fake clock
covering disconnect before ready, during streaming, and immediately after
commit.

### 2. Overlay placement

Problems today:

- The overlay is pinned bottom-center on the mouse's screen. Chat composers
  and terminal prompts live at the bottom of the window, so the overlay covers
  the field being dictated into.
- The panel is not repositioned when it grows with the transcript.

Work:

- Capture an anchor at press time alongside the focus snapshot, using the
  Accessibility reads already performed there. Resolution order:
  1. Caret bounds via `kAXBoundsForRangeParameterizedAttribute` on the
     selected range. A zero-width, positive-height rect is a valid caret;
     reject only rects that are off screen or have zero height.
  2. Focused element frame via `kAXPosition` and `kAXSize`, rejecting
     zero-size or off-screen frames.
  3. Focused window frame via `kAXFocusedWindow`.
  4. Screen containing the focused window.
  5. Screen containing the mouse (current behavior).
- Accessibility reports top-left screen coordinates. Convert to AppKit
  bottom-left coordinates in the app layer before placement, and cover
  vertically stacked and mixed-scale displays in tests.
- Electron and Chromium usually expose element and window frames once
  `AXManualAccessibility` is set, but rarely caret bounds. Treat this as
  something to verify per target app, not a guarantee. Canvas editors, some
  Java and Qt apps, and apps with no Accessibility support fall through to
  the window or screen levels, where the overlay may still cover the field.
- Add `OverlayPlacement` to the core: pure geometry that takes the anchor
  kind, anchor rect, visible screen frame, and panel size, and returns an
  origin. Element and caret anchors place the panel above the anchor, flip
  below when there is no room, and clamp to the visible frame. Window and
  screen anchors place bottom-center with the current inset. Recompute
  placement whenever the panel size changes.
- Add a placement preference: automatic (above), near the caret, bottom of
  screen, top of screen.

Tests: placement function for each anchor kind, flip and clamp behavior,
rejection of degenerate rects, coordinate conversion across display layouts.

### 3. Text insertion quality and overlay lifetime

Problems today:

- Insertion always goes through the clipboard and a synthetic Command-V.
- Paste confirmation treats any value or selection change as success, so a
  caret move during the observation window can report a failed paste as
  confirmed.
- The transcript is trimmed and inserted verbatim, so mid-sentence dictation
  produces "wordHello world".
- Rejection offers Copy only, even when the user moved focus on purpose.
- The overlay's Copy and Dismiss buttons need the mouse.
- A confirmed paste keeps the overlay visible for 850 ms.

Work:

- Strengthen `PasteConfirmation` first: confirmed only when the after-state
  contains the expected text at the expected location. Anything else stays
  `.attempted` with Copy available. This gates the immediate dismissal below.
- Add direct Accessibility insertion as a capability-tested path: check
  `AXUIElementIsAttributeSettable` for `kAXSelectedTextAttribute` on the
  captured element, keep the existing focus and secure-field checks, write,
  then read the value back to verify the expected replacement. A verified
  write is confirmed. An ambiguous result is `.attempted` and must not trigger
  a second insertion through the clipboard. Fall back to clipboard paste only
  when the attribute is not settable or the write returns an explicit error
  before any change. Electron keeps the guarded clipboard path.
- Add `InsertionFormatter` to the core with conservative spacing rules only:
  no leading space at line start, after whitespace, or after an opening
  bracket; leading space after a word character or closing punctuation;
  trailing space by preference. No case changes by default. A separate
  optional case adjustment can lowercase the first letter after a comma, and
  must skip dictionary terms, "I", and words with internal capitals. When
  caret context is unavailable, insert verbatim. Ranges are UTF-16 based to
  match Accessibility.
- Hide the overlay immediately on a confirmed insertion. Keep the short linger
  for attempted results and the persistent state for rejected ones. Confirmed
  feedback moves to the menu-bar icon and an optional sound.
- Add "Paste here" on rejection when the current focus is a non-secure field,
  alongside Copy. Secure fields still hard-reject.
- Keyboard control in attention mode: Return pastes or copies, Escape
  dismisses, routed through the event tap while the overlay is visible.
- Clipboard restore: keep the existing `changeCount` guard and extend the
  restore window from 700 ms to 1.5 seconds.
- Log release-to-insert latency in the diagnostic log.

Tests: confirmation with matching, non-matching, and caret-only changes;
formatter rules across caret contexts including proper nouns, acronyms,
selection replacement, and non-Latin text; insertion path selection and the
no-double-insert guarantee.

### 4. Settings that persist and update live

Problems today:

- Dictionary, prompt, and language changes are lost unless Save & reconnect
  is pressed.
- Every save tears down the socket.
- The language picker has one entry.
- Connection status and validation errors share one message slot.
- Input Monitoring is not shown in permissions.
- Audio capture binds to the default device at engine start, with one
  converter for one source format. Device or format changes are not handled.

Work:

- Persist each setting on change. Send `session.update` on the live socket
  with a 500 ms debounce for prompt, dictionary, and language changes, handle
  the acknowledgement or error event, and apply edits made during a recording
  after the snippet completes. Only an API key change reconnects.
- Restructure into a `TabView` with grouped `Form` sections: General,
  Dictation, Dictionary, Shortcuts, Permissions, Advanced.
- Language: multi-select from the languages the model supports, sent as the
  `languages` array. Default English.
- Separate a connection status row (state, dictionary term count, Reconnect
  button) from per-field validation messages.
- Permissions: add Input Monitoring using `CGPreflightListenEventAccess` and
  `CGRequestListenEventAccess`. Show "Open System Settings" when denied. Poll
  status every 2 seconds while the window is visible.
- Audio device lifecycle: persist the device UID, fall back to the system
  default when it is missing, apply the device through the input unit's
  current-device property, serialize switches, rebuild the tap and converter
  on `AVAudioEngineConfigurationChange`, and cancel an active recording with
  an overlay message when the device disappears mid-snippet.
- Launch at login via `SMAppService.mainApp`, showing the actual registration
  status rather than a saved boolean.
- Other new options: sound cues per event, overlay placement, trailing space,
  insertion mode (automatic, clipboard only).

Tests: settings store round-trip, debounce behavior, `session.update`
payload and acknowledgement handling. Manual: unplug a USB microphone, switch
Bluetooth headsets, wake from sleep, and approve then revoke the login item.

### 5. Shortcuts

Problems today:

- The push-to-talk chord is fixed.
- Fn/Globe and right-Command, the two most common push-to-talk keys, arrive as
  `flagsChanged` events which the gesture does not handle. Flag masks alone
  cannot tell left from right Command; the key code on the `flagsChanged`
  event can.
- Only one binding exists, and later milestones need more.

Work:

- Extend the core gesture to a `ShortcutBinding` set with two kinds: key chord
  (current) and modifier-only (Fn, right-Command, right-Option). Modifier-only
  bindings identify the physical key by key code, track press and release
  from flag transitions, cancel on any other key press so Fn-based system
  shortcuts still work, and reconcile state after tap disable, sleep, and a
  missed release.
- Rework `PushToTalkMonitor` to dispatch to multiple bindings and to consume
  events only for matched bindings. Verify that cancelled Fn combinations
  still reach the system.
- Add a shortcut recorder control in Settings with conflict detection between
  bindings. Warn when Fn is chosen, since capturing it can interfere with
  system behavior on some keyboards.
- Add tap-to-lock: a tap shorter than the accidental threshold with lock
  enabled starts a locked recording, and the next tap finishes it. Hold
  behavior is unchanged.
- Add an optional global "paste last transcript" binding, off by default. It
  reuses the guarded insertion path against the currently focused element,
  rejects secure fields, and reports outcome through the menu-bar icon and
  sound rather than the overlay. If it fails, the transcript is copied to the
  clipboard and the icon shows the attention state.

Tests: modifier-only gesture transitions including both Command keys held,
multi-binding dispatch, tap-to-lock sequencing, state reconciliation after a
missed release, binding conflict detection.

### 6. History and menu bar

Work:

- Keep a transcript history in memory, newest first, capped at 50 entries.
  Optional on-disk persistence, off by default. Each entry stores text,
  timestamp, target app bundle ID, and outcome.
- Menu bar: connection state, Last transcript (copy on click), a History
  submenu with the last ten entries, Enable/Disable dictation, Reconnect,
  Open log, Settings, Quit.
- History tab in Settings with search, copy, and clear.
- Optional sound cues on start, stop, pasted, and rejected using system sounds.
  Off by default.

Tests: history cap and ordering, outcome recording.

## Later options

- Cleanup pass: filler word removal or a format preset, off by default.
- Dictionary import and export as plain text.
- Per-application prompt and dictionary profiles.

## Boundaries

State machines, geometry, formatter, gesture, buffering policy, and history
live in `HubrisVoiceCore` with no AppKit dependency. Accessibility objects,
`NSScreen`, event taps, audio, network monitoring, and lifecycle adapters stay
in `HubrisVoiceApp`.

## Verification

- `mise run check` after each milestone, and `mise run verify` for the final
  bundled handoff.
- Core additions are unit tested in `HubrisVoiceCoreTests`. Transport and
  coordinator races use a fake transport and fake clock rather than live
  sessions.
- Manual verification with the user present for each milestone, extending
  the checklist in [PLAN.md](../../PLAN.md): reconnect after sleep and after a
  forced socket close, overlay placement in a native field, an Electron
  composer, a terminal, and a full-screen app, direct insertion into TextEdit
  and Safari, Electron fallback, secure-field rejection, a caret move during
  the confirmation window, clipboard overlap with a user copy, Fn
  push-to-talk, both Command keys held, tap-to-lock, device switching, login
  item approval and revocation, and the paste-last-transcript binding.

## Unresolved questions

- Whether direct Accessibility insertion should be default-on for all native
  targets or opt-in until it has been exercised across more apps.
- Whether history should persist across launches by default. Transcripts can
  contain sensitive text, so the plan defaults to memory only.
- Whether Fn/Globe can be captured without disabling its system behavior on
  all keyboards, or whether the recorder should only warn when Fn is chosen.
