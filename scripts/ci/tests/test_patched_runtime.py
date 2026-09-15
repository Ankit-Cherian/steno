"""Offline checks for isolated runtime patching and cache reuse."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "prepare-patched-runtime.py"
spec = importlib.util.spec_from_file_location("patched_runtime", SCRIPT)
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class PatchedRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="steno-patched-runtime-")
        self.root = Path(self.temporary.name).resolve()
        self.upstream = self.root / "upstream"
        self.upstream.mkdir()
        self.git("init", "--quiet")
        (self.upstream / "source.c").write_text("int value = 1;\n")
        self.git("add", "source.c")
        self.git("-c", "user.name=Runtime test", "-c", "user.email=test@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Fixture")
        self.revision = self.git("rev-parse", "HEAD").strip()
        self.build = self.root / "build"
        self.patch = self.root / "reviewed.patch"
        self.patch.write_text("--- a/source.c\n+++ b/source.c\n@@ -1 +1 @@\n-int value = 1;\n+int value = 2;\n")

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.upstream), *args], text=True)

    def prepare(self):
        return runtime.prepare(self.upstream, self.build, self.revision, self.patch)

    def snapshot(self, root):
        return {p.relative_to(root).as_posix(): p.read_bytes()
                for p in root.rglob("*") if p.is_file() and not p.is_symlink()}

    def test_patch_applies_to_archive_and_reuse_preserves_upstream(self):
        before = self.snapshot(self.upstream)
        source = self.prepare()
        self.assertEqual((source / "source.c").read_text(), "int value = 2;\n")
        source_stat = source.stat()
        self.assertEqual(source, self.prepare())
        self.assertEqual(source_stat.st_ino, source.stat().st_ino)
        self.assertEqual(before, self.snapshot(self.upstream))
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_matching_cmake_cache_can_be_reused(self):
        source = self.prepare()
        (self.build / "CMakeCache.txt").write_text(f"CMAKE_HOME_DIRECTORY:INTERNAL={source}\n")
        self.assertEqual(self.prepare(), source)

    def test_dirty_upstream_is_rejected_without_repair(self):
        (self.upstream / "source.c").write_text("user change\n")
        with self.assertRaisesRegex(RuntimeError, "modified tracked"):
            self.prepare()
        self.assertEqual((self.upstream / "source.c").read_text(), "user change\n")
        self.assertFalse(self.build.exists())

    def test_untracked_source_is_rejected(self):
        (self.upstream / "injected.c").write_text("unexpected\n")
        with self.assertRaisesRegex(RuntimeError, "unexpected untracked"):
            self.prepare()

    def test_wrong_revision_is_rejected(self):
        self.revision = "a" * 40
        with self.assertRaisesRegex(RuntimeError, "revision does not match"):
            self.prepare()
        self.assertFalse(self.build.exists())

    def test_changed_patch_uses_different_source_and_preserves_prior_source(self):
        first = self.prepare()
        before = self.snapshot(first.parent)
        self.patch.write_text(self.patch.read_text().replace("value = 2", "value = 3"))
        second = self.prepare()
        self.assertNotEqual(first, second)
        self.assertEqual((second / "source.c").read_text(), "int value = 3;\n")
        self.assertEqual(before, self.snapshot(first.parent))

    def test_mismatched_cmake_cache_fails_before_modifying_build(self):
        self.prepare()
        (self.build / "CMakeCache.txt").write_text(f"CMAKE_HOME_DIRECTORY:INTERNAL={self.upstream}\n")
        before = self.snapshot(self.build)
        with self.assertRaisesRegex(RuntimeError, "fresh STENO_WHISPER_BUILD_DIR"):
            self.prepare()
        self.assertEqual(before, self.snapshot(self.build))

    def test_changed_patch_cannot_reuse_prior_cmake_cache(self):
        first = self.prepare()
        (self.build / "CMakeCache.txt").write_text(f"CMAKE_HOME_DIRECTORY:INTERNAL={first}\n")
        self.patch.write_text(self.patch.read_text().replace("value = 2", "value = 3"))
        before = self.snapshot(self.build)
        with self.assertRaisesRegex(RuntimeError, "fresh STENO_WHISPER_BUILD_DIR"):
            self.prepare()
        self.assertEqual(before, self.snapshot(self.build))

    def test_patch_failure_leaves_prior_source_untouched(self):
        self.prepare()
        before = self.snapshot(self.build)
        self.patch.write_text(self.patch.read_text().replace("value = 1", "value = 99"))
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare()
        self.assertEqual(before, self.snapshot(self.build))
        self.assertFalse(any((self.build / "patched-source").glob(".staging-*")))

    def test_tampered_source_and_manifest_are_both_rejected(self):
        source = self.prepare()
        (source / "source.c").write_text("tampered\n")
        manifest_path = source.parent / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["files"] = runtime.source_manifest(source)
        manifest_path.write_text(json.dumps(manifest))
        before = self.snapshot(self.build)
        with self.assertRaisesRegex(RuntimeError, "manifest does not match"):
            self.prepare()
        self.assertEqual(before, self.snapshot(self.build))

    def test_tampered_source_is_rejected(self):
        source = self.prepare()
        (source / "source.c").write_text("tampered\n")
        with self.assertRaisesRegex(RuntimeError, "content does not match"):
            self.prepare()
        self.assertEqual((source / "source.c").read_text(), "tampered\n")

    def test_unexpected_file_or_empty_directory_is_rejected(self):
        source = self.prepare()
        for extra in (source / "unexpected.c", source / "empty"):
            with self.subTest(extra=extra.name):
                if extra.suffix:
                    extra.write_text("unexpected\n")
                else:
                    extra.mkdir()
                with self.assertRaisesRegex(RuntimeError, "content does not match"):
                    self.prepare()
                extra.unlink() if extra.is_file() else extra.rmdir()

    def test_source_symlink_is_rejected_without_touching_target(self):
        source = self.prepare()
        target = self.root / "private.txt"
        target.write_text("untouched\n")
        (source / "link").symlink_to(target)
        with self.assertRaisesRegex(RuntimeError, "symlink"):
            self.prepare()
        self.assertEqual(target.read_text(), "untouched\n")

    def test_build_directory_symlink_is_rejected(self):
        target = self.root / "other-build"
        target.mkdir()
        self.build.symlink_to(target)
        with self.assertRaisesRegex(RuntimeError, "Symlink paths"):
            self.prepare()
        self.assertEqual(list(target.iterdir()), [])

    def test_manifest_symlink_is_rejected(self):
        source = self.prepare()
        manifest = source.parent / "manifest.json"
        target = self.root / "other-manifest"
        manifest.rename(target)
        manifest.symlink_to(target)
        with self.assertRaisesRegex(RuntimeError, "Symlink paths"):
            self.prepare()

    def test_archive_rejects_traversal_symlinks_and_special_files(self):
        for name, kind in (("../outside", tarfile.REGTYPE), ("link", tarfile.SYMTYPE),
                           ("fifo", tarfile.FIFOTYPE), (".git/config", tarfile.REGTYPE)):
            with self.subTest(name=name):
                buffer = io.BytesIO()
                with tarfile.open(fileobj=buffer, mode="w") as archive:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    archive.addfile(member)
                with self.assertRaises(RuntimeError):
                    runtime.extract_archive(buffer.getvalue(), self.root / "extracted")

    def test_patch_cannot_escape_generated_source(self):
        self.patch.write_text("--- /dev/null\n+++ b/../outside\n@@ -0,0 +1 @@\n+unexpected\n")
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare()
        self.assertFalse((self.build / "outside").exists())

    def test_executable_bit_tampering_is_rejected(self):
        source = self.prepare()
        (source / "source.c").chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, "content does not match"):
            self.prepare()


if __name__ == "__main__":
    unittest.main()
