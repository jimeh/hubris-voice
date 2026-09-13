# Local transcription

Hubris Voice's first on-device engine is FluidAudio 0.15.7 with Parakeet Unified
English, using its 320 ms streaming variant. OpenAI remains the default. The
local option requires Apple Silicon; cloud operation keeps the macOS 15 app
baseline. WhisperKit, sherpa-onnx, Apple Speech, additional model variants, and
Accessibility window-context collection are future work.

## Engine boundary

`TranscriptionEngineRuntime` receives ordered, bounded commands. Every invocation
has a backend epoch, generation, and frozen PCM format. The common reducer owns
push-to-talk, tap-to-lock, cancellation, the four-pending-snippet limit, the
8-second release-to-final deadline, and insertion decisions. Providers emit
complete preview replacements and at most one final result per live invocation.
The coordinator and reducer reject retired events; insertion checks identity
again when its queued work starts.

The OpenAI adapter owns socket attempts, item IDs, commit acknowledgement
correlation, cancelled acknowledgement tombstones, and reconnect/replay.
The local adapter owns a persistent native manager, serial inference, bounded
queued audio, final correction, and reset between invocations. It does not
emulate cloud wire events or reconnect to the network.

Capture converts directly to PCM16 mono, 24 kHz for OpenAI and 16 kHz locally.
Both formats have a 90-second byte cap. The capture mailbox labels chunks at
production time and coalesces main-actor drain notifications. A 100 ms release
grace precedes converter drain and finish. A rapid new press drains and resets
the converter segment without restarting microphone hardware.

Engine and vocabulary edits apply at a quiescent boundary, including queued
insertion. A pending engine change blocks new snippets until it applies. Local
model residency has no idle timer: explicit unload, engine replacement, removal,
and process exit release it. Unload keeps selection and files; Load or the next
press prepares it again. Local configuration edits do not undo manual unload.

## Dictionary and privacy

OpenAI's existing dictionary remains in `transcription.dictionary`.
`LocalVocabularyStore` writes versioned canonical entries and explicit aliases
under a separate key. It seeds from cloud terms once, without reverse migration.
`LocalInvocationContext` separates permanent and ephemeral entries; the cloud
configuration type does not accept either. There is no window-text collector.

Correction is opt-in. The strict policy uses similarity 0.80, acoustic rescue
floors 0.80/0.85, rescue enabled, and no short-term taper. These are matching
parameters, not confidence percentages. Generated identifier aliases and explicit
spoken aliases feed the native rescorer. The pure acceptance guard permits
canonical term substitutions, rejects isolated insertions/deletions and
unsupported protected-word consumption, and preserves surrounding text.
These constraints reduce regressions but cannot guarantee correct substitutions.

Live previews are raw. Only accepted final text enters insertion and history.
Correction failure keeps raw text and reports degraded correction. Disabling
correction avoids loading CTC or creating a rescorer. Public tokenizer, spotter,
and rescorer APIs receive owned model paths; the SDK's convenience vocabulary
wrapper is intentionally unused because it hardcodes shared cache access.
Long correction inputs use bounded segments that keep subword tokens together,
with audio context on either side.

FluidAudio's original logger contains transcript and vocabulary interpolation.
The vendored logger has no output sink in either debug or release builds.
`mise run lint:vendor` verifies the exact upstream snapshot and patch. Hubris
Voice's optional raw development trace is also suppressed while local mode is
selected. Normal diagnostics contain no local vocabulary or transcript text.

## Model storage and attribution

`LocalModelCatalog` pins repository revisions, file sizes, and SHA-256 hashes:

| Asset | Revision | Download bytes |
| --- | --- | ---: |
| Parakeet Unified 320 ms | `4252711f6f060f9a2f91e5f081a806d7f45eebd8` | 608,330,968 |
| Optional CTC correction | `accdafd8cf8a2ff1cabe3c11e54416b405d409aa` | 102,803,869 |

The files are NVIDIA Parakeet models converted to CoreML by FluidInference.
The pinned [Unified model card](https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml/blob/4252711f6f060f9a2f91e5f081a806d7f45eebd8/README.md)
specifies CC BY 4.0. The pinned [CTC model card](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml/blob/accdafd8cf8a2ff1cabe3c11e54416b405d409aa/README.md)
has CC BY 4.0 metadata and an Apache 2.0 statement in its body; the UI links to
the card rather than presenting the conflicting statement as settled.

Downloads and staging files live under
`~/Library/Application Support/Hubris Voice/Models`. Networking uses an ephemeral
session without a persistent URL cache. Files are verified before atomic
installation, and completed verified staging files survive retry. Loaded models
hold leases until native work stops, so removal cannot delete active files.
Removing the primary model does not remove the separately installed correction
asset. Shared FluidAudio/Hugging Face files remain untouched. macOS-owned
CoreML/driver caches are outside this ownership boundary.

## Verification

`mise run check` includes reducer/adapter, dictionary, PCM, store, and privacy
boundary tests using fakes and small data. It does not contact OpenAI or download
speech models. `mise run verify` adds signed release bundle verification.

`mise run smoke:local:install` explicitly downloads the pinned assets into
`~/Library/Application Support/Hubris Voice/Experiments/installation-smoke` and
verifies that the model store can lease them. It reuses verified installations.
`mise run smoke:local:runtime` exercises native raw and corrected long
transcription using the prepared experiment fixtures, with network and shared
SDK cache access denied. It builds the release test runner before applying the
sandbox. `mise run smoke:local:ui` renders the three native local settings panels
to `.build/local-ui` for visual inspection; it does not exercise physical input.

On this M3 Max, the release smoke processed a 20.428-second synthetic recording:

| Correction | Model load | First preview | Stream processing | Finalization |
| --- | ---: | ---: | ---: | ---: |
| Disabled | 0.175 s | 0.136 s | 2.109 s | 0.016 s |
| Strict | 0.320 s | 0.092 s | 2.063 s | 0.378 s |

These are warm filesystem timings with audio fed faster than real time, not
microphone-to-screen latency or cold-start guarantees. Both paths produced text;
the strict candidate contained complete expected dictionary terms. Sentinel
checks found no private test term in application diagnostics.

The final `mise run verify` passed: 138 Core tests and 54 app tests were
collected, with 189 passing and the three opt-in smokes skipped in the default
suite. The download, network-denied runtime, and native rendering smokes also
passed separately. The signed release bundle passed strict deep verification.

This development machine has Xcode 27. Older Xcode 16.0/26.3 CI configurations
remain in the workflow, but have not been executed locally. There has been no
live OpenAI smoke during this implementation.

Jim must verify microphone permissions, physical input/device changes,
sleep/wake, global shortcut timing, and final-text insertion in real applications.
Fresh longer dictation is also needed to evaluate correction precision beyond
the tuning corpus. The 8-second finalization budget includes local queue delay;
very long speech with correction can time out and must never insert later.
