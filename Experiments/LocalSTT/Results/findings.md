# Local STT experiment findings

FluidAudio is the stronger first integration candidate for the specific combination
of live preview and per-invocation vocabulary tested here. Both native engines ran
successfully with network access denied. Dynamic dictionaries worked without
reloading the main model. Neither engine makes arbitrary context terms safe to
apply indiscriminately, and neither guarantees exact spelling.

This is evidence from a small synthetic corpus, not a shipping recommendation or
a general accuracy ranking. We ran 307 transcription conditions using 12 macOS TTS
recordings and one silence recording on an Apple M3 Max with 64 GB RAM. See the
[environment](environment.json), [corpus](audio-manifest.json),
[measurements](summary.md), and [transcripts](measurements.json).

## Dictionary results

Each full-corpus condition contains 28 case-sensitive canonical target entries.
"Mixed" adds 30 plausible distractors, with duplicates removed. Word edits measure
all transcript words, including surrounding prose, ignoring case and punctuation.

| Configuration | No dictionary | Relevant terms | Mixed terms | Word edits with relevant / mixed terms |
|---|---:|---:|---:|---:|
| FluidAudio 640 ms | 7/28 | 26/28 | 25/28 | 4 / 11 |
| FluidAudio 320 ms | 8/28 | 27/28 | 27/28 | 9 / 12 |
| sherpa beam, score 1.5 | 16/28 | 19/28 | 19/28 | 15 / 15 |
| sherpa beam, score 3 | 16/28 | 22/28 | 20/28 | 12 / 44 |

FluidAudio correctly rendered `URLSession`, `user_id`, and `DictationSession` in
the identifier fixture with relevant terms. But adding unrelated terms changed
"then reset the DictationSession" to "then Rust the DictationSession", and
"We ran the job today" to "We CRAN the job today". The 640 ms configuration also
produced `MacOS` instead of `macOS` and dropped "on" in the brands fixture.
Additional spoken aliases did not improve exact-term recovery in this corpus,
although they reduced surrounding-word errors in the 320 ms condition.

sherpa improved with stronger hotword weighting, but score 3 also increased errors
with distractors. Score 6 was unusable: relevant terms recovered 26/28 targets while
producing 1,007 word edits against 228 reference words, largely repeated dictionary
terms. Target recall alone would conceal that failure.

The engine paths differ: FluidAudio uses streaming Unified plus CTC correction;
sherpa uses full-utterance Unified with beam decoding on CPU. This experiment does
not isolate runtime quality using equivalent exports or decoding algorithms.
sherpa's genuine Unified streaming path exists in the pinned release, but its
greedy-only path was not exercised here. Streaming plus hotwords remains an
unresolved sherpa integration question.

## Responsiveness and lifecycle

In eight paced FluidAudio runs, first text arrived 0.83–1.03 seconds after audio
start with the 320 ms configuration, and 1.24–1.25 seconds with 640 ms. Final output
arrived 215–257 ms after the scheduled end of audio. These are individual warm
measurements using two synthetic clips, not percentile estimates or microphone
latency measurements. The configuration names are not promises of first-word latency.

Replacing FluidAudio vocabulary took about 6 ms with relevant terms and 11 ms
with distractors. sherpa stream creation with hotwords took about 0.05–0.13 ms.
Both reused the loaded main model across invocations.

Clearing terms reproduced all 13 original baseline transcripts in every paired
configuration. In FluidAudio, however, the median finish cost remained about
169–174 ms after clearing, versus 16–18 ms before vocabulary was ever configured.
Empty vocabulary and disabling vocabulary processing have different observed costs.

Resetting partial FluidAudio input cleared the preview and allowed a fresh
transcription. Cancelling a Swift task around `finish()` threw `CancellationError()`
in approximately 2.7 ms; its subsequent reset also cleared the preview. The probe
signals worker entry, not entry into a native prediction, so it does not establish
immediate interruption of in-flight CoreML computation. sherpa's probe only
destroys an undecoded partial stream, not an actively decoding stream.

Model loading used installed local artifacts and potentially warm OS/CoreML caches.
The original raw load event has a generic download-related note; measurements were
actually network-denied local loads. The runner's note has since been clarified.
Process RSS is not total model memory, because driver and accelerator allocations
can be outside the process. These runs do not establish cold-start cost, energy
use, or performance under sustained application load.

## Implications for Hubris Voice

1. Pass an immutable vocabulary snapshot with each invocation. Keep permanent user
   terms and transient window terms distinguishable so their selection and weighting
   can evolve. Do not require main-model reloads when the vocabulary changes.
2. Expose the difference between recognition hints and guaranteed text replacement.
   These experiments support hints; exact canonical output remains best effort.
3. Allow previews to be revised and a corrected final transcript to arrive after
   audio stops. Do not assume each callback only appends text.
4. Represent disabling dictionary processing separately from an empty term list,
   subject to verifying how each adapter can implement that distinction.
5. Tag invocations so Hubris Voice can discard stale results after cancellation.
   Native cancellation behavior alone is insufficient for insertion safety.
6. Keep captured window terms local, ephemeral, and out of transcript diagnostics.
   The experiment logs contain all supplied terms for analysis; that is unsuitable
   for a production path carrying sensitive Accessibility context.

Before app integration, run a small natural-speech corpus using Jim's normal
pronunciation and microphone. Include technical prose, identifiers, project names,
ordinary sentences with distracting context, and longer speech with pauses.
Start with a manually supplied context list. Automatic Accessibility extraction
would introduce another variable before we know whether dictionary selection is
reliable. The current evidence favors evaluating FluidAudio first while retaining
sherpa's harness as a useful comparison.

## Verification

Both standalone Swift executables built successfully. The report validated all
307 transcription rows, rejected duplicate recording/condition keys, and checked
the cancellation/reset records. The repository's `mise run check` passed. No
production Swift source or application dependency was changed. Microphone input,
Accessibility capture, native permission prompts, and application insertion were
not tested by this standalone experiment.
