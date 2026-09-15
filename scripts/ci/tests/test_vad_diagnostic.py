"""Checks for the failure-only VAD comparison; no models or inference required."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import wave

spec = importlib.util.spec_from_file_location(
    "vad_diagnostic", Path(__file__).resolve().parents[1] / "diagnose-vad-runtime.py")
diagnostic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostic)


class VADDiagnosticTests(unittest.TestCase):
    def test_exact_cpu_command_uses_verified_flags(self):
        self.assertEqual(diagnostic.vad_command(Path("vad"), Path("model"), Path("jfk.wav"), 3),
                         ["vad", "-vm", "model", "-f", "jfk.wav", "-t", "3"])

    def test_real_timeout_kills_and_reaps_owned_process(self):
        result, output = diagnostic.run_owned(
            [sys.executable, "-u", "-c", "import os,time; print(os.getpid()); time.sleep(60)"], 0.2)
        self.assertEqual(result["failure"], "timeout")
        self.assertEqual(result["exitCode"], -9)
        self.assertEqual(result["cleanupErrors"], [])
        with self.assertRaises(ProcessLookupError):
            os.kill(int(output.strip()), 0)

    def test_cleanup_error_does_not_replace_timeout_and_child_is_reaped(self):
        process = Mock(pid=1234, returncode=-9)
        process.communicate.side_effect = [subprocess.TimeoutExpired("vad", 60), ("", None)]
        with patch.object(diagnostic.subprocess, "Popen", return_value=process), \
             patch.object(diagnostic.os, "killpg", side_effect=PermissionError):
            result, _ = diagnostic.run_owned(["vad"], 60)
        self.assertEqual(result["failure"], "timeout")
        self.assertEqual(result["cleanupErrors"], ["PermissionError"])
        process.kill.assert_called_once()
        self.assertEqual(process.communicate.call_args_list[-1].kwargs, {"timeout": 5})

    def test_first_trial_failure_is_preserved_and_second_trial_runs(self):
        with tempfile.TemporaryDirectory() as temporary:
            audio = Path(temporary) / "jfk.wav"
            with wave.open(str(audio), "wb") as fixture:
                fixture.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                fixture.writeframes(b"\0\0" * 16000)
            success = {"exitCode": 0, "failure": None, "cleanupErrors": []}
            failure = {"exitCode": -9, "failure": "timeout", "cleanupErrors": []}
            with patch.object(diagnostic, "available_cpu_count", return_value=3), \
                 patch.object(diagnostic, "run_owned", side_effect=[
                     (success, ""), (success, "--vad-model --file --threads"),
                     (failure, ""), (success, "Detected 1 speech segments:")]) as run, \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(diagnostic.run(Path("build"), Path("model"), audio), 1)
            self.assertEqual(run.call_args_list[2].args[0][-2:], ["-t", "4"])
            self.assertEqual(run.call_args_list[3].args[0][-2:], ["-t", "3"])
            self.assertEqual([call.args[1] for call in run.call_args_list], [120, 10, 60, 60])

    def test_arbitrary_output_and_paths_are_not_reported(self):
        self.assertEqual(diagnostic.public_vad_lines(
            "model=/private/example\nprivate text\nDetected 1 speech segments:\n"
            "Speech segment 0: start = 0.00, end = 11.00"),
            ["Detected 1 speech segments:", "Speech segment 0: start = 0.00, end = 11.00"])


if __name__ == "__main__":
    unittest.main()
