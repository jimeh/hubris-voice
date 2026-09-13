# Milestone 7: pill overlay and insertion without clicks

Design brief for milestone 7 of [the daily driver plan](2026-09-13-daily-driver.md).
Builds on milestones 1 through 6. Part A is core and app policy with no UI
and can be delegated. Part B is the overlay itself and is implemented by the
orchestrator.

Mockups that settled the design:

- Three overlay designs, pill chosen:
  https://plans.jimeh.dev/ugysg2ovstyffjt2qbdkm2d6iq/hubris-voice-overlay-designs.html
- Long transcript behavior, three-line cap chosen with a configurable cap:
  https://plans.jimeh.dev/zqivw5b7prkyk2dxkwqevzv6ou/hubris-voice-pill-long-text.html

## Outcome

- The overlay is a capsule containing only the live transcript and five
  mic-level bars. No title, timer, "release to insert" copy, or buttons. The
  panel itself is the listening indicator.
- The transcript wraps to a configurable cap of 1 to 6 lines, default 3.
  Older lines scroll up behind a fade. A cap of 1 never wraps: the newest
  words stay pinned at the right and older text slides off the left.
- Text is inserted wherever the caret is when the transcript arrives. The
  only reasons an insertion is not attempted are a secure field and no
  editable focus at all.
- Nothing ever waits for a click. Confirmed and attempted insertions hide the
  pill at once. The remaining failures show a one-line reason with the
  paste-last shortcut as the recovery, then hide.
- The clipboard is touched only by the Cmd+V fallback and is always
  restored afterwards. No outcome leaves the transcript on the clipboard.

## Decisions carried in from the discussion

| Outcome | Before | After |
| --- | --- | --- |
| Confirmed | Hide | Hide, icon flash |
| Attempted | Linger with Copy | Hide, icon flash, history records attempted |
| Focus moved | Rejected, Copy | Insert at the current focus |
| No editable focus | Rejected, Copy | Reason plus recovery hint, hide after linger |
| Timed out or error with text | Copy | Reason plus recovery hint, hide after linger |
| Secure field | Copy | Reason plus recovery hint, hide after linger |

- Return no longer does anything in attention. Escape still dismisses.
  Copy remains an explicit action in the menu bar and the History tab.
- The paste-last shortcut stays unset by default. When it is unset, the
  recovery hint points at the menu bar instead of naming a key.
- Always dark, regardless of system appearance. Reduce Motion freezes the
  bars at a mid level with a slow opacity pulse. Reduce Transparency drops
  the blur for a solid fill.
- The panel ignores the mouse and stays non-activating.
- Empty listening state is the bars alone.
- Finalizing dots pulse slowly so a long round trip does not look frozen.
- Rendering is append-only. Earlier lines never reflow.

## Part A (delegable): policy and state

### Core: `DictationSettings`

Add `overlayLineCap: Int` with key `overlay.lineCap`, default 3. `load`
clamps any stored value into `1...6`; `save` writes the integer. The
`SettingsStore` protocol needs an `integer(_:)` accessor; add it and the
`UserDefaults` conformance.

### Core: `PasteSafety` reduces to the secure check

In `InteractionPolicy.swift`:

- Delete `PasteDecision` and `PasteSafety.decision(captured:current:)`.
- `PasteSafety.canPaste(current: FocusSnapshot) -> Bool` returns
  `!current.isSecure`.
- Remove `elementToken` from `FocusSnapshot` if nothing else reads it after
  the change. Keep `processID` for diagnostics.
- `DictationSession.RejectionReason` loses `.focusChanged`. Remaining cases:
  `.noTarget`, `.secureField`.

### Core: `OverlayPresentation`

```swift
public struct OverlayPresentation: Equatable, Sendable {
  public enum Mode: Equatable, Sendable {
    case listening
    case finalizing
    case attention
  }

  public let mode: Mode
  public let transcript: String
  /// Empty while everything is normal. Non-empty only for connection status
  /// while listening and for the reason in attention. Never a key hint; the
  /// app appends the recovery hint because it owns the shortcut settings.
  public let message: String
  public let pendingCount: Int
  public let isLocked: Bool
}
```

`canCopy`, `canPasteHere`, `canDismiss`, and the `completed` and `copied`
modes are gone. `OverlayLayoutPolicy` is replaced in part B.

### Core: `DictationSession`

Remove `Event.copied`, `Event.pasteHereRequested`, `wasCopied`,
`Configuration.copiedLinger`, and `PresentedResult.attempted`. `confirmed`
was never presented either; remove it so `PresentedResult` is exactly the
attention cases:

```swift
public enum PresentedResult: Equatable, Sendable {
  case rejected(text: String, reason: RejectionReason)
  case timedOut(text: String)
  case error(message: String, text: String)
}
```

Transition changes:

- `insertionFinished` with `.confirmed` or `.attempted`: `presented = nil`,
  effects `[.discardSnippet, .cancelDismiss]`. Both are done from the
  session's point of view; the app distinguishes them for history, sound,
  and the log.
- `insertionFinished` with `.rejected`: set `presented`, effects
  `[.discardSnippet, .cancelDismiss, .scheduleDismiss(after: attentionLinger)]`.
  Every attention result now auto-dismisses, including those with text,
  because the recovery is the shortcut, not the pill.
- `finalizingTimedOut`, `serverError`, `localError`: always append
  `.scheduleDismiss(after: attentionLinger)`, dropping the "only when text is
  empty" condition.
- `pasteLastRequested` is unchanged. A rejected paste-last presents the
  rejection like any other.

Presentation messages:

- Listening: `""` when ready and unlocked. Keep `"Connecting…"`,
  `"Reconnecting…"`, and the unconfigured message, since they explain why no
  text is arriving. Locked is carried by `isLocked`, not the message.
- Finalizing: `""`.
- Attention reasons, no trailing hint and no "copy" wording:
  `.noTarget` → `"No text field is focused"`, `.secureField` →
  `"Secure field"`, `.timedOut` → `"No transcript arrived"`, `.error` →
  the message as received.

`phaseTitle`: drop the "Paste attempted" branch. Rejected and timed out
stay "Transcript ready"; error stays "Needs attention".

Update the transition table in `milestone-1-reliability.md` to remove the
copy and paste-here rows and mark attempted as hiding immediately.

### App: `TextInsertionService`

- `paste(_:into:expected:)` becomes `insert(_ text: String, expected: String)`
  and resolves the focused target at call time. Order inside is unchanged:
  no focus → `.rejected(.noTarget)`; secure → `.rejected(.secureField)`;
  direct Accessibility write when settable; else Cmd+V. The ambiguous direct
  write is still final and never followed by a clipboard paste.
- `pasteAtCurrentFocus` becomes a thin alias of `insert` or is removed.
- `focusRejection` and its element comparison are deleted.
- `captureAnchor(for:)` remains and is still taken at key press for overlay
  placement. `captureFocusedTarget` remains for that purpose and for
  formatting context.
- Clipboard restore semantics are unchanged. Delete nothing there.

### App: `AppModel`

- `focus[generation]` is no longer needed for insertion. Remove the map and
  read formatting context from the focus resolved at insertion time.
- Delete `handleReturn`, `capturesReturn`, `copyResult`, and the
  `rejectedPasteLastText` clipboard copy in `apply`. Keep Escape.
- `flashConfirmed()` fires for `.attempted` as well as `.confirmed`.
- Sounds: `.confirmed` and `.attempted` play the pasted cue when enabled;
  `.rejected` plays the rejected cue.
- History outcomes are unchanged: confirmed → pasted, attempted → attempted,
  rejected → rejected, timed out → timedOut.
- Compose the overlay message for attention states:
  `"\(presentation.message) · \(hint)"` where `hint` is
  `"\(binding.displayName) inserts it"` when a paste-last shortcut is set and
  `"Copy it from the menu bar"` otherwise. Pass the composed string to the
  overlay model; the core message stays reason-only.
- Menu bar: keep the last transcript row with Copy. This is the explicit
  copy path.

### App: settings row

General tab, directly under Overlay placement: a `Stepper` labeled
"Overlay lines" bound to `overlayLineCap`, range 1 to 6, with the footnote
"1 keeps a single line and scrolls sideways." Persist on change like the
other rows.

### Tests (part A)

`DictationSettingsTests`: line cap default 3; stored 0 loads as 1; stored 9
loads as 6; round trip.

`InteractionPolicyTests`: `canPaste` is true for a non-secure snapshot in a
different process from the one captured at press, false for secure. Delete
the element-token and process comparison tests.

`DictationSessionTests`:

- attempted insertion clears `presented` with no dismiss scheduled, same as
  confirmed;
- rejected insertion presents the reason and schedules a dismiss;
- timed out with partial text schedules a dismiss;
- the listening presentation has an empty message when ready;
- `pasteLastRequested` still creates an inserting snippet and the effect.

Delete tests for copied, pasteHere, canCopy, canPasteHere, and canDismiss.
`OverlayPresentationTests` is replaced in part B.

### Checkpoints (part A)

1. Core settings, `PasteSafety`, presentation, and session changes with
   tests. Milestone 1 table updated.
2. App insertion service and model changes. `mise run check` green.
3. Self-review per the milestone 1 brief, plus: grep for any remaining
   `copy(` call that runs without an explicit user action, and confirm none
   exists.

## Part B (orchestrator): the pill

### Geometry

| Property | Value |
| --- | --- |
| Padding | 10 pt top and bottom, 14 pt leading, 16 pt trailing |
| Bars to text gap | 12 pt |
| Corner radius | 22 pt continuous |
| Font | SF Rounded 15.5 pt medium, line height 22 pt |
| Bars | 5 capsules, 3 pt wide, 2.5 pt gap, height 3 to 20 pt, in a 22 pt box |
| Max width | 440 pt, or 45 percent of the target screen's visible width if smaller |
| Min width | bars plus padding, about 50 pt |
| Height | padding plus `min(lines, cap) × 22`, so 42 pt for one line |
| Fill | carbon at 94 percent over a 20 pt blur, 1 pt border at white 9 percent |
| Attention border | coral at 35 percent |

Width follows the text up to the max. Height follows the line count up to
the cap. Measure with `NSString.boundingRect` as `OverlayLayout` does today;
keep the measurement in the app and the arithmetic in the core.

### Core: `PillLayoutPolicy`

Replaces `OverlayLayoutPolicy` in `OverlayPresentation.swift`:

```swift
public struct PillLayoutPolicy: Equatable, Sendable {
  public var lineHeight: Double = 22
  public var lineCap: Int = 3
  public var verticalPadding: Double = 10
  public var leadingChrome: Double   // padding + bars + gap
  public var trailingPadding: Double
  public var maximumWidth: Double

  public var isSingleLine: Bool { lineCap == 1 }
  public func visibleLines(measuredLines: Int) -> Int
  public func panelSize(measuredTextWidth: Double, measuredLines: Int) -> LayoutSize
}
```

`visibleLines` is `max(1, min(measuredLines, lineCap))`. `panelSize` clamps
the width to `maximumWidth` and never lets it fall below the chrome plus one
character.

### Core: `OverlayPlacement` alignment

The pill's width changes as words arrive, so centering it on the anchor
makes it jitter. Add leading alignment for caret and element anchors: the
panel's left edge sits at `anchor.rect.minX`, and only the window anchor
and the screen fallbacks stay centered. Vertical behavior is already right:
above the anchor keeps the bottom edge fixed, below keeps the top edge
fixed, and the two screen placements keep their outer edge fixed. Add a test
for the leading case and for the clamp when a leading-aligned panel would
run past the right screen edge.

### Layout modes

Cap of 2 to 6: a wrapping `Text` inside a clip view whose height is
`visibleLines × lineHeight`, anchored to the bottom, with a top gradient
mask from clear at 2 pt to opaque at 26 pt applied only when the text
overflows. The existing `ScrollViewReader` with a bottom anchor covers the
scroll; replace its fixed viewport arithmetic with the policy.

Cap of 1: a single-line `Text` with `fixedSize()` inside a clip frame
aligned trailing, with a left gradient mask from clear at 0 to opaque at
48 pt when it overflows. Max text width is the panel max minus chrome.

Switching the cap while the pill is visible re-lays out in place. No
animation on height changes; a 0.15 s ease on width is fine.

### States

| State | Bars | Caret | Message line |
| --- | --- | --- | --- |
| Listening | Live levels from the last five `record(level:)` samples | Blue 2 pt bar, blinking 1 Hz | Hidden unless the connection message is non-empty |
| Locked | Live levels, lock glyph 10 pt before the bars | Same | Hidden |
| Finalizing | Five 3 pt dots at faint, pulsing opacity 0.4 to 0.8 over 1.2 s | Faint, not blinking | Hidden |
| Attention | One 8 pt coral dot with a 4 pt halo | Hidden | Muted 11 pt sans, composed reason plus hint |
| Pending > 0 | `+N` in muted 10 pt mono directly after the bars | | |

Reduce Motion: bars sit at 0.5 with opacity pulsing 0.7 to 1.0 over 2 s; the
caret does not blink; finalizing dots do not pulse. Reduce Transparency:
carbon at 100 percent and no blur.

### Wiring

- `OverlayViewModel` drops `elapsed`, `canCopy`, `canPasteHere`,
  `canDismiss`, and the default "Hold … release" message. `levels` becomes
  five entries.
- `OverlayController.init` drops the `onPasteHere`, `onCopy`, and
  `onDismiss` closures. The panel gets `ignoresMouseEvents = true`.
- `OverlayController` takes the line cap from settings and re-lays out on
  change. `AppModel` publishes `overlayLineCap` like `overlayPlacement`.
- Remove the elapsed-time task in `AppModel`.
- `menuSystemImage` and the icon flash are unchanged apart from attempted.

### Tests (part B)

`PillLayoutPolicyTests`: visible lines at 0, 1, cap, and cap plus one for
caps 1 and 3; panel size clamps width to the max; single-line policy reports
`isSingleLine`. `OverlayPlacementTests`: leading alignment for caret and
element anchors, centered for window, right-edge clamp.

The view itself is verified by hand; there is no snapshot harness and this
change does not justify building one.

### Checkpoints (part B)

1. Policy and placement changes with tests.
2. The pill view and controller. `mise run check` green.
3. `mise run verify` green, signed bundle built.

## Documentation

- `AGENTS.md`: replace the two guarded-paste bullets with: insertion goes to
  the focused element at transcript time and rejects only secure fields and
  missing focus; `CGEvent.post` is still not proof of success, so an
  unobservable paste is recorded as attempted, hides like a success, and the
  paste-last shortcut and menu bar Copy are the recovery path; nothing may
  place text on the clipboard without an explicit user action.
- `README.md`: rewrite the first paragraph to describe the pill, the line
  cap, insertion at the current focus, and the recovery shortcut.
- `PLAN.md`: replace the focus-safe paste scope line and update the manual
  test list.
- `2026-09-13-daily-driver.md`: add milestone 7 to the index and the status
  line.

## Manual verification with the user

1. Empty listening state shows bars only, anchored at the caret's left edge.
2. Speak a long passage at caps 1, 3, and 6. Confirm the fade, the fixed
   height, no reflow of earlier lines, and that changing the cap in Settings
   applies while the pill is visible.
3. Growth direction above a field near the top of the screen (flips below,
   top edge fixed) and with the bottom-of-screen preference.
4. Dictate, Cmd-Tab to another app mid-sentence, release: the text lands in
   the second app. Undo removes it.
5. TextEdit, Safari, Notes, and Terminal confirm and hide. Slack hides on
   attempted and the icon flashes. History shows the right outcome for each.
6. Release with the desktop focused: reason plus hint, hides after about
   4 s, Escape hides it sooner. Then focus a field and use the paste-last
   shortcut; the text lands.
7. Same with the paste-last shortcut unset: the hint names the menu bar.
8. A password field: reason shows, nothing is inserted, clipboard untouched.
   Check by copying something first and pasting after.
9. Confirmed insertion via Cmd+V restores the previous clipboard within
   about 1.5 s.
10. Reduce Motion and Reduce Transparency on, in System Settings, with the
    pill visible.
11. Tap to lock shows the lock glyph; a second snippet queued shows `+1`.
