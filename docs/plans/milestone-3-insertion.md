# Milestone 3: text insertion quality and overlay lifetime

Design brief for milestone 3 of [the daily driver plan](2026-09-13-daily-driver.md).
Builds on milestones 1 and 2. Part A is delegated; part B is implemented by
the orchestrator after part A lands, because it touches the riskiest path.

## Outcome

- Confirmed means the expected text is observably in the field. Only then
  does the overlay hide, and it hides immediately.
- Text inserted mid-sentence gets a leading space when the caret follows a
  word, and an optional trailing space. No case changes by default.
- A rejected or unconfirmed result can be pasted into whatever is focused
  now with one key, or copied, or dismissed, all from the keyboard.
- Native fields that expose a settable selection get direct Accessibility
  insertion with no clipboard involvement (part B).

## Part A (delegated)

### Core: `PasteConfirmation` strengthening

In `InteractionPolicy.swift`, replace the current "any change" rule:

```swift
public enum PasteConfirmation {
  public static func outcome(
    before: AccessibleTextState?,
    after: AccessibleTextState?,
    expected: String
  ) -> PasteOutcome
}
```

Rules, first match wins:

1. `before == nil || after == nil` → `.attempted`.
2. Both values known and `before.selectionLocation` known: let `loc` and
   `len` be the selection (len defaults to 0). Confirmed iff
   `after.value.utf16.count == before.value.utf16.count - len + expected.utf16.count`
   and the UTF-16 substring of `after.value` at `[loc, loc + expected.utf16.count)`
   equals `expected`.
3. Both values known, location unknown: confirmed iff
   `after.value.utf16.count == before.value.utf16.count + expected.utf16.count`
   and `after.value` contains `expected`.
4. Otherwise `.attempted`. A caret move alone is never confirmed.

Keep the two-argument overload out; update the one call site.

### Core: `InsertionFormatter`

`Sources/HubrisVoiceCore/InsertionFormatter.swift`:

```swift
public struct InsertionFormatter: Equatable, Sendable {
  public struct Options: Equatable, Sendable {
    public var smartLeadingSpace: Bool = true
    public var trailingSpace: Bool = true
    public var adjustCaseAfterComma: Bool = false
    public var protectedTerms: [String] = []    // dictionary entries
  }
  public struct Context: Equatable, Sendable {
    public var textBeforeCaret: String?   // nil when the field exposes no value
    public var textAfterCaret: String?
  }
  public static func format(_ transcript: String, context: Context, options: Options) -> String
}
```

Rules:

- Trim the transcript of leading and trailing whitespace first. Empty in,
  empty out.
- Leading space is added when `smartLeadingSpace` and `textBeforeCaret` is
  non-nil and non-empty and its last character is not whitespace, not a
  newline, and not an opening bracket or quote (`(`, `[`, `{`, `"`, `'`,
  `“`, `‘`). So a leading space follows a word character or closing
  punctuation.
- Trailing space is added when `trailingSpace` is on and
  (`textAfterCaret` is nil, empty, or its first character is not
  whitespace and not closing punctuation `.,;:!?)]}`). When context is
  entirely unknown (`textBeforeCaret == nil`), trailing space still applies
  if the option is on. Leading space never applies without context.
- `adjustCaseAfterComma`, when on: if the text before the caret, ignoring
  trailing whitespace, ends with `,` and the transcript's first word is not
  "I", not in `protectedTerms` (case-insensitive match), and does not
  contain an uppercase letter after its first character, lowercase the
  first letter.
- Never modify anything else.

### Core: session changes for recovery paste and immediate hide

In `DictationSession`:

- `Event.pasteHereRequested`: valid when `presented` is `.attempted`,
  `.rejected`, or `.timedOut` with non-empty text. Allocates a new
  generation, appends a `Snippet` with that text to `inserting`, sets
  `presented = nil`, and returns
  `[.cancelDismiss, .insertAtCurrentFocus(generation:, text:)]`. Otherwise
  no-op.
- `Effect.insertAtCurrentFocus(generation: Int, text: String)`: the app
  captures a fresh focus and pastes there, then feeds `insertionFinished`.
- `insertionFinished(g, .confirmed)`: `presented = nil`, effects
  `[.discardSnippet(g), .cancelDismiss]`. No linger. Remove
  `confirmedLinger` from `Configuration` unless `copied` still uses it
  (it does; keep it and rename to `copiedLinger`).
- `OverlayPresentation.canPasteHere: Bool`: true when mode is `.attention`
  and the transcript is non-empty.
- `phaseTitle` no longer has a "Pasted" state from `presented`; the app
  reports the flash through `lastConfirmedAt` (below).
- Update the transition table in `milestone-1-reliability.md` for these
  rows, and the tests that asserted the confirmed linger.

### App: `TextInsertionService`

- `paste(_:into:)` gains `expected: String` and passes it to the
  confirmation. It formats nothing itself; formatting happens in the model.
- Add `func currentTextContext(for focus: CapturedFocus) -> InsertionFormatter.Context`
  built from `accessibleTextState` on the captured element: split the value
  at `selectionLocation` (UTF-16), with `textAfterCaret` starting at
  `selectionLocation + selectionLength`. Both nil when the value is nil.
- Add `func pasteAtCurrentFocus(_ text: String) async -> PasteResult`:
  capture focus now, reject `secureField` if secure, otherwise reuse the
  clipboard path with the captured focus as both target and current.
- Extend the clipboard restore window from 700 ms to 1500 ms. Keep the
  existing `changeCount` guard.

### App: `AppModel`

- Options come from `UserDefaults`: `insertion.smartLeadingSpace` (true),
  `insertion.trailingSpace` (true), `insertion.adjustCaseAfterComma`
  (false). Expose as `@Published` and persist on change. `protectedTerms`
  is the dictionary.
- In `insert(generation:text:)`: build the context from the captured focus,
  format, then paste the formatted text with `expected: formatted`. The
  history entry (milestone 6) stores the unformatted transcript.
- `insertAtCurrentFocus`: format against the fresh focus, paste, feed
  `insertionFinished`.
- Record `releasedAt[generation]` when `.released` is applied and log
  `insert latency=<ms> outcome=<outcome>` to `DiagnosticLog` on
  `insertionFinished`.
- `@Published private(set) var lastConfirmedAt: Date?` set on confirmed
  insertion; the menu bar icon reads it for a short mint flash (orchestrator
  wires the visual).

### App: keyboard control in attention mode

- `PushToTalkMonitor.capturesReturn: Bool` alongside `capturesEscape`.
  When true, Return (key code 36) key down is consumed and reported through
  `onReturn`.
- `AppModel.publishSessionState` sets `capturesReturn = presentation?.mode == .attention`.
  On Return: `pasteHereRequested` if `canPasteHere`, else `copied` via
  `copyResult()`.
- Overlay footer: show a "Paste here" button when `canPasteHere`, before
  Copy. Keep Copy and Dismiss.

### App: settings rows

Add three toggles under a new "Insertion" section: "Smart leading space",
"Trailing space", "Adjust case after commas". Plain `Toggle` rows in the
existing section style; the settings redesign is milestone 4.

### Tests (part A)

`PasteConfirmationTests` (new file or extend `InteractionPolicyTests`):
exact insertion at the caret confirms; caret move without text change is
attempted; text inserted elsewhere is attempted; missing states are
attempted; location-unknown path confirms only on exact growth plus
containment; selection replacement (len > 0) confirms.

`InsertionFormatterTests`: leading space after a word; none after a space,
newline, or opening bracket; none without context; trailing space before
end, none before a comma; case adjustment off by default; on, lowercases
after a comma but not "I", a protected term, or "OpenAI"; empty transcript;
non-Latin text passes through unchanged.

`DictationSessionTests`: `pasteHereRequested` from rejected creates an
inserting snippet and the effect; no-op from listening; confirmed insertion
clears `presented` with no linger; `canPasteHere` derivation.

### Checkpoints (part A)

1. Core confirmation and formatter with tests.
2. Session changes with tests and the milestone 1 table updated.
3. App wiring, keyboard control, settings rows. `mise run check` green.
4. Self-review per the milestone 1 brief, plus: confirm no path can insert
   the same text twice for one generation.

## Part B (orchestrator)

Direct Accessibility insertion in `TextInsertionService.paste`:

1. If the captured element reports `AXUIElementIsAttributeSettable` for
   `kAXSelectedTextAttribute` and `accessibleTextState` returns a value:
   read `before`, set the attribute to the formatted text, wait 50 ms, read
   `after`, and return `PasteConfirmation.outcome(before:after:expected:)`.
   A `.confirmed` result is final. An `.attempted` result is final too:
   never follow an ambiguous write with a clipboard paste.
2. Fall back to the clipboard path only when the attribute is not settable,
   or the set call returns an error and `after == before`.
3. Log which path was taken with the outcome.

Manual verification with the user: TextEdit, Safari text area, Notes,
Terminal, Slack (Electron, expected clipboard path), a secure field, Return
to paste-here after moving focus, Return to copy when nothing is pastable.
