"""Offline rejection tests for the actual provisioning entrypoint.

Tiny throwaway Git repositories and model bytes exercise verification without
network, the developer runtime checkout, or large model downloads.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys
import unittest


SOURCE = Path(__file__).resolve().parents[1]


class RuntimeBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="steno-bootstrap-test-")
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "steno"
        self.scripts = self.repo / "scripts/ci"
        self.scripts.mkdir(parents=True)
        self.entrypoint = self.scripts / "prepare-runtime.sh"
        shutil.copyfile(SOURCE / "prepare-runtime.sh", self.entrypoint)
        self.runtime = self.root / "runtime"
        self.runtime.mkdir()
        self.git("init", "--quiet")
        (self.runtime / "include").mkdir()
        (self.runtime / "include/whisper.h").write_text("// test fixture\n")
        (self.runtime / "models").mkdir()
        (self.runtime / "models/.gitignore").write_text("*.bin\n")
        self.git("add", "include/whisper.h", "models/.gitignore")
        self.git("-c", "user.name=Runtime test", "-c", "user.email=test@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Fixture")
        self.revision = self.git("rev-parse", "HEAD").strip()
        (self.repo / "scripts/build-whisper-runtime-helper.sh").write_text(
            f'EXPECTED_REVISION="{self.revision}"\n')
        self.lock = json.loads((SOURCE / "runtime-lock.json").read_text())
        self.lock["whisper"]["revision"] = self.revision
        for model in self.lock["models"]:
            payload = (model["filename"] + " fixture").encode()
            model["size"] = len(payload)
            model["sha256"] = hashlib.sha256(payload).hexdigest()
            (self.runtime / "models" / model["filename"]).write_bytes(payload)
        self.write_lock()

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.runtime), *arguments], text=True)

    def write_lock(self):
        (self.scripts / "runtime-lock.json").write_text(json.dumps(self.lock))

    def check(self, *arguments, success=False, reason=None):
        result = subprocess.run(["bash", str(self.entrypoint), "--root", str(self.runtime),
                                 "--verify-only", *arguments], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        if reason:
            self.assertIn(reason, result.stderr)
        return result

    def test_verified_inputs_pass_without_changes(self):
        before = {p.relative_to(self.runtime): p.read_bytes() for p in self.runtime.rglob("*")
                  if p.is_file() and ".git" not in p.parts}
        self.check(success=True)
        after = {p.relative_to(self.runtime): p.read_bytes() for p in self.runtime.rglob("*")
                 if p.is_file() and ".git" not in p.parts}
        self.assertEqual(before, after)

    def test_checksum_mismatch_is_rejected_without_repair(self):
        model = self.runtime / "models/ggml-small.en.bin"
        corrupted = b"!" * model.stat().st_size
        model.write_bytes(corrupted)
        self.check(reason="Model checksum mismatch")
        self.assertEqual(model.read_bytes(), corrupted)

    def test_lock_and_builder_pin_mismatch_is_rejected(self):
        self.lock["whisper"]["revision"] = "a" * 40
        self.write_lock()
        self.check(reason="revision pins disagree")

    def test_checkout_pin_mismatch_is_rejected(self):
        self.lock["whisper"]["revision"] = "a" * 40
        self.write_lock()
        (self.repo / "scripts/build-whisper-runtime-helper.sh").write_text(
            f'EXPECTED_REVISION="{"a" * 40}"\n')
        self.check(reason="checkout revision does not match")

    def test_dirty_checkout_is_preserved_and_rejected(self):
        header = self.runtime / "include/whisper.h"
        header.write_text("// edited fixture\n")
        self.check(reason="modified tracked sources")
        self.assertEqual(header.read_text(), "// edited fixture\n")

    def test_untracked_source_is_rejected(self):
        (self.runtime / "include/injected.h").write_text("// unexpected source\n")
        self.check(reason="unexpected untracked files")

    def test_missing_model_is_rejected_in_verify_only_mode(self):
        (self.runtime / "models/ggml-small.en.bin").unlink()
        self.check(reason="Missing model")

    def test_mutable_model_url_is_rejected(self):
        self.lock["models"][0]["url"] = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
        self.write_lock()
        self.check(reason="immutable public upstream revision")

    def test_corrupt_cache_is_not_used_or_repaired(self):
        cache = self.root / "cache"
        cache.mkdir()
        cached = cache / "ggml-small.en.bin"
        cached.write_bytes(b"x" * self.lock["models"][0]["size"])
        self.check("--asset-cache", str(cache), reason="Model checksum mismatch")
        self.assertEqual(cached.read_bytes(), b"x" * self.lock["models"][0]["size"])

    def test_symlink_model_is_rejected(self):
        model = self.runtime / "models/ggml-small.en.bin"
        target = self.root / "other-model.bin"
        model.rename(target)
        model.symlink_to(target)
        self.check(reason="Symlink paths are not supported")

    def test_bad_download_is_not_promoted_to_model_or_cache(self):
        model = self.runtime / "models/ggml-small.en.bin"
        model.unlink()
        cache = self.root / "cache"
        commands = self.root / "commands"
        commands.mkdir()
        curl = commands / "curl"
        curl.write_text(f"#!{sys.executable}\nimport sys\nfrom pathlib import Path\n"
                        f"Path(sys.argv[sys.argv.index('--output') + 1]).write_bytes({b'x' * self.lock['models'][0]['size']!r})\n")
        curl.chmod(0o755)
        result = subprocess.run(["bash", str(self.entrypoint), "--root", str(self.runtime),
                                 "--asset-cache", str(cache)], capture_output=True, text=True,
                                env={**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"]})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Model checksum mismatch", result.stderr)
        self.assertFalse(model.exists())
        self.assertFalse((cache / model.name).exists())
        self.assertEqual(list(cache.iterdir()), [])


class RuntimeReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="steno-receipt-test-")
        self.receipt_path = Path(self.temporary.name) / "receipt.json"
        self.receipt = {
            "cases": {"expected": 26, "passed": 26, "failed": 0, "skipped": 0,
                      "failureRows": [], "skipRows": [],
                      "rows": [{"name": f"case {index}", "status": "passed",
                                "failureReason": None, "skipReason": None} for index in range(26)]},
            "execution": {"matrix": "full-adversarial", "backendEligibleProcessCount": 25,
                          "attestedProcessCount": 25, "backend": "observed-cpu",
                          "observedBackends": {"cpu": 25, "metal": 0, "unknown": 0},
                          "requestedDeviceMode": "cpu-device-suppressed",
                          "qualification": "nonqualifying-cpu-diagnostic",
                          "productionMetalSmokePerformed": False},
        }

    def tearDown(self):
        self.temporary.cleanup()

    def check(self, backend="cpu", success=False, reason=None):
        self.receipt_path.write_text(json.dumps(self.receipt))
        result = subprocess.run(["bash", str(SOURCE / "runtime-checks.sh"), "--backend", backend,
                                 "--verify-receipt", str(self.receipt_path)], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        if reason:
            self.assertIn(reason, result.stderr)

    def test_cpu_receipt_passes_without_metal_qualification(self):
        self.check(success=True)

    def test_cpu_receipt_cannot_qualify_as_metal(self):
        self.check(backend="metal", reason="requested backend")

    def test_cpu_receipt_cannot_claim_production_metal_smoke(self):
        self.receipt["execution"]["productionMetalSmokePerformed"] = True
        self.check(reason="must not claim production Metal")

    def test_missing_case_fails_even_when_aggregate_claims_pass(self):
        self.receipt["cases"]["rows"].pop()
        self.check(reason="26 unique cases")

    def test_failed_case_fails_even_when_aggregate_claims_pass(self):
        self.receipt["cases"]["rows"][0]["status"] = "failed"
        self.check(reason="did not all pass")

    def test_missing_process_attestation_fails(self):
        self.receipt["execution"]["attestedProcessCount"] = 24
        self.check(reason="Not all eligible processes")

    def test_unknown_backend_fails(self):
        self.receipt["execution"]["observedBackends"] = {"cpu": 24, "metal": 0, "unknown": 1}
        self.check(reason="requested backend")

    def test_invalid_backend_is_rejected_before_work(self):
        self.check(backend="auto", reason="--backend must be cpu or metal")


if __name__ == "__main__":
    unittest.main()
