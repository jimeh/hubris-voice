"""Generate public synthetic fixtures locally; no microphone or network use."""
import hashlib
import json
from pathlib import Path
import subprocess
import wave

ROOT = Path(__file__).resolve().parent
OUT = ROOT / ".build" / "audio"
OUT.mkdir(parents=True, exist_ok=True)
spec = json.loads((ROOT / "fixtures.json").read_text())
records = []
for voice in spec["voices"]:
    for case in spec["cases"]:
        output = OUT / f'{voice}-{case["id"]}.wav'
        subprocess.run([
            "/usr/bin/say", "-v", voice, "-r", "165", "-o", str(output),
            "--file-format=WAVE", "--data-format=LEI16@16000", case["spoken"],
        ], check=True)
        with wave.open(str(output)) as audio:
            assert audio.getnchannels() == 1 and audio.getframerate() == 16000
            duration = audio.getnframes() / audio.getframerate()
        records.append(dict(case, voice=voice, file=str(output), seconds=duration,
                            sha256=hashlib.sha256(output.read_bytes()).hexdigest()))
output = OUT / "silence.wav"
with wave.open(str(output), "wb") as audio:
    audio.setnchannels(1)
    audio.setsampwidth(2)
    audio.setframerate(16000)
    audio.writeframes(bytes(16000 * 2 * 3))
records.append(dict(id="silence", spoken="", expected="", terms=[], aliases={},
                    voice="none", file=str(output), seconds=3,
                    sha256=hashlib.sha256(output.read_bytes()).hexdigest()))
(OUT / "manifest.json").write_text(json.dumps(dict(distractors=spec["distractors"], recordings=records), indent=2) + "\n")
print(f"Prepared {len(records)} recordings in {OUT}")
