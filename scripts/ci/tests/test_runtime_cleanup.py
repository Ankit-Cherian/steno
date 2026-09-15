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
        self.assertEqual(deadlines["networkMonitorStartup"], 25.0)
        self.assertEqual(deadlines["networkMonitorQuery"], 5.0)
        self.assertEqual(deadlines["networkMonitorStop"], 6.0)


class NetworkMonitorTests(unittest.TestCase):
    def setUp(self):
        self.process = Mock(pid=123, poll=Mock(return_value=None))
        for name, value in (("lsof_timeout_seconds", 0.05),
                            ("startup_timeout_seconds", 0.3),
                            ("stop_timeout_seconds", 0.1),
                            ("poll_interval_seconds", 0.001)):
            setting = patch.object(harness.RuntimeNetworkMonitor, name, value)
            setting.start()
            self.addCleanup(setting.stop)

    def test_slow_queries_complete_both_launch_scans(self):
        calls = []

        def slow_query(command, **kwargs):
            calls.append((command, kwargs))
            time.sleep(0.025)
            if "-i" in command:
                return Mock(returncode=1, stdout="", stderr="")
            return Mock(returncode=0, stdout="COMMAND PID FD\nhelper 123 txt\n", stderr="")

        started = time.monotonic()
        with patch.object(harness.subprocess, "run", side_effect=slow_query):
            monitor = harness.RuntimeNetworkMonitor(self.process)
            monitor.stop()
        self.assertGreaterEqual(time.monotonic() - started, 0.1)
        self.assertGreaterEqual(monitor.scans, 2)
        self.assertEqual(monitor.network_fd_count, 0)
        self.assertFalse(monitor.thread.is_alive())
        self.assertGreaterEqual(sum("-i" in command for command, _ in calls), 2)
        self.assertTrue(all(options["timeout"] == 0.05 for _, options in calls))
        self.assertTrue(all("-X" not in command for command, _ in calls))

    def test_query_timeout_fails_closed_and_reaps_the_query_process(self):
        real_run, real_popen = subprocess.run, subprocess.Popen
        queries = []

        def launch(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            queries.append(process)
            return process

        def timeout_query(_command, **kwargs):
            return real_run([sys.executable, "-c", "import time; time.sleep(10)"], **kwargs)

        monitor = harness.RuntimeNetworkMonitor.__new__(harness.RuntimeNetworkMonitor)
        with patch.object(harness.subprocess, "run", side_effect=timeout_query), \
                patch.object(harness.subprocess, "Popen", side_effect=launch), \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(harness.TestFailure, "lsof query timed out"):
                monitor.__init__(self.process)
        self.assertEqual(monitor.scans, 0)
        self.assertTrue(monitor.stop_requested.is_set())
        self.assertFalse(monitor.thread.is_alive())
        self.assertEqual(len(queries), 1)
        self.assertIsNotNone(queries[0].poll())
        with self.assertRaises(ChildProcessError):
            os.waitpid(queries[0].pid, os.WNOHANG)

    def test_startup_timeout_stops_between_queries_and_preserves_primary_failure(self):
        def slow_query(*_args, **_kwargs):
            time.sleep(0.03)
            return Mock(returncode=0, stdout="COMMAND PID FD\n", stderr="")

        monitor = harness.RuntimeNetworkMonitor.__new__(harness.RuntimeNetworkMonitor)
        with patch.object(harness.RuntimeNetworkMonitor, "startup_timeout_seconds", 0.005), \
                patch.object(harness.subprocess, "run", side_effect=slow_query) as query, \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(harness.TestFailure, "did not complete two launch scans"):
                monitor.__init__(self.process)
        self.assertEqual(query.call_count, 1)
        self.assertEqual(monitor.scans, 0)
        self.assertFalse(monitor.thread.is_alive())
        self.assertTrue(monitor.stopped)

    def test_constructor_scan_failure_leaves_no_monitor_thread(self):
        monitor = harness.RuntimeNetworkMonitor.__new__(harness.RuntimeNetworkMonitor)
        with patch.object(harness.subprocess, "run", return_value=Mock(
                returncode=1, stdout="", stderr="permission denied")), \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(harness.TestFailure, "could not inspect"):
                monitor.__init__(self.process)
        self.assertFalse(monitor.thread.is_alive())
        self.assertEqual(monitor.scans, 0)

    def test_network_descriptor_still_blocks_startup(self):
        def query(command, **_kwargs):
            return Mock(returncode=0, stdout="COMMAND PID FD\nhelper 123 socket\n", stderr="")

        monitor = harness.RuntimeNetworkMonitor.__new__(harness.RuntimeNetworkMonitor)
        with patch.object(harness.subprocess, "run", side_effect=query), \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(harness.TestFailure, "opened a network file descriptor"):
                monitor.__init__(self.process)
        self.assertEqual(monitor.network_fd_count, 1)
        self.assertFalse(monitor.thread.is_alive())

    def test_each_raw_process_case_reaps_helper_when_monitor_construction_fails(self):
        cases = (
            lambda: harness.test_global_oversized_header(Path("fixture"), None, None, None),
            lambda: harness.run_before_ready_case(Path("fixture"), Path("model"), eof=True),
            lambda: harness.run_before_ready_case(Path("fixture"), Path("model"), eof=False),
        )
        for case in cases:
            with self.subTest(case=case):
                owned = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(10)"],
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         start_new_session=True)
                primary = harness.TestFailure("launch scans failed")
                try:
                    with patch.object(harness.subprocess, "Popen", return_value=owned), \
                            patch.object(harness, "RuntimeNetworkMonitor", side_effect=primary):
                        with self.assertRaises(harness.TestFailure) as raised:
                            case()
                    self.assertIs(raised.exception, primary)
                    self.assertEqual(owned.returncode, -9)
                    with self.assertRaises(ChildProcessError):
                        os.waitpid(owned.pid, os.WNOHANG)
                finally:
                    if owned.poll() is None:
                        owned.kill()
                        owned.wait(timeout=5)
                    owned.stdin.close()
                    owned.stdout.close()


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


class ForcedCrashTimingTests(unittest.TestCase):
    def make_helper(self, source):
        process = subprocess.Popen([sys.executable, "-c", source], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, start_new_session=True)
        helper = harness.Helper.__new__(harness.Helper)
        helper.process, helper.input, helper.output = process, process.stdin, process.stdout
        helper.monitor = Mock()

        def cleanup():
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            process.stdin.close()
            process.stdout.close()

        self.addCleanup(cleanup)
        return helper

    def test_monitor_join_cannot_allow_an_inflight_response_before_forced_crash(self):
        helper = self.make_helper(
            "import sys; sys.stdin.buffer.read(1); "
            "sys.stdout.buffer.write(b'response'); sys.stdout.buffer.flush(); "
            "sys.stdin.buffer.read()")
        monitor = helper.monitor
        events = []
        monitor.request_stop.side_effect = lambda: events.append("request-stop")

        def join_monitor():
            events.append("join")
            # Model the scheduler opportunity during a slow query join: if the
            # helper is still alive it completes its pending response first.
            if helper.process.poll() is None:
                helper.input.write(b"x")
                helper.input.flush()
                ready, _, _ = harness.select.select([helper.output.fileno()], [], [], 2)
                self.assertTrue(ready, "fixture did not complete its pending response")
            else:
                events.append("already-reaped")

        monitor.stop.side_effect = join_monitor
        helper.force_crash_and_expect_eof()
        self.assertEqual(events, ["request-stop", "join", "already-reaped"])
        self.assertEqual(helper.process.returncode, -9)
        monitor.stop.assert_called_once()

    def test_buffered_response_still_fails_the_empty_output_assertion(self):
        helper = self.make_helper(
            "import sys; sys.stdout.buffer.write(b'response'); "
            "sys.stdout.buffer.flush(); sys.stdin.buffer.read()")
        ready, _, _ = harness.select.select([helper.output.fileno()], [], [], 2)
        self.assertTrue(ready)
        with self.assertRaisesRegex(harness.TestFailure, "late response after forced crash"):
            helper.force_crash_and_expect_eof()
        self.assertEqual(helper.process.returncode, -9)

    def test_monitor_join_failure_does_not_delay_or_prevent_forced_crash(self):
        helper = self.make_helper("import sys; sys.stdin.buffer.read()")
        helper.monitor.stop.side_effect = harness.TestFailure("observation failed")
        with self.assertRaisesRegex(harness.TestFailure, "observation failed"):
            helper.force_crash_and_expect_eof()
        self.assertEqual(helper.process.returncode, -9)
        with self.assertRaises(ChildProcessError):
            os.waitpid(helper.process.pid, os.WNOHANG)


class GateDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="steno-gate-diagnostic-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.scripts = self.root / "repo/scripts"
        (self.scripts / "ci").mkdir(parents=True)
        shutil.copyfile(CI / "runtime-checks.sh", self.scripts / "ci/runtime-checks.sh")
        (self.scripts / "ci/prepare-runtime.sh").write_text("exit 0\n")
        (self.scripts / "ci/prepare-patched-runtime.py").write_text("print('staged-source')\n")
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
        git = commands / "git"
        git.write_text('#!/bin/sh\necho 764482c3175d9c3bc6089c1ec84df7d1b9537d83\n')
        git.chmod(0o755)
        self.environment = {**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"]}

    def run_gate(self, protocol_status, diagnostic_status, allocation_status=0):
        (self.scripts / "ci/test-vendor-allocation-failures.py").write_text(
            f"print('allocation-check-called')\nraise SystemExit({allocation_status})\n")
        (self.scripts / "test-whisper-runtime-helper-v2.sh").write_text(f"exit {protocol_status}\n")
        (self.scripts / "ci/diagnose-runtime-inference.py").write_text(
            f"print('diagnostic-called')\nraise SystemExit({diagnostic_status})\n")
        return subprocess.run(["bash", str(self.scripts / "ci/runtime-checks.sh"), "--root",
                               str(self.runtime), "--output", str(self.root / "output")],
                              env=self.environment, capture_output=True, text=True)

    def test_allocation_failure_stops_runtime_gate(self):
        result = self.run_gate(17, 0, allocation_status=29)
        self.assertEqual(result.returncode, 29, result.stdout + result.stderr)
        self.assertIn("allocation-check-called", result.stdout)
        self.assertNotIn("==> helper-protocol", result.stdout)
        self.assertNotIn("diagnostic-called", result.stdout)

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
