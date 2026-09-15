#!/usr/bin/env python3
"""Bounded CPU VAD comparison after a failed protocol gate; never a passing gate."""

import argparse
import json
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import time
import wave


INFERENCE_SECONDS = 60


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}, sort_keys=True), flush=True)


def available_cpu_count():
    if hasattr(os, "sched_getaffinity"):
        return max(1, len(os.sched_getaffinity(0)))
    counter = getattr(os, "process_cpu_count", os.cpu_count)
    return max(1, counter() or 1)


def run_owned(command, timeout):
    """Bound work, then kill/reap only this process group; retain primary failure."""
    started = time.monotonic()
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, start_new_session=True)
    failure = None
    cleanup_errors = []
    output = ""
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        failure = "timeout"
    except Exception as error:
        failure = type(error).__name__
    finally:
        if failure is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except Exception as error:
                cleanup_errors.append(type(error).__name__)
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
                except Exception as fallback_error:
                    cleanup_errors.append(type(fallback_error).__name__)
            try:
                output, _ = process.communicate(timeout=5)
            except Exception as error:
                cleanup_errors.append(type(error).__name__)
                # A descendant might retain the output pipe after parent exit.
                process.stdout.close()
                try:
                    process.wait(timeout=5)
                except Exception as wait_error:
                    cleanup_errors.append(type(wait_error).__name__)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return {
        "exitCode": process.returncode,
        "failure": failure,
        "cleanupErrors": cleanup_errors,
        "elapsedSeconds": round(time.monotonic() - started, 3),
        "childUserCPUSeconds": round(after.ru_utime - usage.ru_utime, 3),
        "childSystemCPUSeconds": round(after.ru_stime - usage.ru_stime, 3),
    }, output


def vad_command(executable, model, audio, threads):
    # This upstream CLI defaults to CPU VAD. Do not pass --use-gpu.
    return [str(executable), "-vm", str(model), "-f", str(audio), "-t", str(threads)]


def public_vad_lines(output):
    # Preserve numeric VAD evidence, never raw paths or arbitrary subprocess text.
    patterns = [r"Detected \d+ speech segments:",
                r"Speech segment \d+: start = [0-9.]+, end = [0-9.]+",
                r"whisper_vad_detect_speech: vad time = [0-9.]+ ms processing \d+ samples"]
    return [line for line in output.splitlines()
            if any(re.fullmatch(pattern, line) for pattern in patterns)]


def run(build_dir, model, audio):
    logical = os.cpu_count()
    available = available_cpu_count()
    with wave.open(str(audio), "rb") as fixture:
        if (fixture.getnchannels(), fixture.getsampwidth(), fixture.getframerate()) != (1, 2, 16000):
            raise ValueError("expected mono 16-bit 16-kHz public fixture")
        duration = fixture.getnframes() / fixture.getframerate()
    emit("start", qualification="diagnostic-only", logicalCPUCount=logical,
         availableCPUCount=available, audioDurationSeconds=duration,
         inferenceCeilingSeconds=INFERENCE_SECONDS, cleanupMayFollowDeadline=True)
    build, _ = run_owned(["cmake", "--build", str(build_dir), "--target",
                          "whisper-vad-speech-segments", "-j", "2"], 120)
    emit("build", **build)
    if build["exitCode"] != 0 or build["failure"] or build["cleanupErrors"]:
        return 1
    executable = build_dir / "bin/whisper-vad-speech-segments"
    help_result, help_text = run_owned([str(executable), "--help"], 10)
    flags_verified = all(flag in help_text for flag in ("--vad-model", "--file", "--threads"))
    emit("help", flagsVerified=flags_verified, **help_result)
    if (help_result["exitCode"] != 0 or help_result["failure"]
            or help_result["cleanupErrors"] or not flags_verified):
        return 1
    failed = False
    for label, threads in [("four-threads", 4), ("cpu-count-capped", min(4, available))]:
        emit("trial-start", trial=label, requestedThreads=threads)
        result, output = run_owned(vad_command(executable, model, audio, threads), INFERENCE_SECONDS)
        emit("trial-result", trial=label, requestedThreads=threads,
             logicalCPUCount=logical, availableCPUCount=available,
             audioDurationSeconds=duration, vadEvidence=public_vad_lines(output), **result)
        failed |= result["exitCode"] != 0 or result["failure"] is not None or bool(result["cleanupErrors"])
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--audio", required=True, type=Path)
    args = parser.parse_args()
    try:
        return run(args.build_dir, args.model, args.audio)
    except Exception as error:
        emit("failure", errorType=type(error).__name__)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
