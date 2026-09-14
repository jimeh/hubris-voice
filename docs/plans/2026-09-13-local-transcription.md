# Local transcription implementation plan

Status: implementation and automated verification are complete; manual
daily-driver validation remains. The engine migration,
local runtime and dictionary, model service, and settings UI are implemented.
Model ownership, a real verified install, native network-denied transcription,
and Xcode 27 release packaging have passed. Xcode 16.0/26.3 CI also passed at
`9c03199`. Jim has verified ordinary local dictation, downloads, and correction;
the remaining device/sleep-wake and accessibility checks are still manual. Jim requested
`gpt-5.6-sol` implementor sub-agents at medium effort; the parent owns integration
and model-management UI. Final behavior and validation limits are recorded in
[the local transcription reference](../reference/local-transcription.md).

## Outcome and first release scope

Add an explicitly selectable offline transcription backend to the existing
push-to-talk flow. Start with FluidAudio and Parakeet Unified English 0.6B at
320 ms, using the tested strict dictionary settings and spoken aliases. Dictionary
correction defaults to enabled; users can disable it. Installed local dictation
must work without network access or an OpenAI API key. Existing users retain their cloud
selection and behavior until they choose otherwise. OpenAI also remains the
default for new installations.

The first complete release includes model download, validation, selection,
removal, readiness feedback, and recovery from failed downloads. An earlier
internal milestone may use explicitly supplied, verified model files. Model
downloads require an explicit action; pressing the dictation shortcut never
starts a download or silently falls back to cloud transcription.

Retain seams for additional models and engines, but implement one local model
first. sherpa-onnx, WhisperKit, Apple Speech, automatic Accessibility vocabulary,
and model recommendation algorithms are follow-up work. This avoids treating
the existing sherpa offline hotword experiment as proof of streaming hotwords.

## Evidence and current constraints

The [experiment harness](../../Experiments/LocalSTT/README.md) pins FluidAudio
0.15.7. The correction sweep ran 504 native conditions plus a 72-condition
single-pass probe. On Jim's 18 recordings, strict 320 ms correction plus the
acceptance guard recovered 41/42 canonical targets, compared with 22/42 raw.
Script word edits fell from 41 to 10 with the mixed dictionary, with no measured
excess dictionary mentions. Default correction recovered 42/42 but worsened six
clips. These settings were selected using this same small corpus; they are not
validated defaults for arbitrary voices or context lists.

The guard recovered a word deleted by native correction. `consumeTokenTimings()`
provided raw text alongside corrected text in the same inference pass: all 72
raw transcripts matched separate baselines, and corrected output was unchanged.
The guard itself has only been applied to completed transcripts in the harness.
Human audio and detailed reports remain in ignored
`Experiments/LocalSTT/.build/human/correction/`; production tests must not depend
on those private or potentially absent files.

Production boundaries observed before implementation:

| Current owner | Relevant behavior | Planned change |
|---|---|---|
| [DictationSession](../../Sources/HubrisVoiceCore/DictationSession.swift) | Generations, pending snippets, timeout, insertion; also cloud item IDs, ACKs, reconnect | Keep dictation policy; move wire correlation and reconnect machinery behind the cloud backend |
| [AppModel](../../Sources/HubrisVoiceApp/AppModel.swift) | Direct client calls, buffers, transport attempt gate, history and settings coordination | Consume common engine events and commands; preserve final insertion gates |
| [RealtimeTranscriptionClient](../../Sources/HubrisVoiceApp/RealtimeTranscriptionClient.swift) | Ordered outbound actions and WebSocket attempt identity | Keep transport; wrap it with cloud-specific invocation correlation and recovery |
| [AudioCapture](../../Sources/HubrisVoiceApp/AudioCapture.swift) | PCM16 mono at 24 kHz | Configure 24 kHz cloud or 16 kHz local before capture starts |
| [AudioSnippetBuffer](../../Sources/HubrisVoiceCore/AudioSnippetBuffer.swift) | Byte cap equivalent to 90 seconds at 24 kHz | Calculate the cap from duration and the selected PCM format |
| [CaptureFinalizer](../../Sources/HubrisVoiceApp/CaptureFinalizer.swift) | 100 ms release grace; final chunks precede commit; rapid re-press | Preserve ordering with engine-neutral end-of-audio |
| [DictationSettings](../../Sources/HubrisVoiceCore/DictationSettings.swift) | Cloud settings and string-only dictionary persistence | Add engine/model selection and a separately scoped local vocabulary |
| [SettingsTabs](../../Sources/HubrisVoiceApp/SettingsTabs.swift) | Cloud configuration and dictionary copy | Add capability-aware engine/model and local dictionary controls |

Read [Realtime wire behavior](../reference/realtime-transcription.md) before
migrating cloud events. Preserve live pre-commit previews, late ACK tombstones,
commit rejection correlation, replay on reconnect, and rejection of retired
transport attempts. History preparation currently switches on cloud events too;
update it with the lifecycle migration rather than leaving a second wire mapping.

## Recommended boundary

Use a long-lived backend runtime with an ordered command channel and events
identified by backend epoch and snippet generation. A loaded model can serve
many invocations. Keep Core free of FluidAudio, AVFoundation, and application
frameworks. Initially place adapters and native infrastructure in the app target;
do not add a plugin framework or a package per engine.

Conceptual caller flow, with final Swift names settled in milestone 1:

```text
select engine/model -> prepare -> readiness event
press -> snapshot configuration/context -> begin(epoch, generation, format)
capture -> ordered append(generation, sequence, PCM chunk)
release -> capture grace ends -> finish(generation)
events -> preview replacement -> final accepted text -> existing insertion queue
cancel -> retire generation immediately -> request backend cancellation
```

Core-owned values describe engine/model identity, PCM format, readiness,
invocation identity, vocabulary entries, preview replacement, final result, and
typed recoverable failures. The runtime protocol belongs at the native boundary.
Do not expose provider item IDs, commit ACKs, CoreML objects, or socket state to
the generic dictation reducer.

### Required interface behavior

- Identity is `(backend epoch, snippet generation)`. Retire an epoch on backend
  replacement and a generation on cancellation/timeout. Reject stale events both
  before reducer updates and before insertion; a cancelled native task returning
  successfully must still be harmless.
- Deliver complete preview snapshots, not append-only deltas. The cloud adapter
  assembles its deltas. Start the local UI with raw previews and guarded final
  text, so unaccepted native corrections never appear as trusted live output.
  Guarded intermediate revisions can follow after segment-boundary validation.
- Emit at most one terminal result per live generation. Final output includes
  accepted text and a correction outcome such as disabled, applied, or degraded.
  Raw/candidate text stays ephemeral inside the local pipeline unless needed for
  the current invocation; do not add it to persistent history or diagnostics.
- Snapshot engine, model, PCM format, vocabulary, aliases, and correction policy
  at invocation start. Configuration changes apply at a quiescent boundary after
  listening, finalizing, and insertion work finishes. Display pending selection.
  New snippets cannot indefinitely defer a requested engine switch.
- Keep one ordered audio submission path. Avoid one unstructured task per chunk.
  Preserve the 100 ms release grace and never send a later generation's audio
  into the previous generation's finish. Bound retained audio and pending work;
  do not replace bounded buffers with an unbounded `AsyncStream` queue.
- Preserve the existing pending-snippet limit of four. The local runtime may
  finalize one generation while the next records into its bounded buffer, then
  replay that next buffer once the manager is reset. Do not allocate a model copy
  per generation or reset a manager while it is finalizing older audio.
- Expose readiness as preparing, ready, temporarily recovering, or unavailable
  with an actionable reason. While preparation/recovery is underway, existing
  bounded capture policy can apply. Missing assets or unsupported hardware block
  capture with a clear action; download waiting is not a dictation state.
- Keep the existing eight-second finalizing deadline initially, measured from
  release and including local queue delay. A generation that times out cannot
  later insert. Use measured evidence before changing that budget.
- Core owns bounded snippet audio and dictation decisions. A native coordinator
  supplies ordered replay to the selected backend. Only the cloud backend knows
  when reconnect/replay is required; local model failure must not enter a network
  reconnect loop.

### Alternatives considered

1. **Branch throughout AppModel and retain the cloud-shaped reducer.** Smaller
   initial diff, but makes local inference emulate server item IDs, readiness,
   and ACKs. Reject because wire assumptions would spread into every adapter.
2. **A separate dictation state machine per engine.** Isolates providers but
   duplicates cancellation, history, timeout, and insertion policy. Reject because
   those user-visible guarantees should remain shared.
3. **Shared invocation lifecycle, provider-specific runtime.** Recommended. It
   requires a deliberate cloud migration first, but gives both real providers
   the same meaningful contract and leaves their recovery mechanisms private.

## Dictionary and privacy contract

Keep the existing cloud dictionary key and canonical keyword behavior intact.
Add a versioned local vocabulary store with canonical spelling and editable
aliases. It may be seeded once from the existing cloud dictionary, but newly
added local entries must never be exported back implicitly. Do not use a single
unscoped dictionary field for both providers.

Local invocations receive immutable permanent entries plus an optional ephemeral
local-context list. There is no Accessibility collector in this implementation.
Cloud request construction must not accept the local-context type; also test the
serialization boundary with distinctive sentinel terms. Selecting cloud must
never forward local entries, aliases, or captured window text. Existing cloud
keywords remain available through the existing cloud-specific setting.

Port the tested structural alias generation and term-boundary guard to Core as
pure policy, with Unicode-aware boundaries and ambiguity handling. Do not copy
the Python prototype mechanically. Explicit user aliases take precedence;
generated aliases are reproducible and need not be persisted as user edits.

Use similarity 0.80, rescue floors 0.80/0.85, acoustic rescue enabled, and no
short-term taper for the first opt-in policy. These values are string thresholds,
not confidence percentages. Reject isolated insertions/deletions and protected
word consumption unless supported by an explicit alias; preserve surrounding
text and punctuation. Retain raw text for fallback if correction is unavailable
or fails. Surface degraded correction without discarding usable transcription.
With correction disabled, do not create a boosting session or load the auxiliary
CTC model. Merely passing an empty vocabulary retained correction cost in tests.

## Implementation milestones and ownership

### 0. Confirm native packaging and model storage

Owner: one Sol implementor, parent reviews the resulting boundary decisions.

- Verify pinned FluidAudio 0.15.7 builds and bundles under the existing Xcode
  16.0/26.3 CI matrix, not only the Xcode 27 experiment machine. Check required
  resources and binary artifacts in the signed application. Preserve macOS 15
  app support and keep cloud available where the local model is unsupported.
- Use Hubris-owned Application Support storage and explicit paths. The
  [cache-isolation experiment](../../Experiments/LocalSTT/Results/cache-isolation.md)
  verified primary/CTC loading, tokenization, and correction with shared SDK cache
  access and network access denied. Use the public tokenizer, spotter, and
  rescorer APIs; the convenience vocabulary wrapper hardcodes a shared path.
  No SDK fork is required for model paths. Production additionally vendors the
  pinned source to disable sensitive SDK logging. Do not overwrite/delete shared SDK
  caches or change process HOME. OS-managed CoreML/driver caches are outside the
  app's model ownership boundary.
- Implement owned correction orchestration in the adapter. The cache probe used
  complete short utterances; establish bounded long-utterance segmentation and
  token timing behavior before claiming parity with the convenience wrapper.
- Verify actual selected artifact sizes, immutable hashes, model/license metadata,
  and the auxiliary CTC dependency. Do not make users download the multi-GB NeMo
  archive used only by the sherpa experiment.

Exit: verified package/bundle route, runtime eligibility rules, and an explicit
storage ownership decision. No manual downloading of large models in ordinary CI.

### 1. Introduce the contract and migrate cloud behavior

Owner: Sol implementor; parent owns contract review before downstream work.

- Add Core values/events and migrate `DictationSession` to generation-addressed
  preview/final/failure events. Preserve its insertion and user gesture policy.
- Add the native coordinator and OpenAI adapter. Move item-ID/ACK mapping,
  retired-attempt handling, configuration ACKs, and reconnect scheduling into
  the cloud-specific owner. Preserve tombstones after cancellation and timeout.
- Route AppModel, history preparation, and capture finalization through the new
  contract. Keep cloud as the only selectable provider in this milestone.
- Keep tests at the ownership boundary: generic reducer tests use generic events;
  cloud correlation tests retain pre-commit delta, late ACK, rejected commit,
  reconnect replay, buffered stale event, and out-of-order completion cases.

Exit: existing cloud behavior preserved, all checks pass, and the parent accepts
the interface and ownership map. An authorized manual cloud smoke is separate
from automated tests; do not contact the live API merely to run the test suite.

### 2. Implement local runtime and correction policy

After milestone 1, two Sol workers can work in parallel with disjoint ownership:

- **Local runtime worker:** new native adapter files and focused app tests. Load
  verified local files, convert PCM explicitly, stream 16 kHz input, collect raw
  tokens, correct through public APIs with explicit owned paths, finalize, and
  reset/reuse one manager. Prove long-utterance correction boundaries, pending snippet
  handling, cancellation, unload, and no downloads from transcription methods.
- **Dictionary worker:** new Core vocabulary/alias/acceptance files and tests.
  Implement the local store migration and pure correction policy. Do not edit
  shared `DictationSession`, AppModel, or settings views in parallel.

The parent or a subsequent single-owner integration task connects both pieces,
adds selectable local mode for internal testing, and generalizes capture format.
Use direct capture conversion to 16 kHz locally and retain 24 kHz for cloud;
freeze format through release grace and drain conversion output before finish.
Recalculate 90-second buffer limits without changing cloud behavior.

Exit: actual local dictation works without an API key and with network denied;
raw preview, guarded final output, rapid re-press, and stale-result rejection are
verified. Correction-disabled runs avoid CTC loading. Corrections failing still
produce raw final text with a sanitized degraded-status signal.

### 3. Implement the model service and selection state

Owner: Sol implementor. This can overlap milestone 2 after milestone 0 storage
and milestone 1 identity/readiness contracts are settled.

- Add a bundled, pinned catalog for one supported model and its optional CTC
  correction dependency. Separate model identity from backend implementation.
- Expose a testable service for availability, download progress, cancel/retry,
  verification, installation, and removal. Stream downloads and hashes; do not
  hold whole models in memory. Use staging and atomic promotion only after all
  required files validate. An interrupted or corrupt installation is not ready.
- Reuse completed verified artifacts on retry; resuming individual partial files
  is optional. Handle disk-full and failed verification without clobbering the
  last usable installation. Startup reconciles durable files and manifest state.
- Track dependencies shared by the app's own catalog. Unload before deleting
  loaded assets; defer deletion while a generation is using them. Imported or
  SDK-shared assets stay read-only unless ownership is explicitly established.
- Persist selected engine/model separately from installed/readiness state.
  Missing selection stays unavailable with an action; it does not select cloud.

Exit: deterministic filesystem/download-boundary tests cover interruption,
corruption, hash mismatch, retry, disk failure, dependency retention, and deletion
while loaded/in use. One real explicit download/install/offline-load flow passes.

### 4. Build settings and model management UI

Owner: parent. A Sol worker may implement supporting service fixes under explicit
file ownership, but the parent owns interaction design and final UI work.

- Add engine/model selection with local/cloud labels, language/hardware
  availability, and truthful pending/loading/ready/error states.
- Add distinct Load/Unload and Remove actions. Unload releases model memory
  without deleting files or changing selection; do not immediately prewarm it
  again. Explicit Load or the next dictation may reload it with visible readiness
  feedback. Retain the loaded model otherwise while local mode remains selected.
- Show model download size, installed storage, progress, cancel, retry, and remove.
  Make correction's additional asset download explicit when enabling it. Keep
  low-level thresholds and artifact internals out of normal settings.
- Preserve existing cloud credentials/settings; show them only where applicable.
  Local mode requires no key. Hide unsupported prompt/language controls for the
  English-only local model rather than silently ignoring user settings.
- Add the local correction toggle, canonical entries, and alias editing. Explain
  local versus cloud dictionary scope at the point of editing.
- Integrate readiness into the existing overlay/menu without replacing the
  established insertion/recovery interaction. Selection changes and removal must
  not race an active invocation.

Exit: keyboard and VoiceOver labels, layout, downloading/cancel/retry, missing
model, correction dependency, deferred switch, and removal flows are verified.
Manual permission and microphone checks require Jim present.

### 5. Validate the integrated daily-driver path

Owner: parent, with bounded Sol implementation tasks for confirmed defects.

- Run `mise run check` for each material integrated slice and `mise run verify`
  before release-facing handoff. Add discoverable Mise tasks for bounded native
  offline smokes; normal CI uses fakes and small public fixtures, not model pulls
  or Jim's recordings. Validate both existing supported toolchains.
- Test 16/24 kHz conversion with known sample counts, final converter drain,
  duration-based caps, silence, and malformed input. Test begin/append/finish
  ordering across release grace and a rapid next press.
- Test cancellation while loading, streaming, queued, and finalizing; timeout;
  backend switching; terminal event duplication; and stale events reaching the
  insertion queue. Preserve clipboard restoration and focus-at-insertion rules.
- Run installed local dictation under denied network access, including correction
  enabled/disabled and unavailable assets. Verify no local context appears in a
  fake cloud request or diagnostics. Audit SDK logging too: its experimental
  vocabulary logging is unsuitable for sensitive production context.
- With Jim present, test microphone/device changes, sleep/wake, longer speech,
  repeated invocations, rapid presses, final-text insertion, and model removal.
  Use fresh phrases to assess correction precision, not only the tuning corpus.
- Record warm/cold readiness, first-preview and release-to-final latency, sustained
  resource use, and correction regressions. Include leading silence and queue
  delay definitions; avoid treating process RSS as total accelerator memory.

Exit: a working selectable local backend with verified model management and a
written account of remaining manual gaps. Following successful manual dictation
testing, correction defaults to enabled at the user's request. Update README and
affected reference docs to describe final behavior, not this proposed sequence.

## Implementor delegation protocol

For production implementation, spawn fresh workers with:

```text
model = gpt-5.6-sol
reasoning_effort = medium
fork_turns = none
```

Each brief must name the objective, current revision/worktree, approved contract,
owned files, prohibited edits, required observable behavior, and verification.
Explicitly prohibit further native or CLI model delegation. Workers inspect
current source and this plan; do not inherit or paste the full experiment chat.

Use at most three implementors alongside the parent. Parallelism follows actual
independence: local adapter, pure dictionary policy, and model service can proceed
after contracts are settled. `AppModel.swift`, `DictationSession.swift`,
`DictationSettings.swift`, `Package.swift`, `mise.toml`, and settings views have
one writer at a time. The parent allocates ownership before each wave, reviews
diffs and evidence, and integrates sequentially. Workers report blockers rather
than silently changing the contract. The parent owns final judgment and delivery;
implementation delegation does not authorize commits, pushes, or publication.

## Unresolved questions and decision gates

- Milestone 0 model-asset ownership is resolved by the public-API isolation probe.
  Xcode 27 signed packaging and long-input correction now pass locally. The
  Xcode 16.0/26.3 CI also passed on the initial PR candidate.
- Fresh recordings must determine whether this correction policy is suitable for
  default-on use. For this plan the answer is settled as opt-in.
- Jim confirmed that a selected local model stays loaded while the app runs,
  unless explicitly unloaded. Also unload on backend switch/removal. Do not add
  automatic idle eviction. OpenAI remains the default engine.

Automatic Accessibility context and additional engines require their own
subsequent implementation scope. The first local engine is ready for manual
daily-driver validation after the automated checks described above.
