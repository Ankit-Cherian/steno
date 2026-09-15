#!/usr/bin/env python3
"""Stage the pinned runtime with the reviewed patch without editing its checkout."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

SCRIPT_DIR = Path(__file__).resolve().parent


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def safe_path(path):
    path = Path(os.path.abspath(path))
    require(not any(item.is_symlink() for item in (path, *path.parents)),
            f"Symlink paths are not supported: {path}")
    return path


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.PIPE)


def verify_checkout(root, revision):
    require((root / ".git").is_dir() and not (root / ".git").is_symlink(),
            "Runtime must be a standalone Git checkout")
    require(git(root, "rev-parse", "HEAD").decode().strip() == revision,
            "Runtime checkout revision does not match the expected revision")
    require(not git(root, "status", "--porcelain", "--untracked-files=no").strip(),
            "Runtime checkout has modified tracked sources")
    untracked = set(git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0")) - {b""}
    allowed = {b"models/ggml-small.en.bin", b"models/ggml-silero-v6.2.0.bin"}
    require(untracked <= allowed, "Runtime checkout has unexpected untracked files")


def extract_archive(archive, destination):
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as stream:
        for member in stream:
            relative = PurePosixPath(member.name)
            require(not relative.is_absolute() and ".." not in relative.parts
                    and ".git" not in relative.parts and relative.parts,
                    "Unsafe runtime archive path")
            require(member.isdir() or member.isfile(), "Runtime archive contains a link or special file")
            target = destination.joinpath(*relative.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open("xb") as output, stream.extractfile(member) as source:
                    shutil.copyfileobj(source, output)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)


def source_manifest(root):
    records = {}
    for item in sorted(root.rglob("*")):
        mode = item.lstat().st_mode
        relative = item.relative_to(root).as_posix()
        require(not stat.S_ISLNK(mode), f"Staged runtime contains a symlink: {relative}")
        if stat.S_ISDIR(mode):
            records[relative] = {"kind": "directory"}
        else:
            require(stat.S_ISREG(mode), f"Staged runtime contains a special file: {relative}")
            records[relative] = {"kind": "file", "executable": bool(mode & 0o111),
                                 "sha256": hashlib.sha256(item.read_bytes()).hexdigest()}
    return records


def prepare(upstream, build_dir, revision, patch):
    upstream, build_dir, patch = map(safe_path, (upstream, build_dir, patch))
    require(re.fullmatch(r"[0-9a-f]{40}", revision), "Expected revision must be a full commit SHA")
    require(build_dir != upstream and build_dir not in upstream.parents,
            "Build directory cannot contain the runtime checkout")
    require(patch.is_file(), "Missing reviewed runtime patch")
    patch_bytes = patch.read_bytes()
    require(patch_bytes, "Runtime patch must not be empty")
    patch_sha = hashlib.sha256(patch_bytes).hexdigest()
    verify_checkout(upstream, revision)
    destination = safe_path(build_dir / "patched-source" / f"{revision}-{patch_sha}")
    source_root = destination / "source"
    cache = safe_path(build_dir / "CMakeCache.txt")
    if cache.exists():
        homes = [line.partition("=")[2] for line in cache.read_text().splitlines()
                 if line.startswith("CMAKE_HOME_DIRECTORY:INTERNAL=")]
        require(homes == [str(source_root)],
                "Existing CMake cache uses different sources; select a fresh STENO_WHISPER_BUILD_DIR")
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Reconstruct trusted content on every invocation. A modified manifest cannot
    # make modified source acceptable, and no existing state is repaired/deleted.
    with tempfile.TemporaryDirectory(prefix=".staging-", dir=destination.parent) as temporary:
        candidate = Path(temporary) / "candidate"
        candidate_source = candidate / "source"
        candidate_source.mkdir(parents=True)
        extract_archive(git(upstream, "archive", "--format=tar", revision), candidate_source)
        env = {**os.environ, "GIT_CEILING_DIRECTORIES": str(candidate_source.parent)}
        for options in (("--check",), ()):
            subprocess.run(["git", "apply", "--no-index", *options, "-"],
                           input=patch_bytes, cwd=candidate_source, env=env,
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        expected = {"schema_version": 1, "upstream_revision": revision, "patch_sha256": patch_sha,
                    "files": source_manifest(candidate_source)}
        (candidate / "manifest.json").write_text(json.dumps(expected, sort_keys=True, indent=2) + "\n")
        verify_checkout(upstream, revision)
        if destination.exists():
            require(destination.is_dir(), "Staged runtime path is not a directory")
            require({item.name for item in destination.iterdir()} == {"source", "manifest.json"},
                    "Staged runtime contains unexpected files")
            require(safe_path(source_root).is_dir(), "Missing staged runtime source")
            manifest = safe_path(destination / "manifest.json")
            require(manifest.is_file() and json.loads(manifest.read_text()) == expected,
                    "Staged runtime manifest does not match the pinned source and patch")
            require(source_manifest(source_root) == expected["files"],
                    "Staged runtime content does not match the pinned source and patch")
        else:
            candidate.rename(destination)
    return source_root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--build-dir", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    try:
        print(prepare(args.root, args.build_dir, args.revision,
                      SCRIPT_DIR / "patches/whisper-security.patch"))
    except (RuntimeError, OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError) as error:
        detail = error.stderr.decode(errors="replace").strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
        print(f"Error: {detail}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
