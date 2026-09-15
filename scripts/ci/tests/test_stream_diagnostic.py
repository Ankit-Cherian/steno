"""The optional diagnostic exercises the same VAD stream as the failed gate."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "diagnose-runtime-inference.py"
spec = importlib.util.spec_from_file_location("stream_diagnostic_test", SCRIPT)
diagnostic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostic)


class StreamDiagnosticTests(unittest.TestCase):
    def run_diagnostic(self, read_error=None, cleanup_error=None, append_error=None):
        helper = Mock(observed_backend="cpu")
        helper.expect.return_value.payload = b'{"transcription": []}'
        helper.expect.side_effect = read_error
        helper.terminate.side_effect = cleanup_error
        helper.stream_configuration.return_value = b"configuration"
        fixture = Mock(pcm=b"\0\0" * 32, observed_sample_count=32)
        output = io.StringIO()
        previous_vad = diagnostic.harness.VAD_MODEL
        with patch.object(diagnostic.harness, "Helper", return_value=helper) as constructor, \
                patch.object(diagnostic.harness, "read_public_audio_fixture", return_value=fixture), \
                patch.object(diagnostic.harness, "start_stream") as start, \
                patch.object(diagnostic.harness, "append_all", side_effect=append_error) as append, \
                patch.object(diagnostic.threading, "Thread"), \
                patch.dict(os.environ, {"GGML_METAL_DEVICES": "0"}), \
                contextlib.redirect_stdout(output):
            status = diagnostic.run(Path("/private/helper"), Path("/private/model"),
                                    Path("/private/audio"), Path("/private/vad"))
        self.assertIs(diagnostic.harness.VAD_MODEL, previous_vad)
        self.assertNotIn("/private/", output.getvalue())
        self.assertNotIn("transcription", output.getvalue())
        rows = [json.loads(line) for line in output.getvalue().splitlines()]
        return status, helper, constructor, start, append, fixture, rows

    def test_vad_mode_sends_the_full_fixture_through_v2_finish(self):
        status, helper, constructor, start, append, fixture, rows = self.run_diagnostic()
        self.assertEqual(status, 0)
        self.assertEqual(constructor.call_args.args[2], diagnostic.harness.VERSION_2)
        start.assert_called_once()
        self.assertEqual(append.call_args.args[-1], fixture.pcm)
        helper.send.assert_called_once()
        frame = helper.send.call_args.args[0]
        self.assertEqual(frame.operation, diagnostic.harness.STREAM_FINISH)
        self.assertEqual(frame.request_id, start.call_args.args[1])
        self.assertEqual(frame.generation, start.call_args.args[2])
        self.assertEqual(helper.expect.call_args.args[0], diagnostic.harness.FINAL_RESULT)
        self.assertLessEqual(helper.expect.call_args.kwargs["timeout"], 180)
        self.assertEqual(rows[0]["requestedThreadCount"], diagnostic.harness.STREAM_THREAD_COUNT)
        self.assertTrue(rows[0]["vadEnabled"])
        request = next(row for row in rows if row["event"] == "request")
        self.assertEqual(request["sampleCount"], 32)
        self.assertEqual(request["phase"], "stream-finish")
        self.assertEqual(rows[-1]["outcome"], "completed")
        helper.shutdown.assert_called_once()
        helper.terminate.assert_called_once()

    def test_read_timeout_is_reported_without_leaking_exception_text(self):
        result = self.run_diagnostic(diagnostic.harness.TestFailure("timed out reading /private/response"))
        status, helper, *_, rows = result
        self.assertEqual(status, 1)
        failure = next(row for row in rows if row["event"] == "failure")
        self.assertEqual(failure["phase"], "stream-finish")
        self.assertEqual(failure["failureKind"], "read-timeout")
        self.assertLessEqual(failure["readTimeoutSeconds"], 180)
        helper.shutdown.assert_not_called()
        helper.terminate.assert_called_once()

    def test_primary_failure_remains_visible_when_cleanup_also_fails(self):
        result = self.run_diagnostic(TimeoutError("/private/timeout"), OSError("/private/cleanup"))
        status, _, *_, rows = result
        self.assertEqual(status, 1)
        failures = [row for row in rows if row["event"] == "failure"]
        self.assertEqual(len(failures), 1)
        self.assertEqual(failures[0]["errorType"], "TimeoutError")
        self.assertEqual(failures[0]["failureKind"], "work-ceiling")
        self.assertEqual(next(row for row in rows if row["event"] == "cleanupFailure")["errorType"], "OSError")
        self.assertEqual(rows[-1]["outcome"], "failed")

    def test_append_failure_does_not_send_finish(self):
        result = self.run_diagnostic(append_error=diagnostic.harness.TestFailure("/private/append"))
        status, helper, *_, rows = result
        self.assertEqual(status, 1)
        helper.send.assert_not_called()
        self.assertEqual(next(row for row in rows if row["event"] == "failure")["phase"], "stream-append")
        helper.terminate.assert_called_once()


if __name__ == "__main__":
    unittest.main()
