"""Deterministic teardown and failed-gate diagnostic regression coverage."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch


CI = Path(__file__).resolve().parents[1]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


harness = load_module("runtime_cleanup_test_harness", CI.parent / "test-whisper-runtime-helper-v2.py")
diagnostic = load_module("runtime_inference_diagnostic_test", CI / "diagnose-runtime-inference.py")


class InferenceBudgetTests(unittest.TestCase):
    def test_only_explicit_cpu_mode_uses_the_hosted_inference_budget(self):
        for device_mode, expected in (("0", 180.0), ("1", 30.0), ("", 30.0)):
            with self.subTest(device_mode=device_mode), patch.dict(
                os.environ, {"GGML_METAL_DEVICES": device_mode}
            ):
                self.assertEqual(harness.inference_timeout(), expected)

    def test_cpu_receipt_preserves_non_inference_deadlines(self):
        with patch.dict(os.environ, {"GGML_METAL_DEVICES": "0"}):
            deadlines = harness.declared_configuration()["harnessTimeoutsSeconds"]
        self.assertEqual(deadlines["inference"], 180.0)
        self.assertEqual(deadlines["defaultFrameRead"], 5.0)
        self.assertEqual(deadlines["loadReady"], 15.0)
        self.assertEqual(deadlines["backendAttestation"], 2.0)
        self.assertEqual(deadlines["networkMonitorStartup"], 3.0)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.helper = harness.Helper.__new__(harness.Helper)
        self.helper.process = Mock(pid=123, poll=Mock(return_value=None))
        self.helper.process.wait.side_effect = lambda **_: self.events.append("wait")
        self.helper.monitor = Mock()
        self.helper.monitor.stop.side_effect = lambda: self.events.append("stop")
        self.kill = patch.object(harness.os, "killpg", side_effect=lambda *_: self.events.append("kill"))
        self.kill.start()
        self.addCleanup(self.kill.stop)

    def test_observation_stops_before_kill_and_reap(self):
        self.helper.terminate()
        self.assertEqual(self.events, ["stop", "kill", "wait"])

    def test_monitor_failure_still_kills_and_reaps(self):
        self.helper.monitor.stop.side_effect = harness.TestFailure("monitor failure")
        with self.assertRaisesRegex(harness.TestFailure, "monitor failure"):
            self.helper.terminate()
        self.assertEqual(self.events, ["kill", "wait"])

    def test_primary_timeout_survives_secondary_monitor_failure(self):
        primary = harness.TestFailure("inference timed out")
        self.helper.monitor.stop.side_effect = harness.TestFailure("monitor failure")
        with contextlib.redirect_stderr(io.StringIO()) as output:
            with self.assertRaises(harness.TestFailure) as raised:
                try:
                    raise primary
                finally:
                    self.helper.terminate()
        self.assertIs(raised.exception, primary)
        self.assertIn("Secondary helper cleanup failure: monitor failure", output.getvalue())
        self.assertEqual(self.events, ["kill", "wait"])

    def test_exit_between_poll_and_kill_is_reaped(self):
        harness.os.killpg.side_effect = ProcessLookupError()
        self.helper.terminate()
        self.assertEqual(self.events, ["stop", "wait"])

    def test_already_exited_helper_is_reaped_without_signal(self):
        self.helper.process.poll.return_value = 0
        self.helper.terminate()
        self.assertEqual(self.events, ["stop", "wait"])

    def test_signal_error_does_not_skip_wait(self):
        harness.os.killpg.side_effect = OSError("signal failed")
        with self.assertRaisesRegex(OSError, "signal failed"):
            self.helper.terminate()
        self.assertEqual(self.events, ["stop", "wait"])


class DiagnosticTests(unittest.TestCase):
    def run_diagnostic(self, inference_error=None, backend="cpu", constructor_error=None):
        helper = Mock(observed_backend=backend)
        helper.expect.return_value.payload = b'{"transcription":[]}'
        helper.expect.side_effect = inference_error
        output = io.StringIO()
        with patch.object(diagnostic.harness, "Helper", return_value=helper,
                          side_effect=constructor_error), \
                patch.object(diagnostic.harness, "read_public_audio_fixture"), \
                patch.object(diagnostic.threading, "Thread"), \
                patch.dict(os.environ, {"GGML_METAL_DEVICES": "0"}), \
                contextlib.redirect_stdout(output):
            status = diagnostic.run(Path("/private/helper"), Path("/private/model"), Path("/private/audio"))
        rows = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertNotIn("/private/", output.getvalue())
        self.assertNotIn("transcription", output.getvalue())
        return helper, status, rows

    def test_one_request_completes_with_attested_backend_and_cleanup(self):
        helper, status, rows = self.run_diagnostic()
        self.assertEqual(status, 0)
        self.assertEqual(helper.send.call_count, 1)
        frame = helper.send.call_args.args[0]
        self.assertEqual(frame.operation, diagnostic.harness.TRANSCRIBE)
        self.assertLessEqual(helper.expect.call_args.kwargs["timeout"], 180)
        helper.shutdown.assert_called_once()
        helper.terminate.assert_called_once()
        self.assertEqual(rows[-1]["outcome"], "completed")

    def test_timeout_is_failure_and_reaps_helper_without_path_disclosure(self):
        helper, status, rows = self.run_diagnostic(TimeoutError("/private/audio"))
        self.assertEqual(status, 1)
        self.assertEqual(next(row for row in rows if row["event"] == "failure")["phase"], "inference")
        helper.terminate.assert_called_once()

    def test_wall_clock_ceiling_interrupts_blocked_inference(self):
        started = time.monotonic()
        with patch.object(diagnostic, "CEILING_SECONDS", 0.05):
            helper, status, rows = self.run_diagnostic(lambda *_args, **_kwargs: time.sleep(2))
        self.assertEqual(status, 1)
        self.assertLess(time.monotonic() - started, 1)
        self.assertEqual(next(row for row in rows if row["event"] == "failure")["errorType"], "TimeoutError")
        helper.terminate.assert_called_once()

    def test_backend_mismatch_prevents_request(self):
        helper, status, _ = self.run_diagnostic(backend="unknown")
        self.assertEqual(status, 1)
        helper.send.assert_not_called()
        helper.terminate.assert_called_once()

    def test_launch_monitor_failure_does_not_run_inference(self):
        helper, status, rows = self.run_diagnostic(constructor_error=harness.TestFailure("launch scans"))
        self.assertEqual(status, 1)
        helper.send.assert_not_called()
        self.assertEqual(next(row for row in rows if row["event"] == "failure")["phase"], "load")

    def test_process_sample_excludes_command_and_identity(self):
        with patch.object(diagnostic.subprocess, "run", return_value=Mock(
                returncode=0, stdout=" 397.2 1:23.45 512000 R+\n")) as command:
            result = diagnostic.sample_process(123)
        self.assertEqual(result["cpuPercent"], 397.2)
        self.assertEqual(command.call_args.args[0][-1], "%cpu=,time=,rss=,state=")


class OwnedProcessCleanupTests(unittest.TestCase):
    def test_actual_owned_process_reaped_after_monitor_failure(self):
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                                   start_new_session=True)
        helper = harness.Helper.__new__(harness.Helper)
        helper.process = process
        helper.monitor = Mock()
        helper.monitor.stop.side_effect = harness.TestFailure("monitor failure")
        try:
            with self.assertRaisesRegex(harness.TestFailure, "monitor failure"):
                helper.terminate()
            self.assertEqual(process.returncode, -9)
            with self.assertRaises(ChildProcessError):
                os.waitpid(process.pid, os.WNOHANG)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)


class GateDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="steno-gate-diagnostic-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.scripts = self.root / "repo/scripts"
        (self.scripts / "ci").mkdir(parents=True)
        shutil.copyfile(CI / "runtime-checks.sh", self.scripts / "ci/runtime-checks.sh")
        (self.scripts / "ci/prepare-runtime.sh").write_text("exit 0\n")
        for name in ("build-whisper-runtime-helper", "test-whisper-prompt-verification",
                     "test-whisper-vad-integrity"):
            (self.scripts / f"{name}.sh").write_text("exit 0\n")
        (self.scripts / "test-whisper-prompt-scoring.sh").write_text("echo unexpected-later-check\n")
        self.runtime = self.root / "runtime"
        self.runtime.mkdir()
        commands = self.root / "commands"
        commands.mkdir()
        uname = commands / "uname"
        uname.write_text('#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; esac\n')
        uname.chmod(0o755)
        self.environment = {**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"]}

    def run_gate(self, protocol_status, diagnostic_status):
        (self.scripts / "test-whisper-runtime-helper-v2.sh").write_text(f"exit {protocol_status}\n")
        (self.scripts / "ci/diagnose-runtime-inference.py").write_text(
            f"print('diagnostic-called')\nraise SystemExit({diagnostic_status})\n")
        return subprocess.run(["bash", str(self.scripts / "ci/runtime-checks.sh"), "--root",
                               str(self.runtime), "--output", str(self.root / "output")],
                              env=self.environment, capture_output=True, text=True)

    def test_successful_diagnostic_preserves_original_failure(self):
        result = self.run_gate(17, 0)
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("diagnostic-called"), 1)
        self.assertNotIn("unexpected-later-check", result.stdout)

    def test_failed_diagnostic_preserves_original_failure(self):
        result = self.run_gate(17, 23)
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("diagnostic-called"), 1)

    def test_passing_protocol_does_not_run_diagnostic(self):
        result = self.run_gate(0, 0)
        self.assertNotIn("diagnostic-called", result.stdout)
        self.assertIn("invalid runtime receipt", result.stderr)


if __name__ == "__main__":
    unittest.main()
