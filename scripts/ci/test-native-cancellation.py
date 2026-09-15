#!/usr/bin/env python3
"""Exercise cancellation and reuse through the real vendor scheduler helper."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--whisper-root", type=Path, required=True)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--backend", choices=("cpu", "metal"), default="cpu")
    parser.add_argument("--original-policy", action="store_true",
                        help="adapt the original helper signature only, to demonstrate the regression")
    args = parser.parse_args()
    vendor = args.whisper_root.resolve(strict=True)
    build = args.build_dir.resolve(strict=True)
    version = re.search(r"^CMAKE_PROJECT_VERSION:STATIC=([0-9.]+)$",
                        (build / "CMakeCache.txt").read_text(), re.MULTILINE)
    if not version:
        parser.error("build directory has no CMake project version")
    source = Path(__file__).with_suffix(".cpp")
    with tempfile.TemporaryDirectory(prefix="steno-cancellation-tests-") as temporary:
        implementation = vendor / "src/whisper.cpp"
        if args.original_policy:
            text = implementation.read_text()
            old = "bool   sched_reset = true) {"
            if text.count(old) != 1:
                parser.error("original-policy requires the original scheduler helper")
            text = text.replace(old, "bool   sched_reset = true, ggml_abort_callback = nullptr, void * = nullptr) {")
            implementation = Path(temporary) / "original-whisper.cpp"
            implementation.write_text(text)
        binary = Path(temporary) / "cancellation"
        command = ["xcrun", "clang++", "-std=c++17", "-O0", "-arch", "arm64",
                   "-mmacosx-version-min=13.0", "-DGGML_USE_CPU", "-DGGML_USE_METAL",
                   f'-DWHISPER_VERSION="{version.group(1)}"',
                   f'-DSTENO_VENDOR_IMPLEMENTATION="{implementation}"']
        for include in ["include", "src", "ggml/include", "ggml/src"]:
            command.extend(["-I", str(vendor / include)])
        for directory in [build / "ggml/src", build / "ggml/src/ggml-metal"]:
            command.extend(["-L", str(directory), f"-Wl,-rpath,{directory}"])
        command.extend([str(source), "-lggml", "-lggml-base", "-lggml-cpu", "-lggml-metal", "-o", str(binary)])
        subprocess.run(command, check=True, timeout=120)
        return subprocess.run([str(binary), args.backend], timeout=30).returncode


if __name__ == "__main__":
    raise SystemExit(main())
