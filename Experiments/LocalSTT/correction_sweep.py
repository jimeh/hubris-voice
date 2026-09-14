"""Controlled local correction sweep; human artifacts stay in ignored .build/."""
import collections
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
OUT = ROOT / ".build/human/correction"
PROFILES = ["sweep-default", "sweep-no-rescue", "sweep-taper", "sweep-strict", "sweep-conservative"]


def generated_aliases(term):
    """Generate structural spoken forms, without guessing phonetic substitutions."""
    split = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", term)
    split = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", split)
    forms = {split.replace("_", " "), split.replace("_", " underscore ")}
    for form in list(forms):
        forms.add(re.sub(r"\b[A-Z]{2,}\b", lambda m: " ".join(m[0]), form))
    return sorted({" ".join(f.split()) for f in forms if len(f.split()) >= 2})


def exact_alias(text, terms, aliases):
    """Only replace complete multiword aliases; reject ambiguous alias mappings."""
    mappings = collections.defaultdict(set)
    for term in terms:
        for alias in aliases.get(term, []):
            if len(alias.split()) >= 2:
                mappings[" ".join(alias.lower().split())].add(term)
    options = {a: next(iter(ts)) for a, ts in mappings.items() if len(ts) == 1}
    if not options:
        return text, []
    patterns = [r"\s+".join(re.escape(word) for word in a.split())
                for a in sorted(options, key=len, reverse=True)]
    pattern = re.compile(r"(?<!\w)(?:" + "|".join(patterns) + r")(?!\w)", re.IGNORECASE)
    changes = []

    def replace(match):
        target = options[" ".join(match[0].lower().split())]
        if match[0] != target:
            changes.append(dict(original=match[0], replacement=target, start=match.start(), end=match.end()))
        return target

    return pattern.sub(replace, text), changes


def term_guard(original, corrected, terms, aliases):
    """Accept isolated canonical substitutions, preserving unrelated raw text.

    This is a text boundary guard, not acoustic confidence. It cannot prove that
    a plausible canonical replacement is correct; strict native matching remains
    responsible for candidate quality.
    """
    before = list(re.finditer(r"\S+", original))
    after = list(re.finditer(r"\S+", corrected))
    protected = set("a an the and or but if then than to of on in at by for from with as is are was were be been being it this that these those we you i he she they my your our their".split())
    terms = [" ".join(term.split()) for term in terms]

    def is_boundary(character):
        return not character.isalnum() and character != "_"

    def canonical_term(candidate):
        candidate = " ".join(candidate.split())
        for term in terms:
            start = candidate.find(term)
            if start < 0:
                continue
            prefix = candidate[:start]
            suffix = candidate[start + len(term):]
            if all(map(is_boundary, prefix)) and all(map(is_boundary, suffix)):
                return term
        return None

    def boundary_prefix(text):
        for index, character in enumerate(text):
            if not is_boundary(character):
                return text[:index]
        return text

    def boundary_suffix(text):
        return boundary_prefix(text[::-1])[::-1]

    changes = []
    edits = []
    for tag, a, b, c, d in difflib.SequenceMatcher(
            a=[m[0] for m in before], b=[m[0] for m in after], autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        raw = " ".join(m[0] for m in before[a:b])
        proposed = " ".join(m[0] for m in after[c:d])
        canonical = canonical_term(proposed)
        reason = "not an isolated canonical substitution"
        accepted = False
        if tag == "replace" and canonical is not None:
            normalized = " ".join(words(raw))
            known = {" ".join(words(alias)) for alias in aliases.get(canonical, [])}
            if not (set(words(raw)) & protected) or normalized in known:
                accepted = True
                reason = "canonical substitution with preserved boundaries"
                # Native correction often drops punctuation. Retain both raw
                # boundaries without duplicating punctuation in terms like .NET
                # and C++.
                prefix = boundary_prefix(before[a][0])
                suffix = boundary_suffix(before[b - 1][0])
                canonical_prefix = boundary_prefix(canonical)
                canonical_suffix = boundary_suffix(canonical)
                if canonical_prefix and prefix.endswith(canonical_prefix):
                    prefix = prefix[:-len(canonical_prefix)]
                if canonical_suffix and suffix.startswith(canonical_suffix):
                    suffix = suffix[len(canonical_suffix):]
                edits.append((before[a].start(), before[b - 1].end(), prefix + canonical + suffix))
            else:
                reason = "would consume a protected word without an explicit alias"
        changes.append(dict(before=raw, after=proposed, accepted=accepted, reason=reason))
    text = original
    for start, end, replacement in reversed(edits):
        text = text[:start] + replacement + text[end:]
    return text, changes


def checks():
    aliases = {"user_id": generated_aliases("user_id"), "URLSession": generated_aliases("URLSession")}
    terms = list(aliases)
    assert exact_alias("Use user underscore ID, then URL session.", terms, aliases)[0] == "Use user_id, then URLSession."
    assert exact_alias("myuser ID and user IDs", terms, aliases)[0] == "myuser ID and user IDs"
    assert exact_alias("Reset this. We ran with a warm bun.", ["Rust", "CRAN", "Bun"], {})[0] == "Reset this. We ran with a warm bun."
    assert exact_alias("user ID", ["user_id", "userID"], {"user_id": ["user ID"], "userID": ["user ID"]})[0] == "user ID"
    assert exact_alias("user_id", terms, aliases)[0] == "user_id"
    assert term_guard("Open this on macOS with Tensor RT.", "Open this macOS with TensorRT", ["TensorRT"], {})[0] == "Open this on macOS with TensorRT."
    assert term_guard("ask the Quaxal", "ask Quexal", ["Quexal"], {})[0] == "ask the Quaxal"
    assert term_guard("user underscore ID, please", "user_id please", ["user_id"], aliases)[0] == "user_id, please"
    assert term_guard("Use (.net).", "Use (.NET).", [".NET"], {})[0] == "Use (.NET)."
    assert term_guard("Use (c plus plus).", "Use (C++).", ["C++"], {})[0] == "Use (C++)."
    assert term_guard("say hello", "say Kubernetes hello", ["Kubernetes"], {})[0] == "say hello"
    print("PASS: structural aliases, exact boundaries, ambiguity rejection, canonical stability, deletion/insertion rejection, protected words, punctuation")


def prepare():
    checks()
    OUT.mkdir(parents=True, exist_ok=True)
    source = ROOT / ".build/human/manifest.json"
    manifest = json.loads(source.read_text())
    if len(manifest["recordings"]) != 18:
        raise AssertionError("Expected 18 original human recordings")
    terms = set(manifest["distractors"])
    aliases = collections.defaultdict(set)
    for recording in manifest["recordings"]:
        if hashlib.sha256(Path(recording["file"]).read_bytes()).hexdigest() != recording["sha256"]:
            raise AssertionError("Audio differs from accepted recording")
        terms.update(recording["terms"])
        for term, forms in recording["aliases"].items():
            aliases[term].update(forms)
    for term in terms:
        aliases[term].update(generated_aliases(term))
    for recording in manifest["recordings"]:
        recording["aliases"] = {term: sorted(forms) for term, forms in sorted(aliases.items())}
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    plan = dict(source_manifest_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                profiles=PROFILES, modes=["none", "relevant", "mixed", "filtered"],
                tier_ms=640, minimum_filtered_alphanumeric_length=6,
                alias_policy="Existing aliases plus structural camel-case, acronym, and underscore forms",
                evaluation="Same 18 recordings; exploratory tuning, no held-out quality claim")
    (OUT / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    print("Prepared isolated correction manifest; original human corpus unchanged")


def run(tier=640, profiles=PROFILES):
    workflow = runpy.run_path(str(ROOT / "workflow.py"))
    env = {k: v for k, v in os.environ.items() if not k.startswith("FLUID_")}
    for profile in profiles:
        if profile not in PROFILES:
            raise ValueError(profile)
        name = f"{tier}-{profile}"
        print(f"Running {name}, network denied", flush=True)
        with (OUT / f"{name}.jsonl").open("w") as output, (OUT / f"{name}.log").open("w") as errors:
            subprocess.run(["sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
                            str(workflow["FLUID"]), "run", str(OUT / "manifest.json"), str(tier), profile],
                           env=env, cwd=ROOT, stdout=output, stderr=errors, check=True)
    (OUT / "environment.json").write_text(json.dumps(workflow["capture_environment"]("Same 18 human takes; correction sweep"), indent=2) + "\n")


def probe():
    workflow = runpy.run_path(str(ROOT / "workflow.py"))
    output = OUT / "single-pass.jsonl"
    with output.open("w") as out, (OUT / "single-pass.log").open("w") as err:
        subprocess.run(["sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
                        str(workflow["FLUID"]), "run", str(OUT / "manifest.json"),
                        "320", "sweep-strict", "capture-raw"], cwd=ROOT, stdout=out, stderr=err,
                       env={k: v for k, v in os.environ.items() if not k.startswith("FLUID_")}, check=True)
    previous = [json.loads(l) for l in (OUT / "320-sweep-strict.jsonl").read_text().splitlines()]
    baseline = {(r["voice"], r["id"]): r["text"] for r in previous if r.get("mode") == "none"}
    corrected = {(r["mode"], r["voice"], r["id"]): r["text"] for r in previous if r.get("kind") == "result"}
    rows = [json.loads(l) for l in output.read_text().splitlines()]
    rows = [r for r in rows if r["kind"] == "result"]
    assert len(rows) == len(corrected) == 72
    assert {(r["mode"], r["voice"], r["id"]) for r in rows} == set(corrected)
    for r in rows:
        assert r["raw_token_text"] == baseline[(r["voice"], r["id"])], f"Raw token mismatch: {r['id']} {r['voice']}"
        assert r["text"] == corrected[(r["mode"], r["voice"], r["id"])], "Draining raw tokens changed corrected output"
    evidence = dict(rows=72, raw_matches=72, corrected_matches=72,
                    jsonl_sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
                    source_sha256=hashlib.sha256((ROOT / "Sources/LocalSTTExperiment/main.swift").read_bytes()).hexdigest(),
                    binary_sha256=hashlib.sha256(workflow["FLUID"].read_bytes()).hexdigest(),
                    package_resolved_sha256=hashlib.sha256((ROOT / "Package.resolved").read_bytes()).hexdigest())
    (OUT / "single-pass-check.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print("PASS: 72 single-pass raw transcripts match separate baselines; all corrected outputs unchanged")


def words(text):
    return re.findall(r"\w+", text.lower())


def distance(a, b):
    previous = list(range(len(b) + 1))
    for i, left in enumerate(a, 1):
        current = [i]
        for j, right in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (left != right)))
        previous = current
    return previous[-1]


def occurrences(term, text):
    return len(re.findall(r"(?<!\w)" + re.escape(term) + r"(?!\w)", text))


def report():
    manifest = json.loads((OUT / "manifest.json").read_text())
    fixtures = {(r["voice"], r["id"]): r for r in manifest["recordings"]}
    vocabulary = sorted(set(manifest["distractors"]) | {t for r in fixtures.values() for t in r["terms"]})
    summary, audit = [], []
    baselines = {}
    required = {f"640-{profile}.jsonl" for profile in PROFILES}
    assert required <= {p.name for p in OUT.glob("*-sweep-*.jsonl")}, "Missing primary sweep profiles"
    for file in sorted(OUT.glob("*-sweep-*.jsonl")):
        records = [json.loads(line) for line in file.read_text().splitlines()]
        rows = [r for r in records if r["kind"] == "result"]
        keys = {(r["mode"], r["voice"], r["id"]) for r in rows}
        expected_keys = {(mode, voice, ident) for mode in ["none", "relevant", "mixed", "filtered"] for voice, ident in fixtures}
        assert len(rows) == 72 and keys == expected_keys, f"Incomplete or duplicate results: {file}"
        assert all(f'{r["tier_ms"]}-{r["correction_profile"]}' == file.stem for r in rows), "Profile metadata mismatch"
        baseline = {(r["voice"], r["id"]): r["text"] for r in rows if r["mode"] == "none"}
        tier = file.stem.split("-")[0]
        if tier in baselines:
            assert baseline == baselines[tier], "Uncorrected output drifted between profiles"
        else:
            baselines[tier] = baseline
        groups = [(mode, [r for r in rows if r["mode"] == mode]) for mode in ["none", "relevant", "mixed", "filtered"]]
        if file.stem.endswith("sweep-strict"):
            for mode in ["relevant", "mixed", "filtered"]:
                transformed = []
                for r in rows:
                    if r["mode"] != mode:
                        continue
                    fixture = fixtures[(r["voice"], r["id"])]
                    text, decisions = term_guard(baseline[(r["voice"], r["id"])], r["text"], r["terms"], fixture["aliases"])
                    transformed.append(dict(r, text=text, guard_decisions=decisions))
                groups.append(("guarded-" + mode, transformed))
        if file.stem.endswith("sweep-default"):
            for mode in ["relevant", "mixed", "filtered"]:
                transformed = []
                for r in rows:
                    if r["mode"] != mode:
                        continue
                    fixture = fixtures[(r["voice"], r["id"])]
                    text, changes = exact_alias(baseline[(r["voice"], r["id"])], r["terms"], fixture["aliases"])
                    transformed.append(dict(r, text=text, alias_changes=changes))
                groups.append(("exact-alias-" + mode, transformed))
        for mode, group in groups:
            hits = targets = edits = worse = excess = introduced_excess = 0
            for row in group:
                fixture = fixtures[(row["voice"], row["id"])]
                original = baseline[(row["voice"], row["id"])]
                hits += sum(occurrences(t, row["text"]) > 0 for t in fixture["terms"])
                targets += len(fixture["terms"])
                error = distance(words(fixture["expected"]), words(row["text"]))
                base_error = distance(words(fixture["expected"]), words(original))
                edits += error
                worse += error > base_error
                row_excess = sum(max(0, occurrences(t, row["text"]) - occurrences(t, fixture["expected"])) for t in vocabulary)
                base_excess = sum(max(0, occurrences(t, original) - occurrences(t, fixture["expected"])) for t in vocabulary)
                excess += row_excess
                introduced_excess += max(0, row_excess - base_excess)
                before, after = original.split(), row["text"].split()
                changes = [dict(before=" ".join(before[a:b]), after=" ".join(after[c:d]))
                           for tag, a, b, c, d in difflib.SequenceMatcher(a=before, b=after, autojunk=False).get_opcodes()
                           if tag != "equal"]
                audit.append(dict(experiment=file.stem, mode=mode, id=row["id"], voice=row["voice"],
                                  original=original, text=row["text"], changes=changes, script_edits=error,
                                  baseline_script_edits=base_error, excess_terms=row_excess,
                                  guard_decisions=row.get("guard_decisions")))
            summary.append(dict(experiment=file.stem, mode=mode, exact_terms=hits, targets=targets,
                                script_word_edits=edits, clips_worse_than_baseline=worse,
                                excess_dictionary_mentions=excess, introduced_excess_mentions=introduced_excess,
                                finish_median_ms=None if mode.startswith(("exact-alias", "guarded")) else
                                round(statistics.median(r["finish_seconds"] for r in group)*1000, 1)))
    assert summary, "No measurements"
    for name, data in [("summary.json", summary), ("changes.json", audit)]:
        (OUT / name).write_text(json.dumps(data, indent=2) + "\n")
    lines = ["# Correction sweep", "", "Same human recordings; exploratory tuning, not held-out validation.", "",
             "Word edits compare against the displayed script, which may differ from the words actually read. "
             "Worse clips have more script word edits than their paired uncorrected transcript. "
             "Excess mentions count exact dictionary spellings beyond their script occurrence counts; they are "
             "an automated warning metric, not independently annotated false-positive labels.", "",
             "| Run | Dictionary/policy | Exact terms | Script word edits | Worse clips / 18 | Excess mentions | Newly introduced excess | Finish median ms |",
             "|---|---|---:|---:|---:|---:|---:|---:|"]
    for s in summary:
        lines.append(f'| {s["experiment"]} | {s["mode"]} | {s["exact_terms"]}/{s["targets"]} | {s["script_word_edits"]} | '
                     f'{s["clips_worse_than_baseline"]} | {s["excess_dictionary_mentions"]} | '
                     f'{s["introduced_excess_mentions"]} | {s["finish_median_ms"]} |')
    lines += ["", "Exact-alias policies operate on raw baseline text without CTC correction. They accept only "
              "unambiguous, complete multiword aliases and preserve all other text. Their timing is not measured. "
              "All profiles sharing a tier reproduced identical raw baseline transcripts.", ""]
    lines += ["Guarded policies apply a text-only check to strict native output: accept isolated replacements "
              "whose output is a configured canonical term, reject insertions/deletions, and reject spans "
              "consuming common function words unless they match an explicit alias. Other raw text and "
              "trailing punctuation are preserved. The guard cannot detect every incorrect term substitution. "
              "It was evaluated after full transcription using separately collected raw baselines; its "
              "streaming integration and additional runtime cost have not been implemented or measured.", ""]
    if (OUT / "single-pass-check.json").exists():
        proof = json.loads((OUT / "single-pass-check.json").read_text())
        assert proof["jsonl_sha256"] == hashlib.sha256((OUT / "single-pass.jsonl").read_bytes()).hexdigest()
        lines += [f'An additional {proof["rows"]}-row probe captured raw text via `consumeTokenTimings()` during '
                  'the same inference run as the corrected text. Every raw transcript matched the separate '
                  'uncorrected baseline, and every corrected transcript stayed unchanged. A second ASR '
                  'inference pass is therefore unnecessary for access to both texts on these fixtures.', ""]
    (OUT / "summary.md").write_text("\n".join(lines))
    print(f"Validated {len(list(OUT.glob('*-sweep-*.jsonl'))) * 72} native result rows; report: {OUT / 'summary.md'}")


if __name__ == "__main__":
    action = sys.argv[1]
    if action == "run":
        run(int(sys.argv[2]) if len(sys.argv) > 2 else 640, sys.argv[3:] or PROFILES)
    else:
        {"prepare": prepare, "report": report, "check": checks, "probe": probe}[action]()
