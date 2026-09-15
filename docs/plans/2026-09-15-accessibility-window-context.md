# Accessibility window context plan

Status: implemented behind a default-off setting. Automated policy, collection,
privacy-boundary, and invocation-lifecycle coverage is in place. The native
application matrix and speech-corpus tuning remain to be completed with manual
Accessibility access and prepared local model fixtures.

## Outcome and scope

Improve local transcription of identifiers, project names, class names, and
other unusual terms already visible in the window where the user is dictating.
When enabled, Hubris Voice captures an ephemeral Accessibility snapshot after
dictation starts, extracts and ranks likely custom terms, and adds the selected
terms to that invocation's local dictionary correction context.

The active window is the collection boundary. The focused element is a strong
relevance signal, but it is not the only text source. This covers empty input
fields and applications where useful names appear in an editor, document,
sidebar, tab, title, or nearby visible content.

The first release is limited to the existing FluidAudio local engine and its
English correction model. It does not:

- capture screenshots or use Vision OCR;
- send captured text or selected terms to OpenAI or another service;
- persist captured text or selected terms;
- continuously observe applications between dictations;
- modify another application's preferences or enable its screen-reader mode;
- add broad application-specific traversal rules for Xcode, VS Code, terminals,
  or browsers; or
- promise exact spelling when the local correction model lacks sufficient
  acoustic evidence.

## Settled product behavior

- Add a **Use active-window terms** setting for on-device dictation. It defaults
  to off for new and existing users.
- Enabling the setting persists the preference but does not bypass or
  automatically grant macOS Accessibility permission. The Permissions tab
  remains the explicit place to request and manage that permission.
- The setting is active only while FluidAudio is selected, local dictionary
  correction is enabled, the correction model is available, and Accessibility
  permission is granted. Preserve the saved setting while any prerequisite is
  temporarily absent.
- Start microphone capture without waiting for Accessibility collection,
  language classification, term selection, or correction-pipeline preparation.
- Collection is best effort. A timeout, unsupported attribute, unresponsive
  application, empty result, or stale target falls back to the permanent local
  dictionary without failing or delaying transcription.
- Consume the Accessibility tree that the target application currently exposes.
  Applications with an enabled screen-reader mode may expose richer context,
  but correct dictation must not depend on that mode. Hubris Voice never changes
  target-application settings or enables a screen-reader mode.
- Associate captured context with one transcription invocation. Never allow
  terms from an older, cancelled, or timed-out generation to affect another.
- If the focused window changes before release, discard the captured context.
  A focus change within the same window does not invalidate window-wide context.
- If the focused element is a known secure field at capture or revalidation,
  collect and use no window context.
- Discard raw window text as soon as selection completes. Discard selected
  ephemeral terms after the invocation reaches a terminal state.

## Current system and required seam

`TextInsertionService` already resolves the frontmost application, focused
element, focused window, secure-field status, and Accessibility text used for
insertion formatting. These reads currently run on the main actor and are
designed for a few targeted attributes, not bounded traversal of a remote
application's window tree. When its first focused-element lookup fails, it also
writes the generic Electron `AXManualAccessibility` attribute before retrying.
That write does not edit VS Code's `editor.accessibilitySupport` preference, but
its effect on Electron applications' runtime accessibility and screen-reader
mode must be measured before sharing this path with context collection.

`LocalInvocationContext` already separates permanent and ephemeral vocabulary.
The cloud configuration type cannot accept either category. However, the local
backend currently holds one global context and only replaces it during an idle
configuration update. `FluidAudioProcessor` also owns one correction pipeline
built from that global context.

Complete the intended per-invocation seam rather than calling the existing
global configuration update on every shortcut press:

```text
shortcut press
  -> begin audio capture immediately
  -> identify invocation and focused window
  -> collect bounded AX fragments asynchronously
  -> classify and rank candidate terms
  -> submit an ID-scoped ephemeral context update
release
  -> revalidate focused window and secure-field state during capture grace
  -> freeze permanent + accepted ephemeral context for that invocation
  -> finish local transcription and guarded correction
terminal result
  -> discard invocation context
```

Keep Accessibility and AppKit types in `HubrisVoiceApp`. Keep extraction,
ranking, deduplication, and context-composition policy in `HubrisVoiceCore` so
tests can exercise the real policy without controlling other applications.
The local backend receives an ordered, invocation-ID-scoped context update; the
OpenAI backend and Realtime configuration remain structurally unable to receive
the captured context.

The local runtime may queue up to four snippets and finalize them serially.
Store a separate context with each invocation record. The freeze boundary is
when the local state handles `finish(id:)` and changes that invocation's
`finishRequested` flag from false to true. Accept an ID-scoped context update
only before that transition. Context received while a finished invocation waits
behind another queued invocation is still late and must be ignored.
Cancellation, timeout, epoch replacement, and unload retire the associated
context alongside the invocation.

## Accessibility collection

Add an app-owned collector that converts Accessibility objects into plain,
sendable text fragments. Do remote AX messaging away from the main actor. Use a
short `AXUIElementSetMessagingTimeout` and an overall collection deadline so an
unresponsive target cannot stall Hubris Voice.

Resolve the frontmost application, focused window, focused element, and secure
state at invocation start. Traverse each priority branch depth first so deeply
nested Electron and web content is not starved by wide shallow containers. Use
these priorities:

1. Focused element text, selected text, and visible or caret-local ranges.
2. Visible descendants of the focused element's containing editor or scroll
   area.
3. Other visible text-bearing descendants in the focused window.
4. Document, tab, and window titles.
5. General labels and controls, retained at lower relevance.

The collector must establish visibility rather than treating every descendant
of the focused window as visible. Accept descendant text when at least one of
these conditions supplies visibility evidence:

- the element appears through an `AXVisibleChildren` chain;
- its non-hidden bounds intersect the focused window and every known clipping
  or scroll-ancestor viewport;
- an editable text area supplies `AXVisibleCharacterRange`, and text is read
  through the `AXStringForRange` parameterized attribute; or
- the attribute is the focused window, document, or selected tab title.

When `AXVisibleChildren` is unsupported, traverse `AXChildren` only for nodes
whose visibility can be established through hidden state and intersection with
the window plus each known clipping ancestor. If a scroll or clipping ancestor
does not expose enough geometry to prove intersection, exclude the descendant.
Do not read a complete `AXValue` from a scrollable text area or document when a
visible range is unavailable, even when the complete value fits the character
budget. A complete string value is allowed only for a visible, non-scrollable
text control within a small per-control limit. Batch supported attribute reads
where practical. Treat unsupported attributes and individual element failures
as missing evidence rather than failure of the whole snapshot.

Some applications overreport `AXVisibleCharacterRange`. When a text element
supports `AXRangeForPosition`, `AXLineForIndex`, and `AXRangeForLine`, derive the
effective range from the nearest scroll area's screen bounds and retain complete
boundary lines. Ghostty currently reports its complete cached buffer as visible
without exposing range geometry, so keep only its final 200 logical lines through
a centralized bundle-specific fallback. Remove that fallback when Ghostty
provides accurate visibility information.

Use initial defensive limits that are easy to tune from probe evidence:

- 300 ms overall collection deadline;
- 100 ms AX messaging timeout for the target application;
- 2,000 visited elements;
- traversal depth of 24;
- 32,000 collected characters across all fragments; and
- 256 candidate terms submitted for language classification; and
- 40 selected ephemeral terms. Native testing in an identifier-dense T3 Code
  window saturated the initial 20-term cap and excluded newly visible terms.

Return useful partial results when any limit is reached. Normal diagnostics
record only aggregate limit and timing counters. The explicitly enabled,
debug-only development trace may also record captured text, selected terms,
reported and effective ranges, and the strategy used to choose them.

Native probing of T3 Code found visible chat text at depths 19 through 22 and,
in a longer conversation, beyond the 1,500th breadth-first element. Natural
child-order depth-first traversal reached the same content within the first 400
elements. Batched AX attribute reads and the larger traversal limits cover
deeply nested Electron and web accessibility trees while the deadline and
per-message timeout retain the bounded failure behavior.

Each fragment carries enough evidence for selection without retaining AX
objects:

```swift
struct WindowTextFragment: Sendable {
  let text: String
  let source: WindowTextSource
  let relevance: WindowTextRelevance
  let visibility: WindowTextVisibility
}
```

Exact names may change during implementation. The representation must identify
focused, selected, editor-local, title, and general-window sources, along with
the evidence that permitted collection. Geometry is required where it proves
visibility. Use it for ranking only if the native probe shows additional value.

### Screen-reader compatibility

Hubris Voice uses the same Accessibility tree that VoiceOver and other assistive
software consume. Native applications commonly expose this tree without an
explicit mode. Applications such as VS Code can alter the amount and shape of
editor content they expose when their own screen-reader mode is enabled. The
collector must handle both cases by consuming the available tree and returning
partial or empty context when richer content is unavailable.

The context collector must not write `AXManualAccessibility`, change
`editor.accessibilitySupport`, invoke target-application commands, or modify any
other application preference. Test the existing insertion fallback's
`AXManualAccessibility` write separately with VS Code set to `off`, `auto`, and
`on`. If the existing write switches VS Code into Screen Reader Optimized mode
or otherwise changes editor behavior, decouple non-mutating context target
discovery from that fallback before this feature ships. Do not depend on the
write to obtain window content.

## Term extraction and selection

The selector's job is to produce a small set of useful hints, not a list of all
unique words in the window. Existing corpus evidence shows that unrelated
dictionary terms can change surrounding words even when target recovery remains
high, so precision matters more than exhaustive extraction.

Tokenize Unicode text while preserving identifier structure such as camel case,
Pascal case, acronyms, underscores, and mixed alphanumeric names. Preserve the
canonical spelling and capitalization shown in the window. Derive spoken aliases
with the existing deterministic alias policy after a term is selected.

Use the active local model language as the language source. The first model is
English-only, so choose an installed English `NSSpellChecker` locale matching
the user's preferred languages when possible. Do not infer the transcription
language from a code-heavy window. Put the AppKit spell-checker adapter behind a
Core-owned lexicon interface or pass plain classification evidence into Core.

Spell-checking is one signal, never a hard veto. On the current development Mac,
`NSSpellChecker` accepted `HubrisVoice`, `URLSession`, `user_id`, `PostgreSQL`,
`getUserByID`, and `Codex` as correctly spelled. Identifier shape must therefore
override ordinary dictionary membership.

Apply these initial eligibility rules:

- Keep camel-case, Pascal-case, acronym, underscore, and meaningful mixed
  alphanumeric identifiers even when the spell checker accepts them.
- Preserve recognized developer filenames as single candidates and generate
  literal-dot and spoken-dot aliases.
- Drop accepted ordinary lowercase language words unless another strong signal,
  such as selection or repeated occurrence, justifies them.
- Keep unknown alphabetic terms only when supported by relevance, repetition,
  or distinctive capitalization.
- Drop single-character tokens, punctuation-only values, common numeric values,
  URLs, domains, email addresses, filesystem paths, UUIDs, long hexadecimal
  strings, and high-entropy secret-like values.
- Reject candidates that cannot be represented by the correction tokenizer.
- Deduplicate case-insensitively while retaining the highest-ranked canonical
  form. Permanent user entries take precedence over ephemeral collisions.

Rank eligible terms by source relevance, identifier shape, language-dictionary
evidence, repetition, and canonical quality. Selected and focused-editor terms
rank above other window content. Repeated identifiers rank above one-off labels.
Window and document titles can contribute project names, while general controls
receive the lowest weight.

Take at most the configured internal term limit after merging duplicates. Do
not silently limit permanent user vocabulary to make room for window terms. The
probe must measure how permanent vocabulary size changes the safe ephemeral cap;
reduce or disable ephemeral additions when evidence shows that the combined
vocabulary becomes unreliable.

## Local correction lifecycle

Retain the loaded primary ASR model, CTC models, and tokenizer across
invocations. Build only vocabulary-dependent structures for each frozen
invocation context. Vocabulary changes must not reload the primary model or make
the engine globally unavailable.

Correction readiness cannot depend on the permanent dictionary being nonempty.
When correction is enabled, the correction model is installed, and active-window
terms are enabled, acquire and retain the correction assets even if there are no
permanent entries. The first useful ephemeral context must be able to create its
vocabulary-dependent pipeline during capture without reloading either model or
delaying microphone startup. If collection returns no terms, skip correction
work for that invocation while retaining normal readiness for a later one.

The earlier isolated FluidAudio experiment replaced vocabulary in about 6 ms
with relevant terms and 11 ms after adding 30 distractors while retaining the
loaded main model. Production must measure its own path because the current
processor reloads CTC objects while rebuilding its global correction pipeline.

Prepare vocabulary-dependent correction work while audio is streaming when the
context arrives in time. Serialize access to native processor state and preserve
ordered audio submission. At release, run focused-window and secure-field
revalidation concurrently with the existing 100 ms audio capture grace. Use a
short AX messaging timeout no greater than the remaining grace interval. When
the grace completes, accept ephemeral context only if revalidation has already
succeeded; otherwise discard it. Drain final audio and submit `finish(id:)`
without waiting beyond the existing grace. This finish submission freezes the
invocation context.

If context preparation is incomplete at that boundary, use the permanent
context or raw transcription rather than extending the existing eight-second
finalization contract. A late context or revalidation result cannot revise text
or insert after the invocation has retired.

Keep the current acceptance guard around corrected output. Window terms remain
recognition hints supported by acoustic evidence; their presence in the window
does not authorize arbitrary insertion, deletion, or replacement in the spoken
transcript.

## Settings and user feedback

Add a versioned local preference such as
`transcription.local.accessibilityContextEnabled`, defaulting to `false` when
absent. Put the toggle in the local **Transcription context** section near
**Local dictionary correction**.

Suggested copy:

- **Use active-window terms**
- "Temporarily reads visible text from the active window to improve names and
  identifiers. On-device only."

Disable the control when a non-local engine is selected. When local correction
or its model is unavailable, preserve the preference and explain that window
terms require local dictionary correction. When Accessibility permission is
missing, preserve the preference and link or direct the user to the existing
Permissions tab rather than prompting during dictation.

Normal dictation UI should not list captured terms or announce routine fallback.
Settings may expose aggregate status such as "Accessibility required" or
"Available". A development-only inspection tool may show extracted terms during
the native probe, but it must require an explicit action, write no captured
content to logs, and stay out of release builds unless later approved as a user
feature.

## Implementation sequence

### 1. Establish native collection and selection evidence

Build an isolated, explicit probe around synthetic, non-sensitive window
content. Capture the focused element and visible window hierarchy, report AX
roles and aggregate timings, and display extracted fragments and selected terms
only in the probe's direct output. Exercise native AppKit text, Xcode, VS Code,
Terminal, and a browser editor using the same behavior-based collector.

For VS Code, run the same cases with `editor.accessibilitySupport` set to `off`,
`auto`, and `on`. Record what editor and window content each mode exposes. Verify
that Hubris does not change the setting, activate Screen Reader Optimized mode,
or alter folding, minimap, focus, and editor behavior. Repeat the focused-element
fallback separately with and without the existing `AXManualAccessibility` write;
do not include that write in the context collector.

Use the results to confirm attribute priority, traversal limits, timeout
behavior, visibility evidence, and whether geometry improves selection. Record
only sanitized fixtures and aggregate findings in the repository.

### 2. Add pure context-selection policy

Add Core-owned fragment evidence, lexicon boundary, candidate extraction,
ranking, deduplication, permanent-entry precedence, and bounded context
composition. Reuse the existing alias resolver rather than creating a second
identifier pronunciation policy.

### 3. Add bounded Accessibility collection

Extract reusable low-level AX readers without changing insertion behavior. Add
the asynchronous window collector, secure-field rejection, deadline and size
budgets, visibility proof, partial-result handling, and target identity needed
for bounded release-time revalidation. Keep the collector's reads non-mutating.

### 4. Make local context invocation-scoped

Extend the local backend with ordered, invocation-ID-scoped ephemeral context.
Store and freeze context per queued invocation. Separate retained CTC assets from
vocabulary-dependent correction state, and ensure configuration edits still
apply only at the existing quiescent boundary. Cover the first ephemeral context
when correction is enabled and the permanent dictionary is empty.

### 5. Integrate the opt-in lifecycle and setting

Persist the default-off preference, add the settings control and prerequisite
status, start collection only after local audio capture begins, revalidate the
window within the existing release grace, freeze context when finish is
requested, and clear context on every terminal path. Preserve cloud,
correction-disabled, and Accessibility-denied behavior.

### 6. Tune against speech and application evidence

Extend the existing local speech corpus with technical phrases whose canonical
terms appear in controlled windows. Compare no context, manually selected ideal
context, automatically selected AX context, and deliberately distracting window
content. Tune ranking and limits using both exact-term recovery and total word
edits; target recall alone is insufficient.

### 7. Document final behavior

Update the README, local transcription reference, permission copy, and remaining
manual-validation list with observed behavior and limitations. Describe the
feature as best-effort local context, not guaranteed correction.

## Verification strategy

### Automated policy and lifecycle tests

- Candidate extraction preserves representative identifiers and Unicode while
  rejecting ordinary words and secret-like or structural noise.
- Locale-aware known-word evidence affects natural words but does not remove
  identifier-shaped terms.
- Ranking, repetition, deduplication, permanent-entry precedence, and the
  ephemeral cap are deterministic.
- Fake AX trees cover visible-child preference, unsupported attributes, cycles,
  secure focus, hidden descendants, an offscreen identifier in a small
  scrollable document, geometry refinement of an overreported terminal range,
  the bounded Ghostty fallback, oversized values, depth, node, character, and
  time limits, and useful partial results.
- Microphone capture starts without awaiting context collection.
- Cloud, correction-disabled, model-unavailable, setting-disabled, and
  Accessibility-denied paths never collect or submit window terms.
- Same-window focus changes retain context; window changes, cancellation,
  timeout, epoch replacement, and late completion discard it.
- Four pending invocations retain distinct frozen contexts and cannot consume a
  neighboring generation's terms. An update arriving after `finishRequested`
  becomes true is rejected even while that invocation remains queued.
- Distinctive sentinel window text never reaches Realtime payloads, settings,
  history, or sanitized diagnostic logs. An explicitly enabled debug-build
  development trace records captured fragments, candidates, selected terms,
  aliases, range strategies, raw and candidate correction text, guard decisions,
  and context lifecycle decisions.
- Per-invocation vocabulary replacement retains loaded primary and CTC assets,
  and correction failure preserves usable raw text.
- With correction and active-window terms enabled, an empty permanent dictionary
  can acquire correction assets, accept the first ephemeral terms, and correct
  without delaying microphone startup. An empty ephemeral result performs no
  correction work for that invocation.

### Runtime and manual evidence

- Run the focused local correction and invocation-lifecycle tests while the
  implementation evolves, then run `mise run check` for handoff.
- Run the network-denied local runtime smoke with permanent and ephemeral
  contexts after the native pipeline changes.
- With the user present, verify the default-off state, settings persistence,
  Accessibility-denied behavior, secure fields, rapid press and release,
  locked dictation, application switching, and final insertion.
- In VS Code, verify `editor.accessibilitySupport` values `off`, `auto`, and `on`.
  Hubris must not change the configured value, activate Screen Reader Optimized
  mode, or rely on it for correct dictation. Record the context available in
  each mode as compatibility evidence.
- Probe the existing `AXManualAccessibility` fallback independently and confirm
  whether it changes Electron or VS Code runtime behavior before sharing any AX
  discovery code with the collector.
- Exercise native and custom UI applications by observed AX capability. Keep
  application-specific exceptions centralized, bounded, and supported by probe
  evidence, as with the temporary Ghostty trailing-line fallback.
- Compare automatic context with the baseline and manually selected ideal terms
  on fresh microphone recordings. Do not enable the feature by default or
  recommend general use if surrounding-word regressions outweigh identifier
  recovery.

## Risks and recovery

- Broad AX trees can be slow or internally inconsistent. Deadlines, bounded
  traversal, partial results, and fallback to permanent vocabulary contain this.
- Applications and screen-reader modes expose different tree shapes. The
  capability-based collector, non-mutating reads, explicit mode matrix, and
  graceful fallback preserve compatibility without target-app configuration.
- Window-wide text can contain sensitive material. Explicit opt-in, secure-field
  rejection, local-only processing, no persistence, and sentinel privacy tests
  define the boundary.
- Distractor terms can worsen otherwise correct speech. Conservative ranking,
  a small cap, the existing correction guard, and comparative corpus evaluation
  address this risk.
- Dynamic context may complicate the serial local runtime. Per-invocation
  ownership and generation rejection preserve the current cancellation and
  insertion guarantees.
- Applications may expose little useful text. This is normal fallback behavior,
  not an error requiring app-specific code.

The setting provides immediate rollback: turning it off restores the current
permanent-dictionary behavior without changing stored local vocabulary. If the
local runtime refactor proves unreliable, ship the selector and collector only
as a development probe until invocation-scoped correction is ready.

## Unresolved questions

- What collection and term limits give the best precision and latency across
  the native application matrix? The listed values are initial defensive
  guardrails for the probe.
- Does AX geometry materially improve relevance beyond focused-element,
  ancestor, role, and repetition evidence?
- At what combined permanent and ephemeral vocabulary size should Hubris Voice
  reduce or suppress automatic terms?
- Does the existing `AXManualAccessibility` insertion fallback change Electron
  or VS Code accessibility mode or editor behavior? If so, context discovery
  must be decoupled from that mutating fallback before release.
- Should a later release offer an explicit user-facing preview of terms selected
  from the current window? This is not part of the first implementation.
