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


def run(helper_path: Path, model: Path, audio: Path) -> int:
    started = time.monotonic()
    helper = None
    observer = None
    stop = threading.Event()
    phase = "fixture"
    outcome = "failed"

    def deadline_expired(_signum, _frame):
        raise TimeoutError("diagnostic ceiling reached")

    previous_handler = signal.signal(signal.SIGALRM, deadline_expired)
    signal.setitimer(signal.ITIMER_REAL, CEILING_SECONDS)
    # The work deadline covers fixture/load/inference/shutdown. Bounded process
    # and observer cleanup can follow it; it is not a total-process time claim.
    emit("start", workCeilingSeconds=CEILING_SECONDS, qualification="diagnostic-only",
         logicalCPUCount=os.cpu_count(), requestedThreadCount=REQUESTED_THREAD_COUNT)
    try:
        harness.read_public_audio_fixture(audio)
        phase = "load"
        helper = harness.Helper(helper_path, model, harness.VERSION_1)
        expected_backend = "cpu" if os.environ.get("GGML_METAL_DEVICES") == "0" else "metal"
        harness.require(helper.observed_backend == expected_backend, "diagnostic backend mismatch")
        emit("ready", elapsedSeconds=round(time.monotonic() - started, 3),
             observedBackend=helper.observed_backend)
        observer = threading.Thread(target=observe_process,
                                    args=(helper.process.pid, stop, started), daemon=True)
        observer.start()
        phase = "inference"
        request_id = uuid.uuid4().bytes
        inference_started = time.monotonic()
        helper.send(harness.Frame(harness.TRANSCRIBE, request_id, 7,
                                  harness.one_shot_configuration(audio, threads=REQUESTED_THREAD_COUNT)))
        response = helper.expect(harness.RESULT, request_id, 7,
                                 timeout=max(0.001, CEILING_SECONDS - (time.monotonic() - started)))
        harness.require_rich_result(response.payload)
        emit("result", inferenceSeconds=round(time.monotonic() - inference_started, 3),
             elapsedSeconds=round(time.monotonic() - started, 3))
        phase = "shutdown"
        helper.shutdown()
        outcome = "completed"
    except Exception as error:
        # Exception text can contain supplied paths; the phase and type suffice.
        emit("failure", phase=phase, errorType=type(error).__name__,
             elapsedSeconds=round(time.monotonic() - started, 3))
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
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
    args = parser.parse_args()
    return run(args.helper, args.model, args.audio)


if __name__ == "__main__":
    raise SystemExit(main())
