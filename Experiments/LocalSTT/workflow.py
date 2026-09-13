"""Mise entrypoint for native STT experiments; Python only orchestrates files/processes."""
import hashlib
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / ".build"
VENDOR = BUILD / "vendor"
RESULTS = BUILD / "results"
LIB = VENDOR / "sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts-lib"
MODEL = VENDOR / "sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming"
MANIFEST = BUILD / "audio/manifest.json"
FLUID = BUILD / "release/LocalSTTExperiment"
SHERPA = BUILD / "SherpaExperiment"
NATIVE_ASSETS = [
    ("sherpa-lib.tar.bz2", "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts-lib.tar.bz2", "f3e0cbd86cc3f38dad30c97921b40e9a8bcc6f2c943777eb76ad77176993e417"),
    ("sherpa-model.tar.bz2", "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming.tar.bz2", "99f63605b3a85a54c250c0869670a687b7d6598a47bf2421515e1f839a76e150"),
    ("unified.nemo", "https://huggingface.co/nvidia/parakeet-unified-en-0.6b/resolve/fe53cd885760c96b6a5f51a0bfd362cb4584a98b/parakeet-unified-en-0.6b.nemo", "ec23ed9150c8fde49072c3e2d61678ab903dbcef389d658db833420cbc1da35b"),
    ("c-api.h", "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/sherpa-onnx/c-api/c-api.h", "2a1b95084be8fd1deb3228fcad2fd3f7f0258b64582f7402281ec174c7b7f4ce"),
]


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def digest(file, algorithm="sha256"):
    value = hashlib.new(algorithm)
    with file.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def fetch(url, file):
    file.parent.mkdir(parents=True, exist_ok=True)
    temporary = file.with_name(file.name + ".partial")
    run("curl", "-fLsS", "--retry", "3", "-o", temporary, url)
    temporary.replace(file)


def prepare_models():
    VENDOR.mkdir(parents=True, exist_ok=True)
    for name, url, checksum in NATIVE_ASSETS:
        file = VENDOR / name
        if not file.exists():
            fetch(url, file)
        if digest(file) != checksum:
            raise RuntimeError(f"Checksum mismatch: {file}")
    if not LIB.exists():
        run("tar", "-xjf", VENDOR / "sherpa-lib.tar.bz2", "-C", VENDOR)
    if not MODEL.exists():
        run("tar", "-xjf", VENDOR / "sherpa-model.tar.bz2", "-C", VENDOR)
    with tarfile.open(VENDOR / "unified.nemo") as archive:
        names = [name for name in archive.getnames() if name.endswith("_tokenizer.vocab")]
        if len(names) != 1:
            raise RuntimeError("Expected exactly one NVIDIA tokenizer vocabulary")
        (MODEL / "bpe.vocab").write_bytes(archive.extractfile(names[0]).read())
    # Verify symbol IDs as well as using the original SentencePiece scores.
    vocab = [line.split("\t")[0] for line in (MODEL / "bpe.vocab").read_text().splitlines()]
    tokens = [line.rsplit(" ", 1)[0] for line in (MODEL / "tokens.txt").read_text().splitlines()]
    if tokens[:len(vocab)] != vocab:
        raise RuntimeError("NVIDIA tokenizer does not match sherpa token IDs")

    cache = Path.home() / "Library/Application Support/FluidAudio/Models"
    specifications = [
        ("FluidInference/parakeet-unified-en-0.6b-coreml", "4252711f6f060f9a2f91e5f081a806d7f45eebd8", "parakeet-unified-en-0.6b", [
            "parakeet_unified_decoder.mlmodelc", "parakeet_unified_joint_decision_single_step.mlmodelc",
            "parakeet_unified_encoder_streaming_70_7_1_int8.mlmodelc",
            "parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc", "vocab.json", "config.json", "metadata.json"]),
        ("FluidInference/parakeet-ctc-110m-coreml", "accdafd8cf8a2ff1cabe3c11e54416b405d409aa", "parakeet-ctc-110m-coreml", [
            "AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "vocab.json", "tokenizer.json",
            "tokenizer_config.json", "special_tokens_map.json", "config.json", "ctc_head_metadata.json"]),
    ]
    inventory = []
    for repo, revision, directory, roots in specifications:
        with urllib.request.urlopen(f"https://huggingface.co/api/models/{repo}/tree/{revision}?recursive=true&limit=1000") as response:
            files = json.load(response)
        for item in files:
            relative = item["path"]
            if item["type"] != "file" or relative.split("/")[0] not in roots:
                continue
            file = cache / directory / relative
            if not file.exists():
                fetch(f"https://huggingface.co/{repo}/resolve/{revision}/{relative}", file)
            if "lfs" in item:
                valid = digest(file) == item["lfs"]["oid"]
            else:
                data = file.read_bytes()
                valid = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest() == item["oid"]
            if not valid:
                raise RuntimeError(f"Existing cache differs from pinned revision; refusing to overwrite {file}")
            inventory.append(dict(repo=repo, revision=revision, file=relative,
                                  bytes=file.stat().st_size, sha256=digest(file)))
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "model-inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    print("Verified pinned native assets, tokenizer IDs, and FluidAudio models", flush=True)


def build():
    run("swift", "build", "-c", "release")
    module = BUILD / "SherpaModule"
    module.mkdir(parents=True, exist_ok=True)
    (module / "module.modulemap").write_text('module CSherpa { header "../vendor/c-api.h" export * }\n')
    run("swiftc", "-O", "-parse-as-library", "-I", module, "-L", LIB / "lib",
        "-lsherpa-onnx-c-api", "-Xlinker", "-rpath", "-Xlinker",
        "@executable_path/vendor/" + LIB.name + "/lib", ROOT / "SherpaExperiment.swift", "-o", SHERPA)


def measure(name, *command):
    print(f"Running {name} with network access denied", flush=True)
    RESULTS.mkdir(parents=True, exist_ok=True)
    with (RESULTS / (name + ".jsonl")).open("w") as output, (RESULTS / (name + ".log")).open("w") as errors:
        subprocess.run(["sandbox-exec", "-p", "(version 1)(allow default)(deny network*)",
                        *map(str, command)], cwd=ROOT, stdout=output, stderr=errors, check=True)


def capture_environment(audio_source):
    def capture(*command):
        return subprocess.check_output(command, text=True).strip()

    return dict(
        date=datetime.now(timezone.utc).isoformat(),
        cpu=capture("sysctl", "-n", "machdep.cpu.brand_string"),
        memory_bytes=int(capture("sysctl", "-n", "hw.memsize")),
        macos=capture("sw_vers", "-productVersion"),
        xcode=capture("xcodebuild", "-version"),
        swift=capture("swift", "--version"),
        network_during_measurement="Denied by sandbox-exec profile",
        audio_source=audio_source,
        native_source_versions={"FluidAudio": "0.15.7", "sherpa-onnx": "1.13.8"},
    )


def experiments():
    RESULTS.mkdir(parents=True, exist_ok=True)
    environment = capture_environment("macOS say, Daniel and Samantha, 165 words/minute")
    (RESULTS / "environment.json").write_text(json.dumps(environment, indent=2) + "\n")
    # Serial execution avoids competing inference workloads distorting latency.
    measure("fluid-640", FLUID, "run", MANIFEST)
    measure("fluid-320", FLUID, "run", MANIFEST, "320")
    measure("fluid-paced-640", FLUID, "run", MANIFEST, "paced")
    measure("fluid-paced-320", FLUID, "run", MANIFEST, "paced", "320")
    measure("sherpa-beam", SHERPA, MODEL, MANIFEST)
    measure("sherpa-beam-3", SHERPA, MODEL, MANIFEST, "3")
    measure("sherpa-beam-6", SHERPA, MODEL, MANIFEST, "6")
    measure("sherpa-greedy", SHERPA, MODEL, MANIFEST, "greedy")
    measure("fluid-lifecycle", FLUID, "lifecycle", MANIFEST)


if __name__ == "__main__":
    {"setup": prepare_models, "build": build, "run": experiments}[sys.argv[1]]()
