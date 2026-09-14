"""Summarize measured outputs, validating collection and dictionary-reset checks."""
import json
from pathlib import Path
import re
import statistics
import sys

ROOT = Path(__file__).resolve().parent
HUMAN = "--human" in sys.argv
RAW = ROOT / (".build/human/results" if HUMAN else ".build/results")
OUT = RAW if HUMAN else ROOT / "Results"
OUT.mkdir(exist_ok=True)
manifest = json.loads((ROOT / (".build/human/manifest.json" if HUMAN else ".build/audio/manifest.json")).read_text())
fixtures = {(r["voice"], r["id"]): r for r in manifest["recordings"]}
experiments = {
    "fluid-640": 65, "fluid-320": 65, "fluid-paced-640": 4, "fluid-paced-320": 4,
    "sherpa-beam": 52, "sherpa-beam-3": 52, "sherpa-beam-6": 52, "sherpa-greedy": 13,
    "fluid-lifecycle": 0,
}
if HUMAN:
    experiments = {"fluid-640": 90, "fluid-320": 90, "fluid-paced-640": 4,
                   "fluid-paced-320": 4, "sherpa-beam": 72, "sherpa-beam-3": 72,
                   "sherpa-greedy": 18, "fluid-lifecycle": 0}


def exact_term(term, text):
    return re.search(r"(?<!\w)" + re.escape(term) + r"(?!\w)", text) is not None


def words(text):
    # Deliberately retain identifier underscores; ignore case and prose punctuation.
    return re.findall(r"\w+", text.lower())


def distance(a, b):
    previous = list(range(len(b) + 1))
    for index, token in enumerate(a, 1):
        current = [index]
        for other, candidate in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[other] + 1,
                               previous[other - 1] + (token != candidate)))
        previous = current
    return previous[-1]


def median_ms(rows, key):
    return round(statistics.median(r[key] for r in rows) * 1000, 2)


all_rows, summary, checks = [], [], []
for name, expected_count in experiments.items():
    records = [json.loads(line) for line in (RAW / (name + ".jsonl")).read_text().splitlines() if line.strip()]
    rows = [r for r in records if r["kind"] == "result"]
    if len(rows) != expected_count:
        raise AssertionError(f"{name}: expected {expected_count} results, got {len(rows)}")
    keys = [(r["mode"], r["voice"], r["id"]) for r in rows]
    if len(keys) != len(set(keys)):
        raise AssertionError(f"Duplicate result in {name}")
    baseline = {(r["voice"], r["id"]): r["text"] for r in rows if r["mode"] == "none"}
    cleared = [r for r in rows if r["mode"] == "cleared"]
    identical = sum(r["text"] == baseline[(r["voice"], r["id"])] for r in cleared)
    if cleared:
        checks.append(f"{name}: {identical}/{len(cleared)} cleared-dictionary outputs equal the initial baseline.")
    for record in records:
        if record["kind"] == "cancel_reset":
            if record["preview_after_reset"] != "":
                raise AssertionError(f"{name}: reset retained preview text")
        if record["kind"] == "task_cancel":
            checks.append(f'{name}: cancelled task {record["outcome"]}; worker cancellation flag = '
                          f'{record["worker_observed_cancelled"]}.')
        if record["kind"] == "post_task_cancel_reset" and record["preview"] != "":
            raise AssertionError(f"{name}: task cancellation reset retained preview text")
    if name == "fluid-lifecycle":
        for kind in ("task_cancel", "post_task_cancel_reset", "after_cancel"):
            if sum(record["kind"] == kind for record in records) != 1:
                raise AssertionError(f"{name}: missing or duplicate {kind} probe")
    for record in records:
        record["experiment"] = name
        if not record.get("paced", False):
            record.pop("previews", None)
        all_rows.append(record)
    for mode in dict.fromkeys(r["mode"] for r in rows):
        group = [r for r in rows if r["mode"] == mode]
        correct = total = edits = reference_words = 0
        for row in group:
            fixture = fixtures[(row["voice"], row["id"])]
            correct += sum(exact_term(term, row["text"]) for term in fixture["terms"])
            total += len(fixture["terms"])
            reference = words(fixture["expected"])
            edits += distance(reference, words(row["text"]))
            reference_words += len(reference)
        summary.append(dict(experiment=name, mode=mode, recordings=len(group), exact_terms=correct,
                            target_terms=total, normalized_word_edits=edits,
                            reference_words=reference_words,
                            configure_ms=median_ms(group, "configure_seconds"),
                            finish_ms=median_ms(group, "finish_seconds"),
                            total_ms=median_ms(group, "total_seconds"),
                            peak_process_rss_mib=round(max(r["peak_rss_bytes"] for r in group) / 2**20, 1)))

(OUT / "measurements.json").write_text(json.dumps(all_rows, indent=2) + "\n")
(OUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
inventory = RAW / "model-inventory.json"
if inventory.exists():
    (OUT / "model-inventory.json").write_bytes(inventory.read_bytes())
(OUT / "environment.json").write_bytes((RAW / "environment.json").read_bytes())
# Audio hashes and the literal text sent to TTS establish the synthetic corpus.
portable_manifest = json.loads(json.dumps(manifest))
for recording in portable_manifest["recordings"]:
    recording["file"] = Path(recording["file"]).name
(OUT / "audio-manifest.json").write_text(json.dumps(portable_manifest, indent=2) + "\n")
lines = ["# Local STT experiment measurements", "", "Generated by `mise run experiment:stt:report`.", "",
         ("These are three human takes of six scripted phrases, not general speech-recognition accuracy estimates."
          if HUMAN else "These are synthetic-fixture results, not general speech-recognition accuracy estimates."), "",
         "Exact terms are case-sensitive canonical forms, counted once per target entry per recording. "
         "Word edits ignore case and prose punctuation but retain identifier underscores. "
         "No-dictionary and cleared runs are paired within a single loaded runtime.", "",
         "| Experiment | Dictionary | Exact terms | Word edits / reference words | Configure median ms | Finish median ms | Peak process RSS MiB |",
         "|---|---|---:|---:|---:|---:|---:|"]
for row in summary:
    lines.append(f'| {row["experiment"]} | {row["mode"]} | {row["exact_terms"]}/{row["target_terms"]} | '
                 f'{row["normalized_word_edits"]}/{row["reference_words"]} | {row["configure_ms"]} | '
                 f'{row["finish_ms"]} | {row["peak_process_rss_mib"]} |')
lines += ["", "Process RSS excludes some accelerator/driver allocations and is cumulative per process. "
          "FluidAudio streams while sherpa decodes the full utterance, so finish timings are not equivalent workloads.",
          "", "## Lifecycle checks", ""]
lines.extend("- " + check for check in checks)
lines += ["", "## Paced preview timing", "",
          "Audio delivered in 100 ms blocks against a monotonic clock. First preview is timed from audio start, "
          "not detected speech onset. Release-to-final includes any processing backlog after the final sample.", "",
          "| Experiment | Clip | Dictionary | First preview ms | Release-to-final ms |", "|---|---|---|---:|---:|"]
for row in all_rows:
    if row.get("kind") == "result" and row.get("paced"):
        first = row["previews"][0]["wall_seconds"] * 1000 if row["previews"] else None
        first_display = f"{first:.1f}" if first is not None else "n/a"
        lines.append(f'| {row["experiment"]} | {row["id"]} | {row["mode"]} | {first_display} | '
                     f'{row["release_to_final_seconds"] * 1000:.1f} |')
(OUT / "summary.md").write_text("\n".join(lines) + "\n")
print("\n".join(checks))
print(f"Validated {sum(experiments.values())} results; wrote {OUT / 'summary.md'}")
