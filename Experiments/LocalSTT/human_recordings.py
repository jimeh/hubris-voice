"""Build the local recorder and benchmark accepted human recordings. No server."""
import fcntl
import hashlib
import json
from pathlib import Path
import plistlib
import runpy
import subprocess
import sys
import time
import wave

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
HUMAN = ROOT / ".build/human"
APP = ROOT / ".build/STT Phrase Recorder.app"


def run(*args):
    subprocess.run(list(map(str, args)), cwd=REPO, check=True)


def build():
    binary = APP / "Contents/MacOS/Recorder"
    resources = APP / "Contents/Resources"
    binary.parent.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    run("swiftc", "-parse-as-library", ROOT / "Recorder.swift", "-o", binary)
    run(binary, "--self-test")
    (resources / "fixtures.json").write_bytes((ROOT / "fixtures.json").read_bytes())
    (resources / "output-directory.txt").write_text(str(HUMAN) + "\n")
    metadata = dict(
        CFBundleExecutable="Recorder", CFBundleIdentifier="com.jimeh.HubrisVoice.STTRecorder",
        CFBundleName="STT Phrase Recorder", CFBundlePackageType="APPL",
        CFBundleVersion="1", CFBundleShortVersionString="0.1",
        LSMinimumSystemVersion="15.0", NSHighResolutionCapable=True,
        NSMicrophoneUsageDescription="Record the displayed test phrases locally for offline speech recognition experiments.",
    )
    (APP / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata))
    identity = subprocess.check_output([str(REPO / "Scripts/resolve-signing-identity.sh")], text=True).strip()
    run("codesign", "--force", "--sign", identity, APP)
    run("codesign", "--verify", "--strict", APP)


def benchmark():
    workflow = runpy.run_path(str(ROOT / "workflow.py"))
    manifest = HUMAN / "manifest.json"
    recordings = json.loads(manifest.read_text())["recordings"]
    if len(recordings) != 18:
        raise RuntimeError(f"Expected 18 accepted takes, found {len(recordings)}")
    cases = json.loads((ROOT / "fixtures.json").read_text())["cases"]
    for index, recording in enumerate(recordings):
        case = cases[index // 3]
        if (recording["id"], recording["voice"], recording["expected"], recording["terms"]) != (
                case["id"], f"Jim-take-{index % 3 + 1}", case["expected"], case["terms"]):
            raise RuntimeError(f"Recording {index + 1} does not match the planned phrase and take")
        audio_file = Path(recording["file"])
        if hashlib.sha256(audio_file.read_bytes()).hexdigest() != recording["sha256"]:
            raise RuntimeError(f"Recording hash mismatch: {audio_file.name}")
        with wave.open(str(audio_file)) as audio:
            if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
                raise RuntimeError(f"Expected mono PCM16 at 16 kHz: {audio_file.name}")
            if abs(audio.getnframes() / 16000 - recording["seconds"]) > 1 / 16000:
                raise RuntimeError(f"Duration mismatch: {audio_file.name}")
    # Use the same pinned models and deny network for every inference process.
    results = HUMAN / "results"
    results.mkdir(exist_ok=True)
    for name, args in [
        ("fluid-640", [workflow["FLUID"], "run", manifest]),
        ("fluid-320", [workflow["FLUID"], "run", manifest, "320"]),
        ("fluid-paced-640", [workflow["FLUID"], "run", manifest, "paced"]),
        ("fluid-paced-320", [workflow["FLUID"], "run", manifest, "paced", "320"]),
        ("sherpa-beam", [workflow["SHERPA"], workflow["MODEL"], manifest]),
        ("sherpa-beam-3", [workflow["SHERPA"], workflow["MODEL"], manifest, "3"]),
        ("sherpa-greedy", [workflow["SHERPA"], workflow["MODEL"], manifest, "greedy"]),
        ("fluid-lifecycle", [workflow["FLUID"], "lifecycle", manifest]),
    ]:
        print(f"Running {name}", flush=True)
        with (results / f"{name}.jsonl").open("w") as output, (results / f"{name}.log").open("w") as errors:
            subprocess.run(["sandbox-exec", "-p", "(version 1)(allow default)(deny network*)", *map(str, args)],
                           cwd=ROOT, stdout=output, stderr=errors, check=True)
    environment = workflow["capture_environment"]("Human speech, three accepted takes per phrase, default macOS microphone")
    (results / "environment.json").write_text(json.dumps(environment, indent=2) + "\n")
    (results / "model-inventory.json").write_bytes((workflow["RESULTS"] / "model-inventory.json").read_bytes())
    run(sys.executable, ROOT / "report.py", "--human")
    (HUMAN / "tested").write_text("complete\n")
    print(f"Finished. Report: {results / 'summary.md'}", flush=True)


def watch():
    HUMAN.mkdir(parents=True, exist_ok=True)
    with (HUMAN / "watch.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        print("Waiting for all 18 takes to be accepted in STT Phrase Recorder.", flush=True)
        while not (HUMAN / "ready").exists():
            time.sleep(1)
        if not (HUMAN / "tested").exists():
            benchmark()


def launch():
    build()
    HUMAN.mkdir(parents=True, exist_ok=True)
    with (HUMAN / "benchmark.log").open("a") as log:
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "watch"],
                         stdout=log, stderr=log, cwd=REPO, start_new_session=True)
    run("open", APP)
    print(f"Recorder opened. Accepted takes: {HUMAN}")


if __name__ == "__main__":
    {"build": build, "launch": launch, "watch": watch, "run": benchmark}[sys.argv[1]]()
