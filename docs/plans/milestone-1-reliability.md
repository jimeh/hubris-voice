# Milestone 1: reliability

Design brief for the first milestone of
[the daily driver plan](2026-09-13-daily-driver.md). This document is the
contract for implementation. Where it and the existing code disagree, this
document wins; where it is silent, follow existing conventions in the repo.

## Outcome

After this milestone:

- A dropped or refused connection reconnects with backoff, and a press while
  disconnected starts recording immediately and connects in parallel.
- Audio recorded while disconnected or reconnecting is replayed when the
  session is ready, so a snippet is never lost to a transport failure.
- A snippet that never receives a completion times out and offers Copy with
  the best preview text.
- Escape cancels the current dictation. A tap disable cancels rather than
  finalizes.
- Every overlay state can be dismissed.
- Pressing again while a previous snippet is still finalizing starts a new
  snippet. The previous one completes and inserts on its own.
- All of the above is decided by a pure state machine in `HubrisVoiceCore`
  and covered by unit tests. `AppModel` becomes an interpreter of effects.

## Architecture

```text
ShortcutMonitor ─ role/action ────────────┐
AudioCapture ─ chunks, levels ────────────┤
RealtimeTranscriptionClient ─ events ─────┤       ┌─ AudioCapture start/stop
Timers, wake, network ────────────────────┼─► AppModel ─► DictationSession.transition(event)
                                          │       │             │
                                          │       │             └─ [Effect]
                                          │       └─ interprets effects: client sends, timers,
                                          │          insertion, capture
                                          └─ overlay and menu render DictationSession.presentation
```

`DictationSession` is a value type. `AppModel` holds one instance, feeds it
events, applies the returned effects, and republishes `presentation` and
`phaseTitle`. No dictation policy lives in `AppModel` after this change.

## Core types

All in `Sources/HubrisVoiceCore`. No AppKit, no Combine, no Foundation types
beyond `Data`, `Duration`, and `TimeInterval`.

### `DictationSession.swift`

```swift
public struct DictationSession: Equatable, Sendable {
  public struct Snippet: Equatable, Sendable {
    public let generation: Int
    public var itemID: String?        // assigned by inputCommitted
    public var transcript: String     // accumulated deltas or final text
  }

  public enum ConnectionState: Equatable, Sendable {
    case unconfigured                 // no API key
    case disconnected(attempt: Int)   // attempt = next reconnect attempt number
    case connecting(attempt: Int)
    case ready
  }

  public enum PresentedResult: Equatable, Sendable {
    case confirmed(text: String)
    case attempted(text: String)
    case rejected(text: String, reason: RejectionReason)
    case timedOut(text: String)       // may be empty
    case error(message: String, text: String)
  }

  public enum RejectionReason: Equatable, Sendable {
    case noTarget, focusChanged, secureField
  }

  public enum Event: Equatable, Sendable {
    // user
    case pressed
    case released(heldDuration: TimeInterval)
    case cancelRequested              // Escape, tap disable
    case dismissRequested             // Dismiss button, Escape while presenting
    case copied                       // Copy button pressed
    case pasteHereRequested           // Return while a recoverable result is presented
    case pasteLastRequested(text: String)
    case connectRequested(force: Bool)
    case credentialsChanged(hasKey: Bool)
    case localError(message: String)  // permission or capture failures from the app
    case bufferFull(generation: Int)  // snippet reached the audio cap
    // transport
    case sessionReady
    case connectionFailed(message: String)   // connect() threw
    case connectionLost(message: String)     // established socket dropped
    case server(RealtimeServerEvent)         // inputCommitted, delta, completed, error
    // timers
    case reconnectDelayElapsed(attempt: Int)
    case finalizingTimedOut(generation: Int)
    case dismissDelayElapsed
    // insertion
    case insertionFinished(generation: Int, outcome: PasteOutcome, reason: RejectionReason?)
  }

  public enum Effect: Equatable, Sendable {
    case startCapture(generation: Int)
    case stopCapture
    case replayAudio(generation: Int)        // resend the whole buffer for that snippet
    case commitAudio(generation: Int)
    case clearAudio(generation: Int)         // discard local buffer; send clear if this was the streaming snippet
    case connect(attempt: Int)
    case disconnect
    case scheduleReconnect(after: Duration, attempt: Int)
    case cancelReconnect
    case scheduleFinalizingTimeout(generation: Int, after: Duration)
    case cancelFinalizingTimeout(generation: Int)
    case insert(generation: Int, text: String)
    case insertAtCurrentFocus(generation: Int, text: String)
    case scheduleDismiss(after: Duration)
    case cancelDismiss
    case discardSnippet(generation: Int)     // release captured focus and buffer
  }

  public struct Configuration: Equatable, Sendable {
    public var minimumHoldDuration: TimeInterval = 0.2
    public var finalizingTimeout: Duration = .seconds(8)
    public var copiedLinger: Duration = .milliseconds(850)
    public var attentionLinger: Duration = .seconds(4)
    public var maximumPendingSnippets: Int = 4
    public var reconnect: ReconnectPolicy = .init()
    public var tapToLock: Bool = false
  }

  public private(set) var connection: ConnectionState
  public private(set) var listening: Snippet?
  public private(set) var pending: [Snippet]      // FIFO awaiting commit ack, transcript, or insertion
  public private(set) var inserting: [Snippet]    // completed, insertion in flight
  public private(set) var presented: PresentedResult?
  public private(set) var nextGeneration: Int
  public private(set) var isLocked: Bool

  public init(configuration: Configuration = .init(), hasKey: Bool)
  public mutating func transition(_ event: Event) -> [Effect]

  public var presentation: OverlayPresentation?   // nil means hidden
  public var phaseTitle: String                   // menu bar and settings header
}
```

`OverlayPresentation` is a new value in the same file:

```swift
public struct OverlayPresentation: Equatable, Sendable {
  public enum Mode: Equatable, Sendable { case listening, finalizing, completed, copied, attention }
  public let mode: Mode
  public let transcript: String
  public let message: String
  public let canCopy: Bool
  public let canPasteHere: Bool     // true for non-empty attention results
  public let canDismiss: Bool       // true for every mode except listening and finalizing
  public let pendingCount: Int      // snippets still finalizing behind the visible one
}
```

Derivation, first match wins:

1. `listening != nil`: mode `listening`, transcript from the listening
   snippet, message "Release to insert" when `connection == .ready`,
   "Connecting…" when connecting, "Reconnecting…" when disconnected,
   `pendingCount = pending.count`.
2. `presented != nil`: mode `completed` for `.confirmed`, `copied` after the
   `.copied` event, `attention` otherwise. Messages: "Inserted into the
   focused field", "Paste attempted · copy if needed", "Focus or app changed ·
   copy instead" / "No target app was captured · copy instead" / "Secure field
   · copy instead", "No result arrived · copy what was heard", and the error
   message. `canCopy` is true when the text is non-empty. `canDismiss` is
   always true. `canPasteHere` is true for non-empty attention results.
3. `pending` or `inserting` non-empty: mode `finalizing`, transcript from the
   newest pending snippet, message "Completing the transcript…".
4. Otherwise nil.

`phaseTitle`: "Add an API key", "Connecting", "Reconnecting", "Ready",
"Listening", "Finalizing", "Paste attempted", "Transcript ready",
"Needs attention", in that priority from the same state.

### Transition table

Rules that apply before the table:

- Every event carrying a `generation` or `itemID` that does not match a live
  snippet (listening, pending, or inserting) is ignored and returns no
  effects. This is the stale guard.
- `reconnectDelayElapsed(attempt)` is ignored unless
  `connection == .disconnected(attempt)`.
- `dismissDelayElapsed` is ignored unless `presented != nil`.
- `server(.ignored)` returns no effects.

Connection events, independent of snippet state:

| Event | From | To | Effects |
| --- | --- | --- | --- |
| `credentialsChanged(false)` | any | `unconfigured` | `disconnect`, `cancelReconnect` |
| `credentialsChanged(true)` | `unconfigured` | `connecting(0)` | `connect(0)` |
| `credentialsChanged(true)` | other | unchanged | none |
| `connectRequested(false)` | `disconnected(n)` | `connecting(0)` | `cancelReconnect`, `connect(0)` |
| `connectRequested(false)` | `connecting`, `ready`, `unconfigured` | unchanged | none |
| `connectRequested(true)` | `ready`, `connecting`, `disconnected` | `connecting(0)` | `disconnect`, `cancelReconnect`, `connect(0)` |
| `connectionFailed` | `connecting(n)` | `disconnected(n+1)` | `scheduleReconnect(after: delay(n+1), attempt: n+1)` |
| `connectionLost` | `ready` | `disconnected(1)` | `scheduleReconnect(after: delay(1), attempt: 1)`; every live snippet resets `itemID` and its partial transcript, since replay is transcribed afresh |
| `connectionLost` | `connecting(n)` | as `connectionFailed` | as `connectionFailed` |
| `reconnectDelayElapsed(n)` | `disconnected(n)` | `connecting(n)` | `connect(n)` |
| `sessionReady` | `connecting` | `ready` | replay effects, see below |

Replay effects on `sessionReady`: for each pending snippet in FIFO order,
`replayAudio(g)` then `commitAudio(g)`; then, if a listening snippet exists,
`replayAudio(listening)`. Pending snippets keep their existing
`scheduleFinalizingTimeout`; do not reschedule.

`delay(n)` comes from `ReconnectPolicy`.

Snippet events:

| Event | Condition | Result | Effects |
| --- | --- | --- | --- |
| `pressed` | `listening != nil`, `isLocked` | snippet moves to `pending`, `isLocked = false` | as a normal long release |
| `pressed` | `connection == .unconfigured` | `presented = .error("Add an OpenAI API key before dictating.", "")` | `scheduleDismiss(attentionLinger)` |
| `pressed` | `listening != nil`, not locked | unchanged | none |
| `pressed` | `pending.count + inserting.count >= maximumPendingSnippets` | `presented = .error("Waiting for previous transcripts.", "")` | `scheduleDismiss(attentionLinger)` |
| `pressed` | `connection == .ready` or `.connecting` | new listening snippet, `presented = nil` | `cancelDismiss`, `startCapture(g)` |
| `pressed` | `connection == .disconnected` | new listening snippet, `connection = .connecting(0)`, `presented = nil` | `cancelDismiss`, `cancelReconnect`, `connect(0)`, `startCapture(g)` |
| `released(held)` | `listening == nil` | unchanged | none |
| `released(held)` | `held < minimumHoldDuration`, `tapToLock` | `isLocked = true`; keep listening | none |
| `released(held)` | `held < minimumHoldDuration`, tap-to-lock off | `listening = nil` | `stopCapture`, `clearAudio(g)`, `discardSnippet(g)` |
| `released(held)` | otherwise | snippet moves to `pending` | `stopCapture`, `commitAudio(g)` only if `connection == .ready`, `scheduleFinalizingTimeout(g, finalizingTimeout)` |
| `bufferFull(g)` | `listening?.generation == g` | as `released` with a long hold | as `released`, plus `presented` unchanged |
| `cancelRequested` | `listening != nil` | `listening = nil` | `stopCapture`, `clearAudio(g)`, `discardSnippet(g)` |
| `cancelRequested` | `listening == nil`, `presented != nil` | as `dismissRequested` | as `dismissRequested` |
| `cancelRequested` | only pending snippets | `pending = []` | `cancelFinalizingTimeout(g)` and `discardSnippet(g)` for each |
| `cancelRequested` | nothing active | unchanged | none |
| `dismissRequested` | `presented != nil` | `presented = nil` | `cancelDismiss` |
| `copied` | `presented` has text | `presented` stays but mode becomes `copied` (track with a flag) | `cancelDismiss`, `scheduleDismiss(copiedLinger)` |
| `pasteHereRequested` | `presented` is non-empty `.attempted`, `.rejected`, or `.timedOut` | allocate a new generation, move its text to `inserting`, clear `presented` | `cancelDismiss`, `insertAtCurrentFocus(g, text)` |
| `pasteLastRequested(text)` | not listening, `text` non-empty | allocate a new generation, move `text` to `inserting`, clear `presented` | `cancelDismiss`, `insertAtCurrentFocus(g, text)` |
| `pasteLastRequested(text)` | listening or `text` empty | unchanged | none |
| `localError(m)` | `listening != nil` | `listening = nil`, `presented = .error(m, transcript)` | `stopCapture`, `clearAudio(g)`, `discardSnippet(g)`, `scheduleDismiss(attentionLinger)` if transcript empty |
| `localError(m)` | otherwise | `presented = .error(m, "")` | `scheduleDismiss(attentionLinger)` |
| `server(.inputCommitted(id))` | first pending snippet with `itemID == nil` exists | that snippet gets `itemID` | none |
| `server(.transcriptDelta(id, d))` | pending snippet with `itemID == id` | append `d` | none |
| `server(.transcriptDelta(id, d))` | no pending match, listening snippet with `itemID` nil or `== id` | listening snippet adopts `id`, appends `d` (live preview) | none |
| `server(.transcriptCompleted(id, t))` | pending snippet with that id, trimmed `t` empty | remove from pending, `presented = .error("No speech was detected.", "")` | `cancelFinalizingTimeout(g)`, `clearAudio(g)`, `discardSnippet(g)`, `scheduleDismiss(attentionLinger)` |
| `server(.transcriptCompleted(id, t))` | pending snippet with that id | move to `inserting` with `transcript = t` | `cancelFinalizingTimeout(g)`, `clearAudio(g)`, `insert(g, t)` |
| `server(.error(m))` | any snippet live | `presented = .error(m, newest transcript)`; listening snippet cancelled as `cancelRequested`; pending snippets untouched | as `cancelRequested` for the listening snippet, `scheduleDismiss(attentionLinger)` if text empty |
| `server(.error(m))` | nothing live | `presented = .error(m, "")` | `scheduleDismiss(attentionLinger)` |
| `finalizingTimedOut(g)` | pending snippet `g` | remove, `presented = .timedOut(transcript)` | `clearAudio(g)`, `discardSnippet(g)`; `scheduleDismiss(attentionLinger)` only if transcript empty |
| `insertionFinished(g, .confirmed)` | inserting `g` | remove, `presented = nil` | `discardSnippet(g)`, `cancelDismiss` |
| `insertionFinished(g, .attempted)` | inserting `g` | remove, `presented = .attempted(text)` | `discardSnippet(g)`, `cancelDismiss`, `scheduleDismiss(attentionLinger)` |
| `insertionFinished(g, .rejected, reason)` | inserting `g` | remove, `presented = .rejected(text, reason)` | `discardSnippet(g)`, `cancelDismiss` |

Notes:

- A `presented` result is replaced by a newer one. The older text is dropped
  from the overlay; history in milestone 6 retains it.
- `presented` is cleared when a new snippet starts listening so the overlay
  shows the live transcript. If a pending snippet later produces an attention
  result while another snippet is listening, `presented` is set but the
  overlay keeps showing the listening snippet until it stops, then shows the
  result. `pendingCount` lets the overlay hint that work is queued.
- `insert` carries only the generation and text. The app looks up the focus
  captured at press time by generation.
- Every path that ends listening clears `isLocked`. While locked, the listening
  presentation uses "Locked · tap to finish" and sets `isLocked` for the
  overlay lock glyph.
- Paste-last insertion outcomes use the same presentation as recovery paste.
  The app also copies paste-last text when insertion is rejected.

### `ReconnectPolicy.swift`

```swift
public struct ReconnectPolicy: Equatable, Sendable {
  public var initialDelay: Duration = .milliseconds(500)
  public var multiplier: Double = 2
  public var maximumDelay: Duration = .seconds(30)
  public func delay(forAttempt attempt: Int) -> Duration  // attempt >= 1
}
```

Attempt 1 returns `initialDelay`; each later attempt multiplies, capped at
`maximumDelay`. No jitter, no attempt limit. Deterministic so tests can assert
exact values.

### `AudioSnippetBuffer.swift`

```swift
public struct AudioSnippetBuffer: Equatable, Sendable {
  public enum AppendResult: Equatable, Sendable { case stored, full }
  public init(capacityBytes: Int)        // default 24_000 * 2 * 90 (90 s of PCM16 mono)
  public var chunks: [Data] { get }
  public var byteCount: Int { get }
  public var isFull: Bool { get }
  public mutating func append(_ chunk: Data) -> AppendResult   // drops the chunk and returns .full at the cap
}
```

The buffer holds every chunk of a snippet until the snippet is discarded. The
app keeps one buffer per live generation.

### `InteractionPolicy.swift` changes

- `PushToTalkGesture.Action` gains `cancelled`. `cancel()` returns
  `.cancelled` when held, `.ignored` otherwise. `released` is only produced by
  a real key up.
- No other change. `SnippetPolicy` remains and is used by the session for the
  minimum hold check.

### Removals

- `TranscriptAssembler.swift` and `TranscriptAssemblerTests.swift`. Its
  behavior (per-item accumulation, completion) now lives in the session and
  is covered by the session tests.

## App changes

### `RealtimeTranscriptionClient.swift`

- Introduce `enum RealtimeTransportEvent { case server(RealtimeServerEvent); case connectionLost(message: String) }`
  and make `events` a stream of it. A receive loop failure, a delegate close,
  or a send failure on an open socket yields `connectionLost`. A decoded
  server `error` event stays `.server(.error)`.
- Remove `pendingActions`. When an outbound action arrives and the socket is
  not ready, drop it and log once per connection. Replay is the session's
  responsibility.
- `connect` throws as today; the model maps a throw to
  `.connectionFailed(message)`.
- Add `outbound.replay(_ chunks: [Data])` that appends every chunk in order,
  or have the model call `appendAudio` in a loop. Either is fine; keep the
  order guarantee.

### `AppModel.swift`

Rewrite around the session:

- State: `session: DictationSession`, `buffers: [Int: AudioSnippetBuffer]`,
  `focus: [Int: CapturedFocus]`, `streamingGeneration: Int?` (the snippet
  whose chunks go straight to the socket), timers keyed by generation for
  finalizing timeouts, one `DelayedActionScheduler` each for reconnect and
  dismiss.
- `apply(_ event:)` feeds the session on the main actor, then interprets
  every returned effect in order. Publish `session.presentation` into
  `OverlayViewModel` and `session.phaseTitle` for the menu.
- Audio chunk handling: append to the buffer for the listening generation;
  if the result is `.full`, feed `.bufferFull(g)`. If `session.connection ==
  .ready` and the chunk belongs to the streaming generation, also send it. A
  chunk arriving during the 100 ms stop grace still counts.
- `startCapture(g)`: capture focus into `focus[g]`, create the buffer, set
  `streamingGeneration = g`, start `AudioCapture`. If `AudioCapture.start`
  throws, feed `.localError`.
- `stopCapture`: wait 100 ms, then stop the engine and clear
  `streamingGeneration`.
- `replayAudio(g)`: send every chunk in `buffers[g]`.
- `commitAudio(g)`: `outbound.commitAudio()`.
- `clearAudio(g)`: if `g == streamingGeneration` send `clearAudio`; the
  buffer itself is dropped by `discardSnippet`.
- `discardSnippet(g)`: remove `buffers[g]`, `focus[g]`, and any timer for
  `g`.
- `insert(g, text)`: run `TextInsertionService.paste` with `focus[g]`. Map
  the outcome to `.insertionFinished(g, outcome, reason)`. Derive the reason:
  `noTarget` when no focus was captured, `secureField` when the captured or
  current snapshot is secure, otherwise `focusChanged`. Expose that from
  `TextInsertionService` by returning a small result struct rather than
  guessing in the model.
- Permissions and API key checks happen before feeding `.pressed`: missing
  key is handled by the session; missing microphone permission feeds
  `.localError("Allow Microphone access in Settings before dictating.")`.
- Wake: observe `NSWorkspace.shared.notificationCenter` for
  `NSWorkspace.didWakeNotification` and feed `.connectRequested(force: false)`.
- Network: an `NWPathMonitor` on a background queue; when the path becomes
  satisfied, feed `.connectRequested(force: false)` on the main actor.
- `saveSettings` feeds `.credentialsChanged(hasKey)` and then
  `.connectRequested(force: true)`. Milestone 4 replaces the forced
  reconnect with `session.update`.
- Escape: set `shortcutMonitor.capturesEscape = session.presentation != nil`
  after every transition.

### `PushToTalkMonitor.swift`

- Add `onCancel` and map the gesture's `.cancelled` to it.
- Add `capturesEscape: Bool` (guarded by the existing lock). When true, an
  Escape key down (key code 53) is consumed and reported through a new
  `onEscape` callback. The model maps Escape to `.cancelRequested`.

### `Overlay.swift`

Only the minimum for this milestone; the overlay redesign is separate work.

- `OverlayViewModel` gains `canDismiss` and `pendingCount`, and a
  `func apply(_ presentation: OverlayPresentation)`.
- Render the Dismiss button whenever `canDismiss` is true, Copy whenever
  `canCopy` is true. Show a small "+N" next to the timer when `pendingCount
  > 0`.
- `OverlayController.show()` and `hide()` are driven by whether the
  presentation is nil. Keep the existing sizing logic.

### `HubrisVoiceApp.swift`

Wire the new `onCancel` and `onEscape` callbacks. No other change.

## Tests

`Tests/HubrisVoiceCoreTests/DictationSessionTests.swift`, one test per row
below. Each test builds a session, feeds events, and asserts both state and
the exact effect list. Name tests after the failure they guard.

Connection:

1. `connectionLost` from ready schedules attempt 1 with the policy's initial
   delay.
2. `connectionFailed` after attempt n schedules n+1 with the grown delay,
   capped at the maximum after enough attempts.
3. `reconnectDelayElapsed` with a stale attempt number is ignored.
4. `connectRequested(force: false)` while connecting is a no-op; while
   disconnected it cancels the pending reconnect and connects at attempt 0.
5. `credentialsChanged(false)` disconnects and moves to unconfigured;
   `pressed` in unconfigured presents the API key error.

Snippet lifecycle:

6. Press and release above the minimum hold commits and schedules the
   finalizing timeout.
7. Release below the minimum hold clears and discards without a commit.
8. Press while disconnected starts capture and connects in the same
   transition; `sessionReady` then replays the listening snippet.
9. Release while connecting does not commit; `sessionReady` replays then
   commits the pending snippet.
10. `connectionLost` during finalizing clears the pending `itemID`;
    `sessionReady` replays and recommits, and a later completion for the new
    `itemID` inserts.
11. Committed, delta, and completed events route by `itemID`; a delta for an
    unknown `itemID` is ignored.
12. Two snippets pending at once: commits are acknowledged in order,
    completions arrive out of order, each inserts with its own text.
13. Press while `maximumPendingSnippets` is reached presents the waiting
    error and does not start capture.
14. `finalizingTimedOut` for a pending snippet presents `timedOut` with the
    partial transcript and discards; a stale timeout is ignored.
15. `bufferFull` behaves as a release.

Cancellation and presentation:

16. `cancelRequested` while listening stops, clears, discards, and shows
    nothing.
17. `cancelRequested` with only pending snippets discards them all.
18. `localError` while listening presents the error with the partial
    transcript and does not schedule dismissal when the transcript is
    non-empty.
19. Every `PresentedResult` yields `canDismiss == true`, and
    `dismissRequested` clears it.
20. `insertionFinished` for confirmed hides immediately; attempted and
    rejected produce the expected presentation, linger, and reason messages.
21. `insertionFinished` for a generation that is not inserting is ignored.
22. `presentation` while listening reports `pendingCount` and the
    connection-dependent message.

`ReconnectPolicyTests.swift`: initial, growth, cap.

`AudioSnippetBufferTests.swift`: append below cap, append at cap returns
`.full` and drops the chunk, `byteCount`.

`InteractionPolicyTests.swift`: update the cancel test to expect
`.cancelled`, add cancel when not held returns `.ignored`.

No new app-target tests are required. The existing
`OverlayControllerTests` must keep passing.

## Checkpoints

Work in this order and run `mise run check` at each checkpoint before moving
on. Report which checkpoint was reached if something blocks.

1. Core: `ReconnectPolicy`, `AudioSnippetBuffer`, gesture `cancelled`, with
   tests green.
2. Core: `DictationSession` with all 22 tests green. Delete
   `TranscriptAssembler`.
3. App: client transport events and queue removal.
4. App: `AppModel` rewrite as effect interpreter, monitor Escape and cancel,
   overlay Dismiss, wake and network hooks.
5. Full `mise run check` green, then self-review.

## Self-review before handoff

- Re-read the transition table row by row against `transition(_:)` and
  confirm each row has a test or is trivially covered.
- Confirm nothing in `HubrisVoiceCore` imports AppKit, Combine, or Network.
- Confirm `AppModel` contains no dictation policy: every `if` about phases,
  generations, or connection state should be in the session.
- Confirm `mise run check` passes from a clean state.
- List anything that could not be verified without a live OpenAI session or
  a real macOS run, so the orchestrator can schedule manual verification.

## Manual verification (orchestrator, user present)

- Reconnect after a forced socket close (disconnect Wi-Fi mid-session) and
  after sleep and wake.
- Press while disconnected, speak, release, watch the replay produce a
  transcript after reconnect.
- Rapid successive snippets: press, release, press again immediately, both
  insert in order.
- Escape while listening, Escape while a result is shown.
- Error overlay with no transcript is dismissable and auto-hides.
