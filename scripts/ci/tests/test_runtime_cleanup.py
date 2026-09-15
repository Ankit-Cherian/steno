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
        monitor.request_stop_for_sigkill.side_effect = lambda: events.append("request-stop")

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


class ForcedCrashScanBoundaryTests(unittest.TestCase):
    make_helper = ForcedCrashTimingTests.make_helper
    def test_inflight_empty_query_waits_for_confirmed_owned_sigkill(self):
        helper = self.make_helper("import sys; sys.stdin.buffer.read()")
        query_started = harness.threading.Event()
        release_query = harness.threading.Event()
        all_file_queries = 0

        def query(command, **kwargs):
            nonlocal all_file_queries
            if "-i" in command:
                return Mock(returncode=1, stdout="", stderr="")
            all_file_queries += 1
            if all_file_queries <= 2:
                return Mock(returncode=0, stdout="COMMAND PID FD\nhelper 1 txt\n", stderr="")
            query_started.set()
            if not release_query.wait(timeout=2):
                raise RuntimeError("fixture query was not released")
            return Mock(returncode=1, stdout="", stderr="")

        real_killpg = harness.os.killpg
        with patch.object(harness.subprocess, "run", side_effect=query):
            monitor = harness.RuntimeNetworkMonitor(helper.process)
            helper.monitor = monitor
            try:
                self.assertTrue(query_started.wait(timeout=2))

                def kill_after_query(pid, sig):
                    release_query.set()
                    monitor.thread.join(timeout=2)
                    self.assertFalse(monitor.thread.is_alive())
                    self.assertIsNone(helper.process.poll())
                    real_killpg(pid, sig)

                with patch.object(harness.os, "killpg", side_effect=kill_after_query):
                    helper.force_crash_and_expect_eof()
                self.assertEqual(helper.process.returncode, -harness.signal.SIGKILL)
                self.assertTrue(monitor.interrupted_sigkill_scan)
                self.assertTrue(monitor.sigkill_confirmed)
                self.assertEqual(monitor.scans, 2, "incomplete scan must not count as observation")
            finally:
                release_query.set()
                monitor.thread.join(timeout=2)

    def bare_monitor(self):
        monitor = harness.RuntimeNetworkMonitor.__new__(harness.RuntimeNetworkMonitor)
        monitor.process = Mock(poll=Mock(return_value=None))
        monitor.started = time.monotonic()
        monitor.stop_requested = harness.threading.Event()
        monitor.sigkill_requested = harness.threading.Event()
        monitor.first_scan_completed = harness.threading.Event()
        monitor.sigkill_confirmed = False
        monitor.interrupted_sigkill_scan = False
        monitor.scans, monitor.network_fd_count = 2, 0
        monitor.error, monitor.stopped = None, False
        monitor.thread = Mock(is_alive=Mock(return_value=False))
        return monitor

    def test_empty_query_without_intentional_crash_remains_failure(self):
        monitor = self.bare_monitor()
        monitor.request_stop()
        with patch.object(harness.subprocess, "run", return_value=Mock(returncode=1, stdout="", stderr="")):
            monitor._scan()
        with self.assertRaisesRegex(harness.TestFailure, "could not inspect"):
            monitor.stop()

    def test_boundary_requires_confirmed_reaped_sigkill(self):
        for confirmed, returncode in ((False, None), (False, -9), (True, None), (True, 0), (True, -15)):
            with self.subTest(confirmed=confirmed, returncode=returncode):
                monitor = self.bare_monitor()
                monitor.request_stop_for_sigkill()
                with patch.object(harness.subprocess, "run", return_value=Mock(returncode=1, stdout="", stderr="")):
                    monitor._scan()
                monitor.sigkill_confirmed = confirmed
                monitor.process.poll.return_value = returncode
                with self.assertRaisesRegex(harness.TestFailure, "could not verify"):
                    monitor.stop()

    def test_sigkill_confirmation_rejects_a_live_or_differently_exited_process(self):
        for returncode in (None, 0, -15):
            monitor = self.bare_monitor()
            monitor.process.poll.return_value = returncode
            with self.assertRaisesRegex(harness.TestFailure, "SIGKILL was not reaped"):
                monitor.confirm_sigkill()
            self.assertFalse(monitor.sigkill_confirmed)

    def test_boundary_preserves_prior_errors_and_minimum_scan_requirement(self):
        for prior_error, scans, expected in (("prior observation failure", 2, "prior observation failure"),
                                             (None, 1, "fewer than two")):
            monitor = self.bare_monitor()
            monitor.error, monitor.scans = prior_error, scans
            monitor.request_stop_for_sigkill()
            with patch.object(harness.subprocess, "run", return_value=Mock(returncode=1, stdout="", stderr="")):
                monitor._scan()
            monitor.process.poll.return_value = -9
            monitor.confirm_sigkill()
            with self.assertRaisesRegex(harness.TestFailure, expected):
                monitor.stop()

    def test_boundary_never_accepts_stderr_or_other_query_failures(self):
        for returncode, stdout, stderr in ((1, "", "denied"), (2, "", ""), (0, "", ""),
                                            (1, "unexpected output", "")):
            with self.subTest(returncode=returncode, stdout=stdout, stderr=stderr):
                monitor = self.bare_monitor()
                monitor.request_stop_for_sigkill()
                monitor.process.poll.return_value = -9
                monitor.confirm_sigkill()
                with patch.object(harness.subprocess, "run", return_value=Mock(
                        returncode=returncode, stdout=stdout, stderr=stderr)):
                    monitor._scan()
                with self.assertRaisesRegex(harness.TestFailure, "could not inspect"):
                    monitor.stop()

    def test_inflight_query_timeout_remains_failure_at_boundary(self):
        monitor = self.bare_monitor()

        def timeout_query(*args, **kwargs):
            monitor.request_stop_for_sigkill()
            raise subprocess.TimeoutExpired(args[0], 5)

        with patch.object(harness.subprocess, "run", side_effect=timeout_query):
            monitor._run()
        monitor.process.poll.return_value = -9
        monitor.confirm_sigkill()
        with self.assertRaisesRegex(harness.TestFailure, "query timed out"):
            monitor.stop()

    def test_failed_kill_cannot_confirm_or_accept_an_interrupted_scan(self):
        helper = self.make_helper("import sys; sys.stdin.buffer.read()")
        monitor = self.bare_monitor()
        monitor.process = helper.process
        helper.monitor = monitor

        def failed_kill(*args):
            with patch.object(harness.subprocess, "run", return_value=Mock(returncode=1, stdout="", stderr="")):
                monitor._scan()
            raise PermissionError("injected SIGKILL failure")

        with patch.object(harness.os, "killpg", side_effect=failed_kill):
            with self.assertRaisesRegex(PermissionError, "SIGKILL failure"):
                helper.force_crash_and_expect_eof()
        self.assertIsNone(helper.process.poll())
        self.assertFalse(monitor.sigkill_confirmed)
        with self.assertRaisesRegex(harness.TestFailure, "could not verify"):
            monitor.stop()

    def test_inflight_empty_network_query_does_not_count_as_a_completed_scan(self):
        monitor = self.bare_monitor()

        def query(command, **kwargs):
            if "-i" not in command:
                return Mock(returncode=0, stdout="COMMAND PID FD\nhelper 1 txt\n", stderr="")
            monitor.request_stop_for_sigkill()
            return Mock(returncode=1, stdout="", stderr="")

        with patch.object(harness.subprocess, "run", side_effect=query):
            monitor._scan()
        monitor.process.poll.return_value = -9
        monitor.confirm_sigkill()
        monitor.stop()
        self.assertTrue(monitor.interrupted_sigkill_scan)
        self.assertEqual(monitor.scans, 2)
        self.assertEqual(monitor.network_fd_count, 0)

    def test_inflight_network_query_errors_remain_failure_at_boundary(self):
        for returncode, stderr in ((1, "denied"), (2, "")):
            with self.subTest(returncode=returncode, stderr=stderr):
                monitor = self.bare_monitor()

                def query(command, **kwargs):
                    if "-i" not in command:
                        return Mock(returncode=0, stdout="COMMAND PID FD\nhelper 1 txt\n", stderr="")
                    monitor.request_stop_for_sigkill()
                    monitor.process.poll.return_value = -9
                    monitor.confirm_sigkill()
                    return Mock(returncode=returncode, stdout="", stderr=stderr)

                with patch.object(harness.subprocess, "run", side_effect=query):
                    monitor._scan()
                with self.assertRaisesRegex(harness.TestFailure, "failed closed"):
                    monitor.stop()

    def test_inflight_network_rows_remain_failure_at_boundary(self):
        monitor = self.bare_monitor()

        def query(command, **kwargs):
            if "-i" not in command:
                return Mock(returncode=0, stdout="COMMAND PID FD\nhelper 1 txt\n", stderr="")
            monitor.request_stop_for_sigkill()
            return Mock(returncode=0, stdout="COMMAND PID FD\nhelper 1 TCP\n", stderr="")

        with patch.object(harness.subprocess, "run", side_effect=query):
            monitor._scan()
        monitor.process.poll.return_value = -9
        monitor.confirm_sigkill()
        with self.assertRaisesRegex(harness.TestFailure, "network file descriptor"):
            monitor.stop()
        self.assertEqual(monitor.network_fd_count, 1)


class CleanShutdownObservationTests(unittest.TestCase):
    def run_shutdown_case(self, version, observation_error=None):
        events = []
        helper = harness.Helper.__new__(harness.Helper)
        helper.version = version
        process = Mock(pid=123, returncode=None)
        process.poll.side_effect = lambda: process.returncode
        helper.process = process
        helper.input = Mock()
        helper.input.close.side_effect = lambda: events.append("close input")
        monitor = Mock()
        helper.monitor = monitor
        terminal_requested = False
        sent = None

        def stop():
            events.append("observe and join")
            if observation_error is not None:
                raise observation_error
            # Reproduce the observer losing its target during an intentional
            # exit. It must finish while the helper still accepts requests.
            if terminal_requested:
                raise harness.TestFailure("runtime network monitor could not inspect the owned helper")

        monitor.stop.side_effect = stop

        def send(frame):
            nonlocal terminal_requested, sent
            sent = frame
            if frame.operation == harness.SHUTDOWN:
                if frame.payload or frame.generation:
                    self.assertIsNotNone(helper.monitor, "malformed shutdown escaped observation")
                    events.append("malformed shutdown")
                else:
                    terminal_requested = True
                    events.append("valid shutdown")
            else:
                self.assertEqual(frame.operation, harness.TRANSCRIBE)
                self.assertIsNotNone(helper.monitor, "inference escaped observation")
                events.append("transcribe")

        def read(timeout=5.0):
            self.assertEqual(timeout, harness.inference_timeout() if sent.operation == harness.TRANSCRIBE else 5.0)
            if sent.operation == harness.TRANSCRIBE:
                events.append("result")
                operation, payload = harness.RESULT, b'{"transcription": []}'
            elif sent.payload or sent.generation:
                events.append("error acknowledgement")
                operation = harness.ERROR
                payload = harness.struct.pack(">IHHQ", 1, harness.SHUTDOWN, 0, 0xFFFFFFFFFFFFFFFF)
            else:
                events.append("stopped acknowledgement")
                operation, payload = harness.STOPPED, b""
            return harness.Frame(operation, sent.request_id, sent.generation, payload)

        def wait(timeout):
            self.assertEqual(timeout, 5.0)
            events.append("reap")
            process.returncode = 0
            return 0

        helper.send = send
        helper.read = read  # Keep Helper.expect and its correlation checks real.
        process.wait.side_effect = wait
        terminate = helper.terminate

        def cleanup():
            events.append("cleanup")
            terminate()

        helper.terminate = cleanup
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(harness.Helper, "__new__", return_value=helper))
            stack.enter_context(patch.object(harness.Helper, "__init__", return_value=None))
            stack.enter_context(patch.object(harness, "one_shot_configuration", return_value=b""))
            stack.enter_context(patch.object(harness, "start_stream", side_effect=lambda *_: events.append("start stream")))
            stack.enter_context(patch.object(harness.os, "killpg", side_effect=lambda *_: events.append("cleanup kill")))
            function = harness.test_v1_compatibility if version == harness.VERSION_1 else harness.test_shutdown_validation
            try:
                function(Path("helper"), Path("model"), Path("audio"), b"")
            finally:
                self.events = events
        return events

    def test_v1_observation_covers_result_and_joins_before_clean_shutdown(self):
        events = self.run_shutdown_case(harness.VERSION_1)
        self.assertEqual(events, ["transcribe", "result", "observe and join", "valid shutdown",
                                  "stopped acknowledgement", "close input", "reap", "cleanup", "reap"])

    def test_v2_invalid_shutdowns_stay_observed_before_valid_terminal_request(self):
        events = self.run_shutdown_case(harness.VERSION_2)
        self.assertEqual(events, ["malformed shutdown", "error acknowledgement", "start stream",
                                  "malformed shutdown", "error acknowledgement", "observe and join",
                                  "valid shutdown", "stopped acknowledgement", "close input", "reap", "cleanup", "reap"])

    def test_failed_observation_never_sends_valid_shutdown_and_preserves_cleanup(self):
        for version in (harness.VERSION_1, harness.VERSION_2):
            with self.subTest(version=version):
                failure = harness.TestFailure("earlier observation failure")
                with self.assertRaises(harness.TestFailure) as raised:
                    self.run_shutdown_case(version, observation_error=failure)
                self.assertIs(raised.exception, failure)
                self.assertNotIn("valid shutdown", self.events)
                self.assertEqual(self.events[-3:], ["cleanup", "cleanup kill", "reap"])


class CompletedFinalCrashOrderingTests(unittest.TestCase):
    def run_completed_final(self, events, observation_error=None):
        helper = harness.Helper.__new__(harness.Helper)
        process = Mock(pid=123, returncode=None)
        process.poll.side_effect = lambda: process.returncode

        def reap(timeout):
            if process.returncode is None:
                events.append("reap")
                process.returncode = -harness.signal.SIGKILL
            return process.returncode

        process.wait.side_effect = reap
        helper.process = process
        helper.output = Mock()
        helper.output.read.side_effect = lambda: events.append("EOF") or b""
        helper.monitor = Mock()

        def stop_monitor():
            events.append("monitor stop/join")
            self.assertIsNone(process.poll(), "completed-final monitor joined after helper exit")
            if observation_error is not None:
                raise observation_error

        helper.monitor.stop.side_effect = stop_monitor
        helper.send = Mock()

        def accept_final(kind, *_args, **_kwargs):
            self.assertEqual(kind, harness.FINAL_RESULT)
            events.append("final")
            return Mock(payload=b'{"transcription": []}')

        helper.expect = Mock(side_effect=accept_final)
        helper.expect_no_frame = Mock(side_effect=lambda: events.append("no extra frame"))
        force_crash = helper.force_crash_and_expect_eof
        terminate = helper.terminate

        def crash():
            events.append("intentional crash")
            force_crash()

        def cleanup():
            events.append("cleanup")
            terminate()

        helper.force_crash_and_expect_eof = crash
        helper.terminate = cleanup

        def kill(pid, signal):
            self.assertEqual((pid, signal), (process.pid, harness.signal.SIGKILL))
            events.append("kill")

        with contextlib.ExitStack() as stack:
            # Keep the real Helper class and crash/cleanup methods; replace only
            # construction and protocol I/O with a completed-final fixture.
            stack.enter_context(patch.object(harness.Helper, "__new__", return_value=helper))
            stack.enter_context(patch.object(harness.Helper, "__init__", return_value=None))
            for name in ("start_stream", "append_all", "finish_payload"):
                stack.enter_context(patch.object(harness, name, return_value=b""))
            stack.enter_context(patch.object(harness.os, "killpg", side_effect=kill))
            stack.enter_context(patch.object(harness.select, "select", return_value=([1], [], [])))
            stack.enter_context(patch.object(harness.Helper, "canary_scanned_surface_count", 0))
            harness.test_crash_after_final(Path("helper"), Path("model"), Path("audio"), b"")
        self.assertEqual(process.returncode, -harness.signal.SIGKILL)

    def test_completed_final_joins_observation_before_kill_and_checks_eof(self):
        events = []
        self.run_completed_final(events)
        self.assertEqual(events, ["final", "no extra frame", "monitor stop/join",
                                  "intentional crash", "kill", "reap", "EOF", "cleanup"])

    def test_observation_failure_remains_primary_and_finally_reaps_helper(self):
        events = []
        failure = harness.TestFailure("runtime network monitor could not inspect the owned helper")
        with self.assertRaises(harness.TestFailure) as raised:
            self.run_completed_final(events, observation_error=failure)
        self.assertIs(raised.exception, failure)
        self.assertEqual(events, ["final", "no extra frame", "monitor stop/join",
                                  "cleanup", "kill", "reap"])


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

    def run_gate(self, protocol_status, diagnostic_status, allocation_status=0, vad_status=0,
                 cancellation_status=0, backend_status=0):
        (self.scripts / "ci/test-backend-discovery.py").write_text(
            "import json, sys\nprint('backend-check-called')\n"
            "print('backend-check-args: ' + json.dumps(sys.argv[1:]))\n"
            f"raise SystemExit({backend_status})\n")
        (self.scripts / "ci/test-vendor-allocation-failures.py").write_text(
            f"print('allocation-check-called')\nraise SystemExit({allocation_status})\n")
        (self.scripts / "ci/test-native-cancellation.py").write_text(
            f"print('cancellation-check-called')\nraise SystemExit({cancellation_status})\n")
        (self.scripts / "test-whisper-runtime-helper-v2.sh").write_text(f"exit {protocol_status}\n")
        (self.scripts / "ci/diagnose-runtime-inference.py").write_text(
            "import sys\nprint('stream-called' if '--vad-model' in sys.argv else 'diagnostic-called')\n"
            f"raise SystemExit({diagnostic_status})\n")
        (self.scripts / "ci/diagnose-vad-runtime.py").write_text(
            f"print('vad-called')\nraise SystemExit({vad_status})\n")
        return subprocess.run(["bash", str(self.scripts / "ci/runtime-checks.sh"), "--root",
                               str(self.runtime), "--output", str(self.root / "output")],
                              env=self.environment, capture_output=True, text=True)

    def test_backend_discovery_failure_stops_runtime_gate(self):
        result = self.run_gate(17, 0, backend_status=37)
        self.assertEqual(result.returncode, 37, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("backend-check-called"), 1)
        arguments = next(line.removeprefix("backend-check-args: ")
                         for line in result.stdout.splitlines()
                         if line.startswith("backend-check-args: "))
        self.assertEqual(json.loads(arguments), [
            "--whisper-root", "staged-source", "--build-dir", str(self.root / "output/build-steno"),
        ])
        self.assertNotIn("allocation-check-called", result.stdout)
        self.assertNotIn("cancellation-check-called", result.stdout)
        self.assertNotIn("==> helper-protocol", result.stdout)
        self.assertNotIn("diagnostic-called", result.stdout)
        self.assertNotIn("unexpected-later-check", result.stdout)

    def test_allocation_failure_stops_runtime_gate(self):
        result = self.run_gate(17, 0, allocation_status=29)
        self.assertEqual(result.returncode, 29, result.stdout + result.stderr)
        self.assertIn("allocation-check-called", result.stdout)
        self.assertNotIn("==> helper-protocol", result.stdout)
        self.assertNotIn("diagnostic-called", result.stdout)

    def test_cancellation_failure_stops_runtime_gate(self):
        result = self.run_gate(17, 0, cancellation_status=31)
        self.assertEqual(result.returncode, 31, result.stdout + result.stderr)
        self.assertIn("cancellation-check-called", result.stdout)
        self.assertNotIn("==> helper-protocol", result.stdout)
        self.assertNotIn("diagnostic-called", result.stdout)

    def test_successful_diagnostic_preserves_original_failure(self):
        result = self.run_gate(17, 0)
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("diagnostic-called"), 1)
        self.assertNotIn("unexpected-later-check", result.stdout)

    def test_failed_vad_comparison_preserves_original_protocol_failure(self):
        result = self.run_gate(17, 0, vad_status=29)
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("vad-called"), 1)
        self.assertEqual(result.stdout.count("stream-called"), 1)

    def test_failed_diagnostic_preserves_original_failure(self):
        result = self.run_gate(17, 23)
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("diagnostic-called"), 1)

    def test_passing_protocol_does_not_run_diagnostic(self):
        result = self.run_gate(0, 0)
        self.assertNotIn("diagnostic-called", result.stdout)
        self.assertNotIn("vad-called", result.stdout)
        self.assertNotIn("stream-called", result.stdout)
        self.assertIn("invalid runtime receipt", result.stderr)


if __name__ == "__main__":
    unittest.main()
