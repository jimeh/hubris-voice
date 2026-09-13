"""Stage owned model assets and probe FluidAudio without its shared cache."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parent
OUT = ROOT / ".build/cache-isolation"
SHARED = Path.home() / "Library/Application Support/FluidAudio"


def digest(file):
    value = hashlib.sha256()
    with file.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def snapshot(directory):
    return {str(p.relative_to(directory)): dict(bytes=p.stat().st_size, sha256=digest(p))
            for p in sorted(directory.rglob("*")) if p.is_file()}


def prepare():
    OUT.mkdir(parents=True, exist_ok=True)
    pointer = OUT / "owned-root.txt"
    if pointer.exists():
        raise RuntimeError("An isolation fixture already exists; preserve it and run the prepared probe")
    owned = Path.home() / "Library/Application Support/Hubris Voice/Experiments" / ("cache-isolation-" + uuid.uuid4().hex)
    owned.mkdir(parents=True)
    pointer.write_text(str(owned) + "\n")
    print("Hashing existing shared assets before staging", flush=True)
    (OUT / "shared-before.json").write_text(json.dumps(snapshot(SHARED), indent=2) + "\n")
    inventory = json.loads((ROOT / ".build/results/model-inventory.json").read_text())
    copied = []
    for entry in inventory:
        primary = "unified" in entry["repo"]
        if primary and "70_7_1" in entry["file"]:
            continue
        directory = "parakeet-unified-en-0.6b" if primary else "parakeet-ctc-110m-coreml"
        source = SHARED / "Models" / directory / entry["file"]
        destination = owned / ("primary" if primary else "ctc") / entry["file"]
        assert not source.is_symlink() and digest(source) == entry["sha256"], source
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        assert digest(destination) == entry["sha256"]
        copied.append(dict(relative=str(destination.relative_to(owned)), bytes=entry["bytes"], sha256=entry["sha256"]))
    (owned / "runtime/tmp").mkdir(parents=True)
    (OUT / "owned-inventory.json").write_text(json.dumps(copied, indent=2) + "\n")
    # Data roots are JSON-escaped as Scheme strings; no shell interpolation.
    shared_rules = f'(deny file-read* file-write* (subpath {json.dumps(str(SHARED))}))\n'
    base = '(version 1)\n(allow default)\n(deny network*)\n' + shared_rules
    (OUT / "assets-isolated.sb").write_text(base)
    strict = base + f'(deny file-write* (require-not (subpath {json.dumps(str(owned))})))\n'
    (OUT / "writes-contained.sb").write_text(strict)
    print(f"Staged {len(copied)} files, {sum(e['bytes'] for e in copied)} bytes, at {owned}")


def restrictions_check(owned):
    script = '''import json,pathlib,sys
owned, shared, outside = map(pathlib.Path, sys.argv[1:])
assert (owned/'ctc/tokenizer.json').read_bytes()
try:
    (shared/'Models/parakeet-ctc-110m-coreml/tokenizer.json').read_bytes()
except PermissionError:
    pass
else:
    raise AssertionError('Shared cache read was not blocked')
(owned/'runtime/write-control').write_text('allowed')
try:
    outside.write_text('must not be written')
except PermissionError:
    pass
else:
    raise AssertionError('Outside write was not blocked')
print(json.dumps(dict(owned_read=True, shared_read_denied=True, owned_write=True, outside_write_denied=True)))
'''
    result = subprocess.run(["sandbox-exec", "-f", str(OUT / "writes-contained.sb"),
                             sys.executable, "-c", script, str(owned), str(SHARED), str(OUT / "forbidden-write")],
                            text=True, capture_output=True, check=True)
    (OUT / "restriction-check.json").write_text(result.stdout)
    print(result.stdout.strip())


def run():
    owned = Path((OUT / "owned-root.txt").read_text().strip())
    restrictions_check(owned)
    env = {k: v for k, v in os.environ.items() if not k.startswith("FLUID_")}
    env["TMPDIR"] = str(owned / "runtime/tmp") + "/"
    results = []
    for profile, mode in [("assets-isolated", "builtin"), ("assets-isolated", "public"),
                          ("writes-contained", "public")]:
        name = f"{profile}-{mode}"
        print(f"Running {name}", flush=True)
        with (OUT / f"{name}.jsonl").open("w") as output, (OUT / f"{name}.log").open("w") as errors:
            result = subprocess.run(["sandbox-exec", "-f", str(OUT / f"{profile}.sb"),
                                     str(ROOT / ".build/release/CacheIsolationProbe"), mode, str(owned),
                                     str(ROOT / ".build/human/correction/manifest.json")],
                                    stdout=output, stderr=errors, env=env, cwd=ROOT)
        results.append(dict(profile=profile, mode=mode, exit_code=result.returncode))
    before = json.loads((OUT / "shared-before.json").read_text())
    after = snapshot(SHARED)
    (OUT / "shared-after.json").write_text(json.dumps(after, indent=2) + "\n")
    report = dict(runs=results, shared_cache_unchanged=before == after, owned_root=str(owned),
                  owned_files_after=snapshot(owned))
    (OUT / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(dict(runs=results, shared_cache_unchanged=before == after), indent=2))


def verify():
    report = json.loads((OUT / "results.json").read_text())
    def records(name):
        return [json.loads(line) for line in (OUT / f"{name}.jsonl").read_text().splitlines()]
    runs = {(r["profile"], r["mode"]): r["exit_code"] for r in report["runs"]}
    builtin = records("assets-isolated-builtin")
    assert runs[("assets-isolated", "builtin")] != 0
    assert any(r["stage"].startswith("configure:") and str(SHARED) in r.get("error", "") for r in builtin)
    assert report["shared_cache_unchanged"], "Shared cache was modified"
    inventory = json.loads((OUT / "owned-inventory.json").read_text())
    assert all(report["owned_files_after"][entry["relative"]]["sha256"] == entry["sha256"] for entry in inventory)
    expected = {("identifiers", f"Jim-take-{n}") for n in (1, 2, 3)} | {("technical", "Jim-take-1"), ("brands", "Jim-take-1")}
    evidence = {}
    for profile in ["assets-isolated", "writes-contained"]:
        rows = [r for r in records(f"{profile}-public") if r["stage"] == "result"]
        succeeded = runs[(profile, "public")] == 0
        if succeeded:
            assert len(rows) == 5 and {(r["id"], r["voice"]) for r in rows} == expected
            assert all(r["raw"] and r["corrected"] and r["preview_count"] > 0 for r in rows)
        evidence[profile] = dict(succeeded=succeeded, result_count=len(rows))
    assert evidence["assets-isolated"]["succeeded"], "Explicit public API path did not succeed"
    if evidence["writes-contained"]["succeeded"]:
        def texts(name):
            return {(r["id"], r["voice"]): (r["raw"], r["corrected"])
                    for r in records(name) if r["stage"] == "result"}
        assert texts("assets-isolated-public") == texts("writes-contained-public")
        evidence["restriction_profiles_produced_identical_text"] = True
    evidence["builtin_shared_lookup_confirmed"] = True
    evidence["shared_cache_unchanged"] = True
    evidence["owned_model_assets_unchanged"] = True
    (OUT / "verification.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    {"prepare": prepare, "run": run, "verify": verify}[sys.argv[1]]()
