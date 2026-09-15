#!/usr/bin/env python3
"""Compile real vendor sources with test-only, deterministic allocation failure.

Requires an existing macOS whisper build. Does not download, patch, or rebuild
the vendor checkout. Each probe compiles the complete selected translation unit
and links its supporting ggml libraries; no model or inference is needed.
"""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--whisper-root", type=Path, required=True)
    parser.add_argument("--build-dir", type=Path, required=True)
    args = parser.parse_args()
    vendor = args.whisper_root.resolve(strict=True)
    build = args.build_dir.resolve(strict=True)
    version = re.search(r"^CMAKE_PROJECT_VERSION:STATIC=([0-9.]+)$",
                        (build / "CMakeCache.txt").read_text(), re.MULTILINE)
    if not version:
        parser.error("build directory has no CMake project version")
    source = Path(__file__).resolve().parents[2] / "runtime-helper/tests/vendor-allocation-failures.cpp"
    library_dirs = [build / "ggml/src", build / "ggml/src/ggml-metal"]
    common = ["xcrun", "clang++", "-std=c++17", "-O0", "-arch", "arm64",
              "-mmacosx-version-min=13.0", "-DGGML_USE_CPU", "-DGGML_USE_METAL",
              f'-DWHISPER_VERSION="{version.group(1)}"']
    for include in ["include", "src", "ggml/include", "ggml/src", "ggml/src/ggml-cpu"]:
        common.extend(["-I", str(vendor / include)])
    for directory in library_dirs:
        common.extend(["-L", str(directory), f"-Wl,-rpath,{directory}"])
    result = 0
    with tempfile.TemporaryDirectory(prefix="steno-allocation-tests-") as temporary:
        for mode, implementation in [("cpu", "ggml/src/ggml-cpu/ggml-cpu.cpp"),
                                     ("vad", "src/whisper.cpp")]:
            binary = Path(temporary) / mode
            command = common + [f'-DSTENO_VENDOR_IMPLEMENTATION="{vendor / implementation}"',
                                f"-DSTENO_ALLOCATION_TEST_CPU={int(mode == 'cpu')}",
                                str(source), "-lggml", "-lggml-base", "-lggml-cpu",
                                "-lggml-metal", "-o", str(binary)]
            print(f"Compiling actual vendor {mode} allocation probe", flush=True)
            subprocess.run(command, check=True, timeout=120)
            completed = subprocess.run([str(binary)], timeout=30)
            if completed.returncode:
                result = 1
    return result


if __name__ == "__main__":
    raise SystemExit(main())
