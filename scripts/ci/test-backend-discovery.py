#!/usr/bin/env python3
"""Verify linked-backend builds never automatically open backend plugins."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def run(command, cwd, environment):
    result = subprocess.run(
        [str(part) for part in command], cwd=cwd, env=environment,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45,
    )
    if result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} exited with {result.returncode}")
    return result.stdout.decode("utf-8", errors="replace")


def marker_plugin(directory, filename, environment):
    marker = directory / "constructor-marker"
    source = directory / "marker.c"
    source.write_text(
        "#include <fcntl.h>\n#include <unistd.h>\n"
        "__attribute__((constructor)) static void mark(void) {\n"
        f"    int fd = open({json.dumps(str(marker))}, O_WRONLY|O_CREAT|O_EXCL, 0600);\n"
        '    if (fd >= 0) { (void)write(fd, "loaded\\n", 7); close(fd); }\n'
        "}\nint ggml_backend_score(void) { return 0; }\n",
        encoding="utf-8",
    )
    plugin = directory / filename
    run(["xcrun", "clang", "-arch", "arm64", "-dynamiclib",
         "-mmacosx-version-min=13.0", source, "-o", plugin], directory, environment)
    return plugin, marker


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", required=True, type=Path)
    parser.add_argument("--whisper-root", required=True, type=Path)
    args = parser.parse_args()
    build = args.build_dir.resolve()
    upstream = args.whisper_root.resolve()
    cli = build / "bin/whisper-cli"
    if not cli.is_file():
        parser.error("build directory must contain bin/whisper-cli")
    if "GGML_BACKEND_DL:BOOL=OFF" not in (build / "CMakeCache.txt").read_text():
        parser.error("these checks require GGML_BACKEND_DL=OFF")

    environment = dict(os.environ)
    for name in ("GGML_BACKEND_PATH", "DYLD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES"):
        environment.pop(name, None)
    environment["GGML_METAL_DEVICES"] = "0"
    failures = []

    with tempfile.TemporaryDirectory(prefix="steno-backend-discovery-") as temporary:
        root = Path(temporary)
        clean = root / "clean"
        clean.mkdir()
        probe_source = root / "backend-probe.cpp"
        probe_source.write_text(r'''
#include "ggml-backend.h"
#include <cstdio>
#include <cstring>
int main(int argc, char ** argv) {
    if (argc == 3 && std::strcmp(argv[1], "explicit") == 0) {
        (void) ggml_backend_load(argv[2]);
    } else if (argc == 3 && std::strcmp(argv[1], "directory") == 0) {
        ggml_backend_load_all_from_path(argv[2]);
    } else {
        ggml_backend_load_all();
    }
    for (size_t i = 0; i < ggml_backend_reg_count(); ++i) {
        std::printf("backend:%s\n", ggml_backend_reg_name(ggml_backend_reg_get(i)));
    }
}
''', encoding="utf-8")
        probe = root / "backend-probe"
        libraries = build / "ggml/src"
        run(["xcrun", "clang++", "-arch", "arm64", "-std=c++17",
             "-I", upstream / "ggml/include", probe_source,
             "-L", libraries, "-lggml", "-lggml-base",
             f"-Wl,-rpath,{libraries}", f"-Wl,-rpath,{libraries / 'ggml-metal'}",
             "-o", probe], clean, environment)
        registered = run([probe], clean, environment)
        if "backend:CPU\n" not in registered or "backend:MTL\n" not in registered:
            failures.append("linked CPU and Metal registration")
        else:
            print("PASS linked CPU and Metal registration", flush=True)

        for name in ("environment", "working-directory", "executable-directory",
                     "explicit-directory", "explicit-api"):
            directory = root / name
            directory.mkdir()
            plugin, marker = marker_plugin(directory, "libggml-cpu-marker.so", environment)
            child_environment = dict(environment)
            cwd = clean
            command = [cli, "--help"]
            if name == "environment":
                child_environment["GGML_BACKEND_PATH"] = str(plugin)
            elif name == "working-directory":
                cwd = directory
            elif name == "executable-directory":
                copied_cli = directory / "whisper-cli"
                shutil.copy2(cli, copied_cli)
                command = [copied_cli, "--help"]
            elif name == "explicit-directory":
                command = [probe, "directory", directory]
            else:
                command = [probe, "explicit", plugin]
            run(command, cwd, child_environment)
            expected = name == "explicit-api"
            observed = marker.exists()
            valid_marker = not observed or marker.read_bytes() == b"loaded\n"
            if observed != expected or not valid_marker:
                failures.append(name)
                print(f"FAIL {name}: constructor execution={observed}, expected={expected}", flush=True)
            else:
                print(f"PASS {name}", flush=True)

    if failures:
        raise RuntimeError("Backend discovery checks failed: " + ", ".join(failures))
    print("Backend discovery checks passed", flush=True)


if __name__ == "__main__":
    main()
