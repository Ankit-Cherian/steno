#!/usr/bin/env python3
"""Bounded public-fixture timing evidence after a failed runtime protocol gate.

This is diagnostic evidence only. The caller preserves the original gate failure.
Use the production protocol harness, including its network and backend checks.
Only numeric process statistics and structural completion are logged.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time
import uuid


spec = importlib.util.spec_from_file_location(
    "runtime_protocol_diagnostic", Path(__file__).resolve().parents[1] / "test-whisper-runtime-helper-v2.py"
)
harness = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = harness
spec.loader.exec_module(harness)

CEILING_SECONDS = 180
REQUESTED_THREAD_COUNT = 4


def emit(event: str, **fields: object) -> None:
    print(json.dumps({"event": event, **fields}, sort_keys=True), flush=True)


def sample_process(pid: int) -> dict[str, object]:
    # Deliberately omit command arguments, executable paths, and user identity.
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "%cpu=,time=,rss=,state="],
        capture_output=True, text=True, timeout=2, check=False,
    )
    fields = result.stdout.split()
    if result.returncode != 0 or len(fields) != 4:
        return {"available": False}
    cpu, cpu_time, rss, state = fields
    if not (re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", cpu)
            and re.fullmatch(r"[0-9:.\-]+", cpu_time)
            and rss.isdigit() and re.fullmatch(r"[A-Za-z+<>N-]+", state)):
        return {"available": False}
    return {"available": True, "cpuPercent": float(cpu), "cpuTime": cpu_time,
            "residentKB": int(rss), "state": state}


def observe_process(pid: int, stop: threading.Event, started: float) -> None:
    while not stop.is_set():
        try:
            stats = sample_process(pid)
        except (OSError, subprocess.TimeoutExpired):
            stats = {"available": False}
        emit("process", elapsedSeconds=round(time.monotonic() - started, 3), **stats)
        stop.wait(5)


def run(helper_path: Path, model: Path, audio: Path, vad_model: Path | None = None) -> int:
    started = time.monotonic()
    helper = None
    observer = None
    stop = threading.Event()
    phase = "fixture"
    outcome = "failed"
    read_timeout_seconds = None
    previous_vad_model = harness.VAD_MODEL

    def deadline_expired(_signum, _frame):
        raise TimeoutError("diagnostic ceiling reached")

    previous_handler = signal.signal(signal.SIGALRM, deadline_expired)
    signal.setitimer(signal.ITIMER_REAL, CEILING_SECONDS)
    # The work deadline covers fixture/load/inference/shutdown. Bounded process
    # and observer cleanup can follow it; it is not a total-process time claim.
    emit("start", workCeilingSeconds=CEILING_SECONDS, qualification="diagnostic-only",
         logicalCPUCount=os.cpu_count(),
         requestedThreadCount=harness.STREAM_THREAD_COUNT if vad_model is not None else REQUESTED_THREAD_COUNT,
         protocolVersion=2 if vad_model is not None else 1, vadEnabled=vad_model is not None)
    try:
        fixture = harness.read_public_audio_fixture(audio)
        if vad_model is not None:
            harness.VAD_MODEL = vad_model.resolve()
        phase = "load"
        helper = harness.Helper(helper_path, model,
                                harness.VERSION_2 if vad_model is not None else harness.VERSION_1)
        expected_backend = "cpu" if os.environ.get("GGML_METAL_DEVICES") == "0" else "metal"
        harness.require(helper.observed_backend == expected_backend, "diagnostic backend mismatch")
        emit("ready", elapsedSeconds=round(time.monotonic() - started, 3),
             observedBackend=helper.observed_backend)
        observer = threading.Thread(target=observe_process,
                                    args=(helper.process.pid, stop, started), daemon=True)
        observer.start()
        request_id = uuid.uuid4().bytes
        if vad_model is not None:
            phase = "stream-start"
            harness.start_stream(helper, request_id, 7)
            phase = "stream-append"
            harness.append_all(helper, request_id, 7, fixture.pcm)
            phase = "stream-finish"
            inference_started = time.monotonic()
            helper.send(harness.Frame(harness.STREAM_FINISH, request_id, 7,
                                      harness.finish_payload(helper, audio, fixture.pcm)))
            response_operation = harness.FINAL_RESULT
        else:
            phase = "inference"
            inference_started = time.monotonic()
            helper.send(harness.Frame(harness.TRANSCRIBE, request_id, 7,
                                      harness.one_shot_configuration(audio, threads=REQUESTED_THREAD_COUNT)))
            response_operation = harness.RESULT
        read_timeout_seconds = max(0.001, CEILING_SECONDS - (time.monotonic() - started))
        if vad_model is not None:
            emit("request", phase=phase, readTimeoutSeconds=round(read_timeout_seconds, 3),
                 sampleCount=fixture.observed_sample_count)
        response = helper.expect(response_operation, request_id, 7, timeout=read_timeout_seconds)
        harness.require_rich_result(response.payload)
        emit("result", inferenceSeconds=round(time.monotonic() - inference_started, 3),
             elapsedSeconds=round(time.monotonic() - started, 3))
        phase = "shutdown"
        helper.shutdown()
        outcome = "completed"
    except Exception as error:
        # Exception text can contain supplied paths; the phase and type suffice.
        failure_kind = ("work-ceiling" if isinstance(error, TimeoutError) else
                        "read-timeout" if isinstance(error, harness.TestFailure)
                        and str(error).startswith("timed out reading ") else "harness-failure")
        emit("failure", phase=phase, errorType=type(error).__name__, failureKind=failure_kind,
             readTimeoutSeconds=round(read_timeout_seconds, 3) if read_timeout_seconds is not None else None,
             elapsedSeconds=round(time.monotonic() - started, 3))
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        harness.VAD_MODEL = previous_vad_model
        stop.set()
        if observer is not None:
            observer.join(timeout=3)
        if helper is not None:
            try:
                helper.terminate()
            except Exception as error:
                outcome = "failed"
                emit("cleanupFailure", errorType=type(error).__name__)
        emit("finished", outcome=outcome, elapsedSeconds=round(time.monotonic() - started, 3),
             networkScans=harness.RuntimeNetworkMonitor.scan_count,
             networkCheckedProcesses=harness.RuntimeNetworkMonitor.checked_process_count,
             observedNetworkFDs=harness.RuntimeNetworkMonitor.observed_network_fd_count)
    return 0 if outcome == "completed" else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--vad-model", type=Path,
                        help="Diagnose the full public fixture through v2 streaming with VAD")
    args = parser.parse_args()
    return run(args.helper, args.model, args.audio, args.vad_model)


if __name__ == "__main__":
    raise SystemExit(main())
