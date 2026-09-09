#!/usr/bin/env bash
# Provision audited sources and model bytes. Never build or repair an existing checkout.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$SCRIPT_DIR" "$@" <<'PY'
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

script_dir = Path(sys.argv[1]).resolve()
repository = script_dir.parent.parent
parser = argparse.ArgumentParser(description="Provision checksum-pinned whisper.cpp sources and public models")
parser.add_argument("--root", type=Path, default=repository / "vendor/whisper.cpp")
parser.add_argument("--asset-cache", type=Path, help="Optional model-only cache; every hit is verified")
parser.add_argument("--verify-only", action="store_true", help="Validate existing inputs without network or writes")
args = parser.parse_args(sys.argv[2:])

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def run(*command):
    return subprocess.check_output(command, text=True, stderr=subprocess.PIPE).strip()

def safe_path(path):
    # Do not follow a symlink to overwrite a different checkout or cache.
    absolute = Path(os.path.abspath(path))
    require(not any(part.is_symlink() for part in [absolute, *absolute.parents]),
            f"Symlink paths are not supported: {absolute}")
    return absolute

def verify_model(path, model):
    require(path.is_file() and not path.is_symlink(), f"Missing or unsafe model: {path}")
    require(path.stat().st_size == model["size"], f"Model size mismatch: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    require(digest.hexdigest() == model["sha256"], f"Model checksum mismatch: {path}")

def verify_checkout(root, revision):
    require((root / ".git").is_dir() and not (root / ".git").is_symlink(),
            f"Existing runtime root must be a standalone Git checkout: {root}")
    require(run("git", "-C", str(root), "rev-parse", "HEAD") == revision,
            "Runtime checkout revision does not match runtime-lock.json")
    require(not run("git", "-C", str(root), "status", "--porcelain", "--untracked-files=no"),
            "Runtime checkout has modified tracked sources")
    untracked = run("git", "-C", str(root), "ls-files", "--others", "--exclude-standard").splitlines()
    allowed = {"models/" + model["filename"] for model in lock["models"]}
    require(set(untracked) <= allowed, "Runtime checkout has unexpected untracked files")
    require((root / "include/whisper.h").is_file(), "Runtime checkout is missing whisper.h")

try:
    lock = json.loads((script_dir / "runtime-lock.json").read_text())
    require(lock["schema_version"] == 1, "Unsupported runtime lock schema")
    revision = lock["whisper"]["revision"]
    require(re.fullmatch(r"[0-9a-f]{40}", revision), "Runtime revision must be a full commit SHA")
    require(lock["whisper"]["repository"] == "https://github.com/ggml-org/whisper.cpp.git",
            "Unexpected runtime source repository")
    helper = (repository / "scripts/build-whisper-runtime-helper.sh").read_text()
    match = re.search(r'^EXPECTED_REVISION="([0-9a-f]{40})"$', helper, re.MULTILINE)
    require(match and match[1] == revision, "Runtime lock and build helper revision pins disagree")
    names = [model["filename"] for model in lock["models"]]
    require(sorted(names) == ["ggml-silero-v6.2.0.bin", "ggml-small.en.bin"], "Unexpected model set")
    for model in lock["models"]:
        require(re.fullmatch(r"[0-9a-f]{64}", model["sha256"]), "Invalid model SHA-256")
        require(isinstance(model["size"], int) and model["size"] > 0, "Invalid model size")
        require(re.fullmatch(r"https://huggingface.co/(ggerganov/whisper\.cpp|ggml-org/whisper-vad)/resolve/[0-9a-f]{40}/" + re.escape(model["filename"]), model["url"]),
                "Model URL must name an immutable public upstream revision")
    root = safe_path(args.root)
    cache = safe_path(args.asset_cache) if args.asset_cache else None
    require(root != repository and root not in repository.parents, "Runtime root cannot contain the Steno repository")
    if cache:
        require(cache != root and root not in cache.parents and cache not in root.parents,
                "Model cache and runtime root must not overlap")

    if root.exists():
        verify_checkout(root, revision)
    else:
        require(not args.verify_only, f"Missing runtime checkout: {root}")
        root.parent.mkdir(parents=True, exist_ok=True)
        # Only the newly created staging directory is removed on failure.
        with tempfile.TemporaryDirectory(prefix=".steno-runtime-", dir=root.parent) as staging:
            checkout = Path(staging) / "checkout"
            run("git", "init", "--quiet", str(checkout))
            run("git", "-C", str(checkout), "remote", "add", "origin", lock["whisper"]["repository"])
            run("git", "-C", str(checkout), "-c", "protocol.file.allow=never", "fetch", "--depth=1", "origin", revision)
            run("git", "-C", str(checkout), "checkout", "--quiet", "--detach", "FETCH_HEAD")
            verify_checkout(checkout, revision)
            require(not root.exists(), "Runtime root appeared during provisioning")
            checkout.rename(root)

    # Existing files must validate before any download or copy is attempted.
    for model in lock["models"]:
        destination = safe_path(root / "models" / model["filename"])
        if destination.exists():
            verify_model(destination, model)
        elif args.verify_only:
            raise RuntimeError(f"Missing model: {destination}")
        cached_path = safe_path(cache / model["filename"]) if cache else None
        if cached_path and cached_path.exists():
            verify_model(cached_path, model)

    for model in lock["models"]:
        destination = root / "models" / model["filename"]
        if destination.exists():
            continue
        target_dir = cache if cache else destination.parent
        target_dir.mkdir(parents=True, exist_ok=True)
        cached = target_dir / model["filename"]
        if not cached.exists():
            with tempfile.TemporaryDirectory(prefix=".steno-model-", dir=target_dir) as staging:
                download = Path(staging) / model["filename"]
                subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
                                "--proto", "=https", "--proto-redir", "=https", "--retry", "3",
                                "--connect-timeout", "30", "--max-time", "1800",
                                "--output", str(download), model["url"]], check=True)
                verify_model(download, model)
                require(not cached.exists(), "Model appeared during provisioning")
                download.rename(cached)
        if cached != destination:
            # Never overwrite an existing asset, even when cache restore races.
            with destination.open("xb") as output, cached.open("rb") as source:
                shutil.copyfileobj(source, output)
        verify_model(destination, model)
    verify_checkout(root, revision)
    print(f"Verified runtime {revision} and {len(lock['models'])} SHA-256-pinned models: {root}")
except (RuntimeError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
PY
