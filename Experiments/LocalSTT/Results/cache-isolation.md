# Model and tokenizer cache isolation

The pinned FluidAudio 0.15.7 public APIs can load the required transcription and
dictionary assets entirely from Hubris-owned directories. No SDK patch or fork
was needed for the tested path. The convenience vocabulary wrapper cannot do so
as currently implemented; Hubris must coordinate the lower-level correction APIs.

## Experiment

We copied 31 pinned, SHA-256-verified files (711,134,837 bytes) into a fresh
`~/Library/Application Support/Hubris Voice/Experiments/cache-isolation-<id>/`
directory, with `primary/` and `ctc/` subdirectories. These are independent files,
not links back to the shared cache. The primary copy includes only the 320 ms
encoder plus its decoder, joint model, vocabulary, and metadata. No new model
downloads were required.

Each process had network access denied and all reads/writes under
`~/Library/Application Support/FluidAudio/` denied. A second profile additionally
denied process file writes outside the owned root. Its temporary directory was
inside that root; HOME was not changed. Executable code, input recordings, and
OS libraries remained readable. Harness output was captured through inherited
stdout/stderr descriptors in the experiment results directory.

Independent controls confirmed that an owned tokenizer read and owned write
succeeded, a shared tokenizer read failed with PermissionError, and an unrelated
write outside the root failed with PermissionError.

| Path | Result |
|---|---|
| Built-in vocabulary wrapper, shared cache blocked | Models loaded; vocabulary configuration failed at its shared tokenizer lookup, as expected |
| Public correction APIs, shared cache blocked | Five clips completed with raw previews and corrected final text |
| Public correction APIs, writes restricted to owned root | All five clips completed again, with identical raw and corrected text |

The five clips cover three identifier takes, including the explicit "underscore"
pronunciation, plus technical and product-name phrases. This exercises dictionary
correction as well as plain ASR. The 15 canonical target entries were present in
both successful runs; this is a functionality check, not a new accuracy estimate.
Existing recognition errors outside those terms remain.

Content hashes confirmed that the existing shared cache and all copied model
assets were unchanged. The only additional file observed inside the owned root
was the control test's `runtime/write-control` file.

## Public API route

The probe uses these APIs with explicit owned paths:

1. `StreamingUnifiedAsrManager.loadModels(from:)` for the primary models.
2. `CtcModels.loadDirect(from:)` for CTC models and vocabulary.
3. `CtcTokenizer.load(from:)` to tokenize the per-invocation terms.
4. `CtcKeywordSpotter` using those already-loaded CTC models.
5. `VocabularyRescorer.create(..., ctcModelDirectory:)` with the owned tokenizer
   directory, followed by `ctcTokenRescore(...)`.

The high-level `configureVocabularyBoosting` method constructs a
`VocabularyBoostingSession`, whose initializer unconditionally obtains
`CtcModels.defaultCacheDirectory(for:)`. Loading the CTC models from another URL
does not override that lookup.

The proof is implemented in [CacheIsolationProbe](../Sources/CacheIsolationProbe/main.swift).
The relevant pinned SDK sources are
`ASR/Parakeet/Unified/StreamingUnifiedAsrManager.swift`,
`SlidingWindow/CustomVocabulary/VocabularyBoostingSession.swift`,
`WordSpotting/CtcModels.swift`, `WordSpotting/CtcTokenizer.swift`, and
`Rescorer/VocabularyRescorer.swift`, under the experiment's FluidAudio checkout.

## What this settles

Hubris can own, validate, and remove its model/tokenizer assets independently of
the FluidAudio shared cache. Prefer explicit paths and a Hubris-owned correction
coordinator, with no implicit model download or shared-cache fallback during
dictation. This resolves the model-asset ownership question in milestone zero.

It does not mean macOS itself never uses files elsewhere. CoreML, the Neural
Engine, GPU drivers, system logs, and helper processes may have OS-managed caches.
Those are distinct from app-managed downloadable assets. The strict-write run
followed model loading in the other processes and can benefit from OS caches;
we did not purge system caches or establish cold-machine hermetic execution.

The public pipeline in this probe corrects complete short utterances, rather than
reproducing the convenience wrapper's roughly 15-second segmented rescoring.
Long-utterance chunking, timing boundaries, bounded memory, and correction quality
must therefore be verified when implementing the production coordinator. The
existing Xcode compatibility and signed-bundle checks are also still open; this
experiment does not complete every part of milestone zero.

## Reproduce

With the existing verified models and human correction manifest available:

```sh
mise run experiment:stt:cache:prepare
mise run experiment:stt:build
mise run experiment:stt:cache:run
mise run experiment:stt:cache:verify
```

Preparation creates a dedicated copy once and refuses to overwrite a previous
fixture. To repeat measurements against it, run only the final two tasks.
The owned root pointer, asset inventory, sandbox profiles, structured results,
and integrity snapshots are in ignored `.build/cache-isolation/`. The owned
experiment directory is retained for inspection; shared assets are never moved
or deleted. No production app source or dependency was changed.
