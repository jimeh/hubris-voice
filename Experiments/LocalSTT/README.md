# Local speech-to-text experiments

Standalone experiments for deciding Hubris Voice's transcription boundary. The
application package and its production dependencies are unchanged. Both runners
are native Swift executables; sherpa uses its C API in process. Python's standard
library only generates fixtures, downloads assets, launches processes, and scores
results. There is no Python inference service.

The completed run and its implications are in [Findings](Results/findings.md).
The model-directory ownership probe is documented in
[Cache isolation](Results/cache-isolation.md).

## Run

From the repository root, on an Apple Silicon Mac:

```sh
mise run experiment:stt:setup
mise run experiment:stt:audio
mise run experiment:stt:build
mise run experiment:stt:run
mise run experiment:stt:report
```

Setup downloads several GB, including NVIDIA's original archive solely to recover
the matching SentencePiece vocabulary. Native archives and audio stay under this
experiment's ignored `.build/`. FluidAudio models use its normal
`~/Library/Application Support/FluidAudio/Models/` cache because the vocabulary
initializer resolves its tokenizer there. Setup refuses to overwrite a cached
file that differs from the pinned revision. It validates native archive SHA-256s,
CoreML artifact hashes against immutable Hugging Face revisions, and the NVIDIA
tokenizer's symbol order against sherpa's token IDs.

The build resolves FluidAudio 0.15.7 with its committed `Package.resolved`.
sherpa-onnx's library and header are pinned to 1.13.8. No global tools are installed.
Build and setup require network access. Measurement runs use macOS `sandbox-exec`
to deny network access; they fail rather than retrying online. The Fluid runner
loads local model paths during measurements.

The tasks are deliberately separate: running a benchmark does not implicitly
regenerate audio, change installed models, or rebuild. Run them in the order above
when starting fresh. After editing Swift, rebuild before measuring. Experiments
run serially to avoid competing inference workloads.

## Corpus and conditions

### Record natural speech

```sh
mise run experiment:stt:record
```

This builds and opens the standalone, development-signed **STT Phrase Recorder**.
Enable its microphone access, hold the button while reading the displayed phrase,
then release. Listen or redo as needed, and click **Keep and next** to save each
take. Read naturally without speaking punctuation, capitals, or underscores. The
six existing phrases each get three takes, for 18 accepted recordings. The final
button is **Keep and run tests**. Closing and reopening resumes accepted progress.

The app records the default macOS microphone directly to mono PCM16 WAV at 16 kHz.
It stops on release, loss of application focus, or after 120 seconds. A pending
take is never included in the test manifest. The save/resume self-test runs when
building the recorder; microphone permission and real capture need the user.

An isolated background watcher starts the comparison after all 18 takes are saved.
It runs 350 transcription conditions, omitting the already-unusable hotword score
6. Paced tests use the first identifier and long-passage takes. Before inference,
the runner validates take identity, hashes, format, and duration. Engine processes
have network access denied. No server or upload is involved.

Audio, manifests, transcripts, and the human report stay in ignored
`.build/human/`, outside the tracked synthetic results. Status is in
`.build/human/benchmark.log`; the report is `.build/human/results/summary.md`.
After interruption, reopen the recorder to restart the watcher, or explicitly rerun
the comparison with `mise run experiment:stt:human`. Keep only complete readings:
the initial reference text is the displayed script and still needs human review
if the actual spoken words differ. Three takes test consistency, not broad accent
or microphone coverage.

### Synthetic corpus

`fixtures.json` supplies six utterances in macOS's Daniel and Samantha voices at
165 words/minute, plus one three-second silence fixture. All WAVs are mono PCM16
at 16 kHz. Expected transcripts distinguish canonical identifiers from the text
spoken to TTS, such as `user_id` versus "user I D". All terms are public or
invented; no microphone, Accessibility data, or private source text is captured.

### Correction controls

After the human comparison, run the isolated correction experiment:

```sh
mise run experiment:stt:correction:prepare
mise run experiment:stt:build
mise run experiment:stt:correction:run
mise run experiment:stt:correction:report
```

This preserves the original manifest and results. It replays all 18 human takes
through five 640 ms profiles, with four dictionary conditions per profile, for
360 native transcription rows. Every profile uses the same existing aliases plus
structural camel-case, acronym, and underscore pronunciations. The conditions are
no dictionary, only relevant terms, relevant terms plus the existing distractors,
and the combined list with terms shorter than six letters/digits removed. The
last filter applies to every term, including relevant terms; it has no oracle
that selectively keeps only the words present in the script.

| Profile | Minimum similarity | Short-term taper pivot | Rescue similarity floors | Acoustic rescue |
|---|---:|---:|---|---|
| default | 0.52 | 1 (disabled) | 0.30 / 0.50 | enabled |
| no-rescue | 0.52 | 1 (disabled) | 0.30 / 0.50 | disabled |
| taper | 0.52 | 5 | 0.30 / 0.50 | enabled |
| strict | 0.80 | 1 (disabled) | 0.80 / 0.85 | enabled |
| conservative | 0.80 | 5 | 0.80 / 0.85 | disabled |

The taper exponent is 2. These are public configuration controls in the pinned
FluidAudio source. Unified's default already applies rescue floors of 0.30/0.50;
it does not use the unrestricted rescorer defaults. Its wrapper internally passes
a size-aware boost of 4.5 and alignment margin of 0.5 seconds; this experiment
does not patch those internals. Ambient `FLUID_*` overrides are removed from the
measurement process environment.

The report separately evaluates exact multiword alias replacement on the raw
baseline, without CTC correction or fuzzy matching. It rejects ambiguous aliases,
requires word boundaries, and leaves unmatched text unchanged. Focused checks
cover those boundaries and the ordinary-word substitutions we want to prevent.

Outputs and per-recording change audits stay in ignored `.build/human/correction/`.
Word-edit comparisons use the displayed script, not a human-verified verbatim
transcript. Excess dictionary mentions and worse-clip counts complement term
recall; they are automated warning metrics, not complete false-positive labels.
This is tuning on the existing sample, not validation on held-out recordings.

For a selected profile on another streaming configuration, the runner also accepts
an explicit tier and profile list, for example:

```sh
mise exec -- /usr/bin/python3 Experiments/LocalSTT/correction_sweep.py run 320 sweep-default sweep-strict
mise run experiment:stt:correction:report
```

The completed follow-up selected `sweep-strict` for the 320 ms confirmation.
The report also applies a term-boundary guard to strict output: it accepts isolated
canonical substitutions, rejects standalone insertions/deletions, and rejects
replacement spans consuming common function words unless an explicit alias
supports them. It preserves other raw text and trailing punctuation. This is not
an acoustic correctness guarantee. It operates on completed text in the harness;
live preview acceptance has not been integrated into Hubris Voice.

After the 320 ms strict run and a current build, verify that raw text can be
collected without a second ASR pass:

```sh
mise run experiment:stt:correction:probe
mise run experiment:stt:correction:report
```

This adds 72 runs using `consumeTokenTimings()` alongside corrected transcription.
It asserts that concatenated raw tokens reproduce the separate uncorrected
baseline and that draining the timing buffer leaves corrected text unchanged.

Conditions:

- `none`: no dictionary, before any vocabulary-bearing invocation.
- `relevant`: only that fixture's canonical target terms.
- `mixed`: relevant terms plus 30 plausible distractors, deduplicated.
- `aliases`: FluidAudio-only experiment adding the supplied spoken aliases.
- `cleared`: an explicitly empty dictionary after preceding vocabulary runs.

FluidAudio uses Unified INT8 streaming with 640 ms (`70_7_1`) and 320 ms
(`70_2_2`) contexts, plus its CTC 110M keyword model. The default vocabulary
configuration is used. The same manager and models are retained through each
process; only snippet state and vocabulary are replaced.

sherpa uses Unified INT8 **offline** inference, ONNX Runtime's CPU provider with
four threads, beam width four, and hotword scores 1.5, 3, and 6. Each request has a
fresh stream under the same loaded recognizer. A separate greedy baseline helps
distinguish beam-search changes from dictionary effects. Neither aliases nor an
extra spelling-replacement pass are added to sherpa.

These paths have different audio context and decoding algorithms. Their baseline
accuracy and finish times are not a controlled comparison of equivalent model
exports. The useful comparisons are dictionary-on versus dictionary-off within
each path, and the resulting product behavior.

## Measurements and evidence

- [Generated summary](Results/summary.md): term recovery, word edits, timing, and
  dictionary-clear checks.
- [Measurements](Results/measurements.json): all transcripts, per-invocation
  timings, lifecycle events, and paced preview revisions.
- [Audio manifest](Results/audio-manifest.json): spoken text, reference text,
  vocabulary, WAV duration, and hashes.
- [Model inventory](Results/model-inventory.json): selected CoreML files and
  immutable revisions. Native asset URLs and hashes are in `workflow.py`.
- Full unpaced preview traces and stderr remain in `.build/results/`.

The report validates result counts and rejects duplicate recording/condition
pairs. Exact-term recovery requires the canonical case-sensitive form at word
boundaries; it counts target entries, not repeated occurrences. Word edit counts
ignore case and prose punctuation but preserve underscores. They therefore catch
missing neighboring words that term recall alone would hide. They are not
presented as general-purpose model accuracy estimates.

Paced runs replay Daniel's identifier and longer utterances in 100 ms audio
blocks. First-preview latency starts at the beginning of the WAV, not detected
speech onset. Release-to-final includes any outstanding processing after the last
sample's scheduled delivery. Unpaced timings measure accelerated computation and
have no release-to-final latency. Model-load timings are new-process loads after
setup, with OS/CoreML caches potentially warm; they are not first-install cold
starts. Peak process RSS is cumulative and excludes some accelerator/driver
allocations, so it is not total model memory.

The Fluid lifecycle probe resets after partial audio, starts a new snippet, and
separately cancels a Swift task around `finish()`. Its signal establishes worker
entry, not entry into a particular native CoreML instruction. sherpa's probe
destroys an undecoded partial stream; it does not demonstrate interruption of
its synchronous native decode. Neither test simulates an application insertion
queue or proves that ignoring stale results has been implemented in Hubris Voice.

## Limits and next recordings

Synthetic speech is useful for repeatable plumbing and vocabulary stress tests.
The TTS pronunciations have not been independently validated by a human. These
voices are not a proxy for Jim's accent, microphone, hesitations, background noise,
or preferred pronunciation of identifiers. Do not tune defaults or choose a
shipping engine solely from this corpus.

The next useful input is a small set of natural recordings: technical prose,
identifiers, project names, ordinary prose without target terms, and a longer
dictation with pauses. Their expected text should be transcribed independently of
engine output. A custom manifest with the same fields can be passed directly to
either runner after converting audio to mono 16 kHz WAV. Raw logs and transcripts
may include every supplied term; keep personal recordings out of committed results.

## Source references

- [FluidAudio 0.15.7](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.7)
- [Unified vocabulary implementation](https://github.com/FluidInference/FluidAudio/pull/862)
- [Programmatic vocabulary fix](https://github.com/FluidInference/FluidAudio/pull/898)
- [sherpa 1.13.8](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.8)
- [Offline NeMo recognizer](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/sherpa-onnx/csrc/offline-recognizer-transducer-nemo-impl.h)
- [Unified streaming recognizer](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/sherpa-onnx/csrc/online-recognizer-transducer-nemo-parakeet-unified-impl.h)

The current sherpa release does have genuine Unified streaming exports. Its
streaming decoder supports greedy search; this experiment uses the offline path
to exercise hotwords. Earlier discussion that sherpa had no real Unified
streaming support was incomplete.
