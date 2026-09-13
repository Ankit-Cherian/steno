#!/usr/bin/env python3
"""Generate deterministic fake-engine inputs; these do not measure ASR accuracy."""
import json
from pathlib import Path
import sys
import wave


def main():
    manifest_path, output_path = map(Path, sys.argv[1:])
    manifest = json.loads(manifest_path.read_text())
    expected_ids = {
        "repair-term-recovery",
        "filler-heavy-small-model",
        "ide-slash-safety",
    }
    samples = manifest["samples"]
    if (manifest["evidenceTier"] != "smokeFixture"
            or len(samples) != len(expected_ids)
            or {sample["id"] for sample in samples} != expected_ids):
        raise SystemExit("Unexpected smoke manifest; update the fixture definitions explicitly.")
    for sample in samples:
        if sample["audioPath"] != f"fixtures/audio/{sample['id']}.wav":
            raise SystemExit("Unexpected smoke audio path.")
        if sample["audioDurationMS"] != 10000:
            raise SystemExit("Unexpected smoke duration; update the generated audio explicitly.")

    output_path.mkdir(parents=True, exist_ok=False)
    audio_path = output_path / "fixtures" / "audio"
    audio_path.mkdir(parents=True)
    for sample in samples:
        with wave.open(str(audio_path / f"{sample['id']}.wav"), "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16000)
            audio.writeframes(bytes(16000 * 10 * 2))
    (output_path / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (output_path / "fake-model.bin").write_bytes(b"Synthetic smoke model placeholder; not a Whisper model.\n")
    fake_cli = output_path / "fake-whisper-cli.sh"
    fake_cli.write_text('''#!/bin/sh
set -eu
audio_path=""
output_base=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -f) audio_path="$2"; shift 2 ;;
    -of) output_base="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$output_base" ] && [ -f "$audio_path" ] || exit 2
case "${audio_path##*/}" in
  repair-term-recovery.wav) text="send it to John scratch that Jane and ping terso" ;;
  filler-heavy-small-model.wav) text="Um I think uh this should ship today" ;;
  ide-slash-safety.wav) text="/build target" ;;
  *) echo "Unknown synthetic smoke sample" >&2; exit 2 ;;
esac
printf '%s\\n' "$text" > "${output_base}.txt"
''')
    fake_cli.chmod(0o755)


if __name__ == "__main__":
    main()
