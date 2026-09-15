#!/usr/bin/env python3
"""Adversarial protocol tests for the real retained Whisper runtime helper.

The harness talks to the compiled C++ executable over its production framed
stdin/stdout protocol. It uses only the vendored public JFK fixture and a local
Whisper model; transcript content is validated structurally but never printed.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
import platform
import re
import select
import signal
import struct
import subprocess
import sys
import threading
import time
import uuid
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


MAGIC = 0x53545752
VERSION_1 = 1
VERSION_2 = 2
MAXIMUM_PAYLOAD_BYTES = 64 * 1024 * 1024
MAXIMUM_APPEND_SAMPLES = 16 * 1024
FNV1A_OFFSET_BASIS = 14695981039346656037
FNV1A_PRIME = 1099511628211
IDENTITY_SCHEMA = 2
IDENTITY_CAPABILITIES = 0x7F
CURRENT_ASR_CONTEXT_COUNT = 1
PEAK_ASR_CONTEXT_COUNT = 1
RUNTIME_IDENTITY = "real-helper-v2-harness"
MODEL_IDENTITY = "vendored-small-en"
VAD_IDENTITY = "vendored-silero-v6-2"
VAD_MODEL: Path | None = None
PUBLIC_CANARY = b"STENO-PUBLIC-PROTOCOL-CANARY-V1"
RECEIPT_SCHEMA_VERSION = 3
SAMPLE_RATE_HZ = 16_000
CHANNEL_COUNT = 1
SAMPLE_WIDTH_BYTES = 2
STREAM_THREAD_COUNT = 8
PREVIEW_WINDOW_SAMPLES = 12 * SAMPLE_RATE_HZ
MAXIMUM_STREAM_SAMPLES = 12 * 60 * 60 * SAMPLE_RATE_HZ

LOAD = 1
READY = 2
TRANSCRIBE = 3
RESULT = 4
ERROR = 5
SHUTDOWN = 6
STOPPED = 7
CANCELLED = 8
STREAM_START = 9
STREAM_STARTED = 10
AUDIO_APPEND = 11
AUDIO_ACCEPTED = 12
STREAM_DECODE = 13
HYPOTHESIS = 14
STREAM_FINISH = 15
FINAL_RESULT = 16
STREAM_CANCEL = 17


def inference_timeout() -> float:
    # Hosted CPU inference can exceed 30 seconds; device-suppressed runs are
    # protocol diagnostics and do not qualify production Metal performance.
    return 180.0 if os.environ.get("GGML_METAL_DEVICES") == "0" else 30.0


class TestFailure(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise TestFailure(message)


def u32(value: int) -> bytes:
    return struct.pack(">I", value)


def u64(value: int) -> bytes:
    return struct.pack(">Q", value)


def string(value: str) -> bytes:
    encoded = value.encode("utf-8")
    return u32(len(encoded)) + encoded


def optional_string(value: str | None) -> bytes:
    return u32(0xFFFFFFFF) if value is None else string(value)


def identity_payload(vad_identity: str = VAD_IDENTITY) -> bytes:
    return (
        u32(IDENTITY_SCHEMA)
        + u32(IDENTITY_CAPABILITIES)
        + string(RUNTIME_IDENTITY)
        + string(MODEL_IDENTITY)
        + string(vad_identity)
        + u32(CURRENT_ASR_CONTEXT_COUNT)
        + u32(PEAK_ASR_CONTEXT_COUNT)
    )


def stream_configuration(
    vad_model: Path | None = None,
    vad_identity: str | None = None,
    prompt: str | None = None,
    vocabulary_prompt: str | None = None,
) -> bytes:
    if vad_identity is None:
        vad_identity = VAD_IDENTITY
        vad_model = VAD_MODEL
    vad_enabled = vad_model is not None
    flags = 1
    if vad_enabled:
        flags |= 1 << 1
    if vocabulary_prompt:
        flags |= 1 << 2
    payload = [
        u32(STREAM_THREAD_COUNT),
        u32(1),
        u32(1),
        u32(flags),
        string("en"),
        optional_string(prompt),
        optional_string(None),
        optional_string(str(vad_model) if vad_model is not None else None),
        string(vad_identity),
    ]
    if vocabulary_prompt:
        payload.append(string(vocabulary_prompt))
    return b"".join(payload)


def parse_error(payload: bytes) -> tuple[int, int, int | None]:
    require(len(payload) == 16, "correlated v2 Error payload length mismatch")
    category, failed_operation, reserved, raw_discriminator = struct.unpack(">IHHQ", payload)
    require(category in range(1, 6), "correlated v2 Error category was invalid")
    require(reserved == 0, "correlated v2 Error reserved field was nonzero")
    discriminator = None if raw_discriminator == 0xFFFFFFFFFFFFFFFF else raw_discriminator
    return category, failed_operation, discriminator


def require_error(
    frame: Frame,
    category: int,
    failed_operation: int,
    discriminator: int | None = None,
) -> None:
    actual_category, actual_operation, actual_discriminator = parse_error(frame.payload)
    require(actual_category == category, "v2 Error category mismatch")
    require(actual_operation == failed_operation, "v2 Error operation correlation mismatch")
    require(actual_discriminator == discriminator, "v2 Error discriminator mismatch")


def parse_hypothesis(payload: bytes) -> tuple[int, int, int, int, str]:
    require(len(payload) >= 32, "Hypothesis payload was truncated")
    revision, watermark, monotonic_nanos, evidence, text_length = struct.unpack(">QQQII", payload[:32])
    require(evidence in (0, 1, 2), "Hypothesis speech evidence enum was invalid")
    require(text_length <= 1024 * 1024, "Hypothesis text exceeded helper bound")
    require(len(payload) == 32 + text_length, "Hypothesis text length mismatch")
    try:
        text = payload[32:].decode("utf-8")
    except UnicodeDecodeError as error:
        raise TestFailure("Hypothesis text was not UTF-8") from error
    return revision, watermark, monotonic_nanos, evidence, text


def one_shot_configuration(
    audio_path: Path,
    prompt: str | None = None,
    vocabulary_prompt: str | None = None,
    vad_model: Path | None = None,
    threads: int = 4,
    beam_size: int = 1,
    best_of: int = 1,
    suppress_nst: bool = True,
) -> bytes:
    flags = 0
    if suppress_nst:
        flags |= 1 << 0
    if vad_model is not None:
        flags |= 1 << 1
    if vocabulary_prompt:
        flags |= 1 << 2
    payload = [
        u32(threads),
        u32(beam_size),
        u32(best_of),
        u32(flags),
        string(str(audio_path)),
        string("en"),
        optional_string(prompt),
        optional_string(None),
        optional_string(str(vad_model) if vad_model is not None else None),
    ]
    if vocabulary_prompt:
        payload.append(string(vocabulary_prompt))
    return b"".join(payload)


def append_payload(sequence: int, offset: int, pcm: bytes) -> bytes:
    require(len(pcm) > 0 and len(pcm) % 2 == 0, "PCM append must contain complete samples")
    return u64(sequence) + u64(offset) + u32(len(pcm) // 2) + pcm


def fnv1a(data: bytes) -> int:
    result = FNV1A_OFFSET_BASIS
    for byte in data:
        result ^= byte
        result = (result * FNV1A_PRIME) & 0xFFFFFFFFFFFFFFFF
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json_sha256(value: object) -> str:
    encoded = json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def checked_command_output(arguments: tuple[str, ...]) -> str:
    result = subprocess.run(arguments, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def classify_observed_backend(counts: dict[str, int]) -> str:
    observed = {backend for backend in ("cpu", "metal", "unknown") if counts.get(backend, 0) > 0}
    if not observed or observed == {"unknown"}:
        return "unobserved"
    if "unknown" in observed or len(observed) > 1:
        return "mixed"
    return "observed-metal" if observed == {"metal"} else "observed-cpu"


def qualifies_as_production_metal(
    backend: str,
    requested_device_mode: str,
    passed: int,
    expected: int,
) -> bool:
    return (
        backend == "observed-metal"
        and requested_device_mode == "default"
        and expected > 0
        and passed == expected
    )


class RuntimeNetworkMonitor:
    poll_interval_seconds = 0.05
    registry_lock = threading.Lock()
    owned_process_count = 0
    checked_process_count = 0
    scan_count = 0
    observation_duration_ms = 0
    minimum_scan_count_per_process: int | None = None
    observed_network_fd_count = 0

    def __init__(self, process: subprocess.Popen[bytes]):
        self.process = process
        self.started = time.monotonic()
        self.stop_requested = threading.Event()
        self.first_scan_completed = threading.Event()
        self.thread = threading.Thread(target=self._run, name="helper-network-monitor", daemon=True)
        self.scans = 0
        self.network_fd_count = 0
        self.error: str | None = None
        self.stopped = False
        with RuntimeNetworkMonitor.registry_lock:
            RuntimeNetworkMonitor.owned_process_count += 1
        self.thread.start()
        require(
            self.first_scan_completed.wait(timeout=3.0),
            "runtime network monitor did not complete two launch scans",
        )
        if self.error is not None:
            raise TestFailure(self.error)
        require(self.scans >= 2, "runtime network monitor completed fewer than two launch scans")

    def stop(self) -> None:
        if self.stopped:
            if self.error is not None:
                raise TestFailure(self.error)
            return
        self.stopped = True
        self.stop_requested.set()
        self.thread.join(timeout=3.0)
        if self.thread.is_alive() and self.error is None:
            self.error = "runtime network monitor did not terminate"
        duration_ms = round((time.monotonic() - self.started) * 1_000)
        with RuntimeNetworkMonitor.registry_lock:
            RuntimeNetworkMonitor.scan_count += self.scans
            RuntimeNetworkMonitor.observation_duration_ms += duration_ms
            RuntimeNetworkMonitor.observed_network_fd_count += self.network_fd_count
            current_minimum = RuntimeNetworkMonitor.minimum_scan_count_per_process
            RuntimeNetworkMonitor.minimum_scan_count_per_process = (
                self.scans if current_minimum is None else min(current_minimum, self.scans)
            )
            if self.error is None and self.scans >= 2 and self.network_fd_count == 0:
                RuntimeNetworkMonitor.checked_process_count += 1
        if self.error is not None:
            raise TestFailure(self.error)
        require(self.scans >= 2, "runtime network monitor recorded fewer than two lifecycle scans")
        require(self.network_fd_count == 0, "owned helper opened a network file descriptor")

    def _run(self) -> None:
        while not self.stop_requested.is_set() and self.process.poll() is None:
            self._scan()
            if self.scans >= 2 or self.error is not None:
                self.first_scan_completed.set()
            if self.error is not None:
                return
            self.stop_requested.wait(self.poll_interval_seconds)
        self.first_scan_completed.set()

    def _scan(self) -> None:
        all_files = subprocess.run(
            ("/usr/sbin/lsof", "-nP", "-p", str(self.process.pid)),
            capture_output=True,
            text=True,
        )
        if all_files.returncode != 0 or not all_files.stdout or all_files.stderr:
            if self.process.poll() is None:
                self.error = "runtime network monitor could not inspect the owned helper"
            return
        network_files = subprocess.run(
            ("/usr/sbin/lsof", "-nP", "-a", "-p", str(self.process.pid), "-i"),
            capture_output=True,
            text=True,
        )
        if network_files.returncode not in (0, 1) or network_files.stderr:
            if self.process.poll() is None:
                self.error = "runtime network monitor failed closed"
            return
        network_rows = [line for line in network_files.stdout.splitlines() if line.strip()]
        observed = max(0, len(network_rows) - 1) if network_rows else 0
        self.scans += 1
        self.network_fd_count += observed
        if observed > 0:
            self.error = "owned helper opened a network file descriptor"


@dataclass(frozen=True)
class AudioFixture:
    pcm: bytes
    expected_sample_count: int
    observed_sample_count: int
    channel_count: int
    sample_width_bytes: int
    sample_rate_hz: int


def read_public_audio_fixture(path: Path) -> AudioFixture:
    with wave.open(str(path), "rb") as source:
        channel_count = source.getnchannels()
        sample_width_bytes = source.getsampwidth()
        sample_rate_hz = source.getframerate()
        expected_sample_count = source.getnframes()
        require(channel_count == CHANNEL_COUNT, "fixture must be mono")
        require(sample_width_bytes == SAMPLE_WIDTH_BYTES, "fixture must be signed 16-bit PCM")
        require(sample_rate_hz == SAMPLE_RATE_HZ, "fixture must be 16 kHz")
        pcm = source.readframes(expected_sample_count)
        require(len(pcm) % SAMPLE_WIDTH_BYTES == 0, "fixture PCM ended within a sample")
        observed_sample_count = len(pcm) // SAMPLE_WIDTH_BYTES
        require(observed_sample_count == expected_sample_count, "fixture sample count did not match its WAV header")
        return AudioFixture(
            pcm=pcm,
            expected_sample_count=expected_sample_count,
            observed_sample_count=observed_sample_count,
            channel_count=channel_count,
            sample_width_bytes=sample_width_bytes,
            sample_rate_hz=sample_rate_hz,
        )


@dataclass(frozen=True)
class Frame:
    operation: int
    request_id: bytes
    generation: int
    payload: bytes = b""

    def encoded(self, version: int) -> bytes:
        require(len(self.request_id) == 16, "request ID must be 16 bytes")
        return struct.pack(">IHH16sQI", MAGIC, version, self.operation, self.request_id, self.generation, len(self.payload)) + self.payload


class Helper:
    canary_scanned_surface_count = 0
    backend_eligible_process_count = 0
    backend_counts = {"cpu": 0, "metal": 0, "unknown": 0}

    def __init__(self, executable: Path, model: Path, version: int, use_vad: bool = True):
        self.version = version
        self.vad_model = VAD_MODEL if version == VERSION_2 and use_vad else None
        self.vad_identity = VAD_IDENTITY if self.vad_model is not None else ""
        environment = dict(os.environ)
        environment["STENO_RUNTIME_BACKEND_ATTESTATION"] = "1"
        self.process = subprocess.Popen(
            (str(executable), "--protocol-version", str(version)),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            env=environment,
        )
        require(
            self.process.stdin is not None
            and self.process.stdout is not None
            and self.process.stderr is not None,
            "helper pipes unavailable",
        )
        self.input = self.process.stdin
        self.output = self.process.stdout
        self.error_output = self.process.stderr
        self.monitor: RuntimeNetworkMonitor | None = None
        try:
            self.monitor = RuntimeNetworkMonitor(self.process)
            load_id = uuid.uuid4().bytes
            load_payload = string(str(model))
            if version == VERSION_2:
                load_payload += string(RUNTIME_IDENTITY) + string(MODEL_IDENTITY) + string(self.vad_identity)
            self.send(Frame(LOAD, load_id, 0, load_payload))
            ready = self.expect(READY, load_id, 0, timeout=15.0)
            require(
                ready.payload == (identity_payload(self.vad_identity) if version == VERSION_2 else b""),
                "ready identity payload mismatch",
            )
            Helper.backend_eligible_process_count += 1
            self.observed_backend = self._read_backend_attestation(timeout=2.0)
            Helper.backend_counts[self.observed_backend] += 1
        except Exception:
            self.terminate()
            raise

    def stream_configuration(self) -> bytes:
        return stream_configuration(self.vad_model, self.vad_identity)

    def identity_payload(self) -> bytes:
        return identity_payload(self.vad_identity)

    def send(self, frame: Frame) -> None:
        self.send_bytes(frame.encoded(self.version))

    def send_bytes(self, data: bytes) -> None:
        try:
            self.input.write(data)
            self.input.flush()
        except (BrokenPipeError, ValueError) as error:
            raise TestFailure("helper pipe closed while writing") from error

    def read(self, timeout: float = 5.0) -> Frame:
        header = self._read_exact(36, timeout)
        magic, version, operation, request_id, generation, length = struct.unpack(">IHH16sQI", header)
        require(magic == MAGIC, "response magic mismatch")
        require(version == self.version, "response version mismatch")
        require(length <= MAXIMUM_PAYLOAD_BYTES, "response payload exceeded global limit")
        payload = self._read_exact(length, timeout)
        Helper.canary_scanned_surface_count += 1
        require(PUBLIC_CANARY not in payload, "public protocol canary escaped in a helper response")
        return Frame(operation, request_id, generation, payload)

    def expect(
        self,
        operation: int,
        request_id: bytes,
        generation: int,
        timeout: float = 5.0,
    ) -> Frame:
        frame = self.read(timeout)
        require(frame.operation == operation, f"expected operation {operation}, got {frame.operation}")
        require(frame.request_id == request_id, "response request ID mismatch")
        require(frame.generation == generation, "response generation mismatch")
        if operation == ERROR:
            require(
                len(frame.payload) == (4 if self.version == VERSION_1 else 16),
                "error response payload was malformed",
            )
        return frame

    def expect_no_frame(self, timeout: float = 0.25) -> None:
        ready, _, _ = select.select([self.output.fileno()], [], [], timeout)
        require(not ready, "unexpected additional response frame")

    def close_input_and_expect_eof(self, timeout: float = 5.0) -> None:
        self.input.close()
        deadline = time.monotonic() + timeout
        drained = bytearray()
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.output.fileno()], [], [], max(0.0, deadline - time.monotonic()))
            if not ready:
                break
            chunk = os.read(self.output.fileno(), 4096)
            if chunk == b"":
                self.process.wait(timeout=max(0.1, deadline - time.monotonic()))
                self._stop_monitor()
                require(self.process.returncode == 65, f"EOF teardown returned {self.process.returncode}, expected 65")
                require(not drained, "helper emitted a late response after input EOF")
                return
            Helper.canary_scanned_surface_count += 1
            require(PUBLIC_CANARY not in chunk, "public protocol canary escaped after input EOF")
            drained.extend(chunk)
        raise TestFailure("helper did not close stdout after input EOF")

    def force_crash_and_expect_eof(self, timeout: float = 5.0) -> None:
        # End observation immediately before the harness intentionally kills
        # the owned process. Otherwise lsof can race the SIGKILL and mislabel
        # the expected disappearance as an inspection failure.
        self._stop_monitor()
        os.killpg(self.process.pid, signal.SIGKILL)
        self.process.wait(timeout=timeout)
        require(self.process.returncode == -signal.SIGKILL, "forced helper crash was not observed")
        ready, _, _ = select.select([self.output.fileno()], [], [], timeout)
        require(bool(ready), "stdout did not become readable after helper crash")
        drained = self.output.read()
        Helper.canary_scanned_surface_count += 1
        require(PUBLIC_CANARY not in drained, "public protocol canary escaped after forced crash")
        require(drained == b"", "helper emitted a late response after forced crash")

    def shutdown(self) -> None:
        if self.process.poll() is not None:
            self._stop_monitor()
            return
        request_id = uuid.uuid4().bytes
        self.send(Frame(SHUTDOWN, request_id, 0))
        self.expect(STOPPED, request_id, 0)
        self.input.close()
        self.process.wait(timeout=5.0)
        self._stop_monitor()
        require(self.process.returncode == 0, f"clean shutdown returned {self.process.returncode}")

    def terminate(self) -> None:
        primary_error = sys.exc_info()[1]
        cleanup_errors: list[Exception] = []
        # Finish observation before intentionally killing the owned helper.
        # A failed monitor must still leave the process killed and reaped.
        try:
            self._stop_monitor()
        except Exception as error:
            cleanup_errors.append(error)
        try:
            if self.process.poll() is None:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass  # The helper exited between poll and kill.
        except Exception as error:
            cleanup_errors.append(error)
        finally:
            try:
                self.process.wait(timeout=5.0)
            except Exception as error:
                cleanup_errors.append(error)
        if cleanup_errors:
            if primary_error is not None:
                for error in cleanup_errors:
                    print(f"Secondary helper cleanup failure: {error}", file=sys.stderr)
            else:
                for error in cleanup_errors[1:]:
                    print(f"Secondary helper cleanup failure: {error}", file=sys.stderr)
                raise cleanup_errors[0]

    def _stop_monitor(self) -> None:
        if self.monitor is not None:
            monitor = self.monitor
            self.monitor = None
            monitor.stop()

    def _read_backend_attestation(self, timeout: float) -> str:
        deadline = time.monotonic() + timeout
        result = bytearray()
        while b"\n" not in result:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TestFailure("helper backend attestation timed out")
            ready, _, _ = select.select([self.error_output.fileno()], [], [], remaining)
            if not ready:
                raise TestFailure("helper backend attestation timed out")
            chunk = os.read(self.error_output.fileno(), 128 - len(result))
            if not chunk:
                raise TestFailure("helper backend attestation was unavailable")
            result.extend(chunk)
            require(len(result) <= 127, "helper backend attestation exceeded its bound")
        require(result.endswith(b"\n") and result.count(b"\n") == 1, "helper backend attestation was malformed")
        raw = bytes(result[:-1])
        if raw == b"STENO_BACKEND=cpu":
            return "cpu"
        if raw == b"STENO_BACKEND=metal":
            return "metal"
        if raw == b"STENO_BACKEND=unknown":
            return "unknown"
        raise TestFailure("helper backend attestation was malformed")

    def _read_exact(self, count: int, timeout: float) -> bytes:
        result = bytearray()
        deadline = time.monotonic() + timeout
        while len(result) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TestFailure(f"timed out reading {count}-byte response")
            ready, _, _ = select.select([self.output.fileno()], [], [], remaining)
            if not ready:
                raise TestFailure(f"timed out reading {count}-byte response")
            chunk = os.read(self.output.fileno(), count - len(result))
            if not chunk:
                raise TestFailure("unexpected helper EOF")
            result.extend(chunk)
        return bytes(result)


def start_stream(helper: Helper, stream_id: bytes, generation: int) -> None:
    helper.send(Frame(STREAM_START, stream_id, generation, helper.stream_configuration()))
    response = helper.expect(STREAM_STARTED, stream_id, generation)
    require(response.payload == helper.identity_payload(), "stream-start identity payload mismatch")


def append_all(helper: Helper, stream_id: bytes, generation: int, pcm: bytes) -> int:
    byte_offset = 0
    sequence = 0
    maximum_bytes = MAXIMUM_APPEND_SAMPLES * 2
    while byte_offset < len(pcm):
        chunk = pcm[byte_offset : byte_offset + maximum_bytes]
        helper.send(Frame(AUDIO_APPEND, stream_id, generation, append_payload(sequence, byte_offset // 2, chunk)))
        response = helper.expect(AUDIO_ACCEPTED, stream_id, generation)
        require(response.payload == u64(sequence) + u64((byte_offset + len(chunk)) // 2), "append acknowledgement mismatch")
        byte_offset += len(chunk)
        sequence += 1
    return sequence


def finish_payload(helper: Helper, audio: Path, pcm: bytes) -> bytes:
    return u64(len(pcm) // 2) + u64(fnv1a(pcm)) + string(str(audio)) + helper.stream_configuration()


VERIFICATION_DECISIONS = frozenset(
    {"accepted", "accepted_vocabulary", "replaced", "dropped", "unscorable"}
)
VERIFICATION_WINDOW_KEYS = frozenset({"seek", "decision", "tier", "wordsP", "wordsN", "P", "V", "N"})
SUPPORT_KEYS = frozenset({"words", "otherTokens", "otherSupport", "suspect"})
SUSPECT_KEYS = frozenset({"word", "group", "occurrences", "first"})


def with_vocabulary_flag(payload: bytes) -> bytes:
    threads, beam, best_of, flags = struct.unpack(">IIII", payload[:16])
    return struct.pack(">IIII", threads, beam, best_of, flags | (1 << 2)) + payload[16:]


def finish_with_configuration(audio: Path, pcm: bytes, configuration: bytes) -> bytes:
    return u64(len(pcm) // 2) + u64(fnv1a(pcm)) + string(str(audio)) + configuration


def require_finite_number_or_none(value: object, field: str) -> None:
    if value is None:
        return
    require(
        isinstance(value, (int, float)) and not isinstance(value, bool),
        f"verification window {field} was not a number",
    )
    require(math.isfinite(value), f"verification window {field} was not finite")


def require_verification_shape(verification: object) -> dict:
    require(isinstance(verification, dict), "verification was not an object")
    require(set(verification) == {"triggered", "windows"}, "verification object keys mismatch")
    require(isinstance(verification["triggered"], bool), "verification.triggered was not a boolean")
    windows = verification["windows"]
    require(isinstance(windows, list), "verification.windows was not an array")
    for window in windows:
        require(isinstance(window, dict), "verification window was not an object")
        require(set(window) == VERIFICATION_WINDOW_KEYS, "verification window keys mismatch")
        require(
            isinstance(window["seek"], int) and not isinstance(window["seek"], bool),
            "verification window seek was not an integer",
        )
        require(window["decision"] in VERIFICATION_DECISIONS, "verification window decision was invalid")
        require(
            isinstance(window["wordsP"], int) and not isinstance(window["wordsP"], bool),
            "verification window wordsP was not an integer",
        )
        require(
            isinstance(window["wordsN"], int) and not isinstance(window["wordsN"], bool),
            "verification window wordsN was not an integer",
        )
        require(window["tier"] in (0, 1, 2), "verification window tier was invalid")
        for field in ("P", "V", "N"):
            require_support_shape(window[field], field)
    return verification


def require_support_shape(support: object, field: str) -> None:
    if support is None:
        return
    require(isinstance(support, dict), f"verification {field} was not an object")
    require(set(support) == SUPPORT_KEYS, f"verification {field} keys mismatch")
    for key in ("words", "otherTokens"):
        require(
            isinstance(support[key], int) and not isinstance(support[key], bool),
            f"verification {field}.{key} was not an integer",
        )
    require_finite_number_or_none(support["otherSupport"], f"{field}.otherSupport")
    require(
        (support["otherSupport"] is None) == (support["otherTokens"] == 0),
        f"verification {field}.otherSupport disagreed with otherTokens",
    )
    require(isinstance(support["suspect"], list), f"verification {field}.suspect was not an array")
    for entry in support["suspect"]:
        require(isinstance(entry, dict), f"verification {field}.suspect entry was not an object")
        require(set(entry) == SUSPECT_KEYS, f"verification {field}.suspect keys mismatch")
        require(isinstance(entry["word"], str) and entry["word"] != "", f"verification {field}.suspect word was empty")
        require(entry["group"] in ("label", "vocabulary"), f"verification {field}.suspect group was invalid")
        require(
            isinstance(entry["occurrences"], int) and entry["occurrences"] >= 1,
            f"verification {field}.suspect occurrences was invalid",
        )
        require_finite_number_or_none(entry["first"], f"{field}.suspect.first")
        require(entry["first"] is not None, f"verification {field}.suspect first was missing")


def require_rich_result(payload: bytes) -> dict:
    decoded = json.loads(payload)
    require(isinstance(decoded, dict), "rich result was not an object")
    require(isinstance(decoded.get("transcription"), list), "rich result did not match schema")
    require(
        set(decoded) <= {"transcription", "verification"},
        "rich result contained unexpected keys",
    )
    if "verification" in decoded:
        require_verification_shape(decoded["verification"])
    return decoded


def test_v1_compatibility(executable: Path, model: Path, audio: Path, _: bytes) -> None:
    helper = Helper(executable, model, VERSION_1)
    try:
        request_id = uuid.uuid4().bytes
        helper.send(Frame(TRANSCRIBE, request_id, 7, one_shot_configuration(audio)))
        response = helper.expect(RESULT, request_id, 7, timeout=inference_timeout())
        decoded = json.loads(response.payload)
        require(isinstance(decoded.get("transcription"), list), "v1 result did not match rich transcript schema")
        helper.shutdown()
    finally:
        helper.terminate()


def test_validation_and_terminal_state(executable: Path, model: Path, audio: Path, pcm: bytes) -> None:
    helper = Helper(executable, model, VERSION_2)
    try:
        stream_id = uuid.uuid4().bytes
        other_id = uuid.uuid4().bytes
        generation = 41
        start_stream(helper, stream_id, generation)

        helper.send(Frame(STREAM_START, other_id, generation + 1, helper.stream_configuration()))
        require_error(helper.expect(ERROR, other_id, generation + 1), 1, STREAM_START)

        first = pcm[: 4_000]
        helper.send(Frame(AUDIO_APPEND, other_id, generation, append_payload(0, 0, first)))
        require_error(helper.expect(ERROR, other_id, generation), 1, AUDIO_APPEND, 0)
        helper.send(Frame(AUDIO_APPEND, stream_id, generation, append_payload(0, 0, first)))
        helper.expect(AUDIO_ACCEPTED, stream_id, generation)

        helper.send(Frame(AUDIO_APPEND, stream_id, generation, append_payload(0, 0, first)))
        require_error(helper.expect(ERROR, stream_id, generation), 1, AUDIO_APPEND, 0)

        helper.send(Frame(STREAM_FINISH, stream_id, generation, finish_payload(helper, audio, pcm)))
        require_error(helper.expect(ERROR, stream_id, generation, timeout=10.0), 3, STREAM_FINISH)
        helper.send(Frame(AUDIO_APPEND, stream_id, generation, append_payload(1, len(first) // 2, first)))
        require_error(helper.expect(ERROR, stream_id, generation), 1, AUDIO_APPEND, 1)
        helper.send(Frame(STREAM_CANCEL, stream_id, generation))
        require_error(helper.expect(ERROR, stream_id, generation), 1, STREAM_CANCEL)
        helper.shutdown()
    finally:
        helper.terminate()


def test_malformed_and_oversized_payloads(executable: Path, model: Path, _: Path, pcm: bytes) -> None:
    helper = Helper(executable, model, VERSION_2)
    try:
        generation = 52

        stream_id = uuid.uuid4().bytes
        start_stream(helper, stream_id, generation)
        helper.send(Frame(AUDIO_APPEND, stream_id, generation, append_payload(1, 0, pcm[:2])))
        require_error(helper.expect(ERROR, stream_id, generation), 1, AUDIO_APPEND, 1)
        helper.send(Frame(STREAM_CANCEL, stream_id, generation))
        helper.expect(CANCELLED, stream_id, generation)

        stream_id = uuid.uuid4().bytes
        start_stream(helper, stream_id, generation + 1)
        malformed = u64(0) + u64(0) + u32(2) + pcm[:2]
        helper.send(Frame(AUDIO_APPEND, stream_id, generation + 1, malformed))
        require_error(helper.expect(ERROR, stream_id, generation + 1), 1, AUDIO_APPEND, 0)
        helper.send(Frame(STREAM_CANCEL, stream_id, generation + 1))
        helper.expect(CANCELLED, stream_id, generation + 1)

        stream_id = uuid.uuid4().bytes
        start_stream(helper, stream_id, generation + 2)
        oversized_pcm = (pcm * ((MAXIMUM_APPEND_SAMPLES * 2 // len(pcm)) + 2))[: (MAXIMUM_APPEND_SAMPLES + 1) * 2]
        helper.send(Frame(AUDIO_APPEND, stream_id, generation + 2, append_payload(0, 0, oversized_pcm)))
        require_error(helper.expect(ERROR, stream_id, generation + 2), 1, AUDIO_APPEND, 0)
        helper.send(Frame(STREAM_CANCEL, stream_id, generation + 2))
        helper.expect(CANCELLED, stream_id, generation + 2)

        stream_id = uuid.uuid4().bytes
        start_stream(helper, stream_id, generation + 3)
        helper.send(Frame(STREAM_DECODE, stream_id, generation + 3, u64(1) + u64(0) + PUBLIC_CANARY))
        require_error(helper.expect(ERROR, stream_id, generation + 3), 1, STREAM_DECODE, 1)
        helper.send(Frame(STREAM_CANCEL, stream_id, generation + 3))
        helper.expect(CANCELLED, stream_id, generation + 3)
        helper.shutdown()
    finally:
        helper.terminate()


def test_finish_priority_and_exactly_one_final(executable: Path, model: Path, audio: Path, pcm: bytes) -> None:
    helper = Helper(executable, model, VERSION_2)
    try:
        stream_id = uuid.uuid4().bytes
        generation = 63
        start_stream(helper, stream_id, generation)
        append_all(helper, stream_id, generation, pcm)

        helper.send(Frame(STREAM_DECODE, stream_id, generation, u64(1) + u64(len(pcm) // 2)))
        helper.send(Frame(STREAM_FINISH, stream_id, generation, finish_payload(helper, audio, pcm)))

        final_count = 0
        deadline = time.monotonic() + inference_timeout()
        while final_count == 0:
            response = helper.read(max(0.1, deadline - time.monotonic()))
            require(response.request_id == stream_id and response.generation == generation, "finish response identity mismatch")
            if response.operation == FINAL_RESULT:
                final_count += 1
                decoded = json.loads(response.payload)
                require(isinstance(decoded.get("transcription"), list), "final result did not match rich transcript schema")
            else:
                require(response.operation == HYPOTHESIS, f"unexpected response while finishing: {response.operation}")
                _, _, _, evidence, _ = parse_hypothesis(response.payload)
                require(evidence == 2, "JFK preview did not carry speech evidence")

        helper.send(Frame(STREAM_FINISH, stream_id, generation, finish_payload(helper, audio, pcm)))
        require_error(helper.expect(ERROR, stream_id, generation), 1, STREAM_FINISH)
        helper.expect_no_frame()
        require(final_count == 1, "stream produced more than one final result")

        replacement_id = uuid.uuid4().bytes
        start_stream(helper, replacement_id, generation + 1)
        helper.send(Frame(STREAM_CANCEL, replacement_id, generation + 1))
        helper.expect(CANCELLED, replacement_id, generation + 1)
        helper.shutdown()
    finally:
        helper.terminate()


def test_finish_rejects_wrong_fnv(executable: Path, model: Path, audio: Path, pcm: bytes) -> None:
    helper = Helper(executable, model, VERSION_2)
    try:
        stream_id = uuid.uuid4().bytes
        generation = 68
        start_stream(helper, stream_id, generation)
        append_all(helper, stream_id, generation, pcm)
        wrong_hash = fnv1a(pcm) ^ 1
        payload = (
            u64(len(pcm) // SAMPLE_WIDTH_BYTES)
            + u64(wrong_hash)
            + string(str(audio))
            + helper.stream_configuration()
        )
        helper.send(Frame(STREAM_FINISH, stream_id, generation, payload))
        require_error(helper.expect(ERROR, stream_id, generation, timeout=10.0), 3, STREAM_FINISH)
        helper.expect_no_frame(0.5)
        helper.shutdown()
    finally:
        helper.terminate()


def test_cancel_priority(executable: Path, model: Path, _: Path, pcm: bytes) -> None:
    helper = Helper(executable, model, VERSION_2)
    try:
        stream_id = uuid.uuid4().bytes
        generation = 74
        start_stream(helper, stream_id, generation)
        append_all(helper, stream_id, generation, pcm)
        helper.send(Frame(STREAM_DECODE, stream_id, generation, u64(1) + u64(len(pcm) // 2)))
        helper.send(Frame(STREAM_CANCEL, stream_id, generation))

        cancelled = False
        deadline = time.monotonic() + 5.0
        while not cancelled:
            response = helper.read(max(0.1, deadline - time.monotonic()))
            require(response.request_id == stream_id and response.generation == generation, "cancel response identity mismatch")
            if response.operation == CANCELLED:
                cancelled = True
            else:
                require(response.operation == HYPOTHESIS, f"unexpected response while cancelling: {response.operation}")
                _, _, _, evidence, _ = parse_hypothesis(response.payload)
                require(evidence == 2, "JFK preview did not carry speech evidence")
        helper.expect_no_frame(0.5)
        helper.shutdown()
    finally:
        helper.terminate()


def test_preview_silence_resumption_and_unknown(executable: Path, model: Path, _: Path, pcm: bytes) -> None:
    """Confirmed silence emits no text; speech resumes and missing VAD stays unknown."""
    speech = pcm[: SAMPLE_RATE_HZ * 3 * SAMPLE_WIDTH_BYTES]
    silence = b"\x00\x00" * (SAMPLE_RATE_HZ // 5)
    for use_vad in (True, False):
        helper = Helper(executable, model, VERSION_2, use_vad=use_vad)
        try:
            stream_id = uuid.uuid4().bytes
            generation = 790 if use_vad else 791
            start_stream(helper, stream_id, generation)
            offset = 0
            sequence = 0
            for revision, chunk in enumerate((silence, speech, silence, speech), start=1):
                for byte_offset in range(0, len(chunk), MAXIMUM_APPEND_SAMPLES * 2):
                    block = chunk[byte_offset : byte_offset + MAXIMUM_APPEND_SAMPLES * 2]
                    helper.send(Frame(AUDIO_APPEND, stream_id, generation, append_payload(sequence, offset, block)))
                    offset += len(block) // 2
                    require(helper.expect(AUDIO_ACCEPTED, stream_id, generation).payload == u64(sequence) + u64(offset), "resumption append mismatch")
                    sequence += 1
                helper.send(Frame(STREAM_DECODE, stream_id, generation, u64(revision) + u64(offset)))
                response = helper.expect(HYPOTHESIS, stream_id, generation, timeout=inference_timeout())
                observed_revision, watermark, _, evidence, text = parse_hypothesis(response.payload)
                require((observed_revision, watermark) == (revision, offset), "resumption response correlation mismatch")
                expected_evidence = (1 if revision % 2 else 2) if use_vad else 0
                require(evidence == expected_evidence, "silence/resumption speech evidence mismatch")
                if use_vad and evidence == 1:
                    require(text == "", "confirmed silence unnecessarily produced provisional ASR text")
                elif revision % 2 == 0:
                    require(bool(text.strip()), "speech or unknown evidence lost provisional ASR text")
            helper.send(Frame(STREAM_CANCEL, stream_id, generation))
            helper.expect(CANCELLED, stream_id, generation)
            helper.expect_no_frame(0.2)
            helper.shutdown()
        finally:
            helper.terminate()


def test_preview_speech_evidence(executable: Path, model: Path, _: Path, pcm: bytes) -> None:
    test_preview_silence_resumption_and_unknown(executable, model, _, pcm)
    helper = Helper(executable, model, VERSION_2)
    try:
        def keyboard_click_fixture(sample_count: int) -> bytes:
            samples = [0] * sample_count
            click_start = sample_count // 4
            click_length = min(80, sample_count - click_start)
            for index in range(click_length):
                magnitude = 30_000 * (click_length - index) // click_length
                samples[click_start + index] = magnitude if index % 2 == 0 else -magnitude
            return b"".join(struct.pack("<h", sample) for sample in samples)

        def deterministic_broadband_noise(sample_count: int) -> bytes:
            state = 0x6D2B79F5
            samples = bytearray()
            for _ in range(sample_count):
                state ^= (state << 13) & 0xFFFFFFFF
                state ^= state >> 17
                state ^= (state << 5) & 0xFFFFFFFF
                sample = ((state & 0xFFFF) - 32_768) * 7 // 8
                samples.extend(struct.pack("<h", sample))
            return bytes(samples)

        def fresh_stream_evidence(fixture_pcm: bytes, fixture_generation: int) -> tuple[int, int]:
            fixture_sample_count = len(fixture_pcm) // SAMPLE_WIDTH_BYTES
            fixture_stream_id = uuid.uuid4().bytes
            start_stream(helper, fixture_stream_id, fixture_generation)
            append_all(helper, fixture_stream_id, fixture_generation, fixture_pcm)
            helper.send(
                Frame(
                    STREAM_DECODE,
                    fixture_stream_id,
                    fixture_generation,
                    u64(1) + u64(fixture_sample_count),
                )
            )
            fixture_response = helper.expect(
                HYPOTHESIS,
                fixture_stream_id,
                fixture_generation,
                timeout=inference_timeout(),
            )
            _, fixture_watermark, _, fixture_evidence, _ = parse_hypothesis(fixture_response.payload)
            helper.send(Frame(STREAM_CANCEL, fixture_stream_id, fixture_generation))
            helper.expect(CANCELLED, fixture_stream_id, fixture_generation)
            return fixture_watermark, fixture_evidence

        stream_id = uuid.uuid4().bytes
        generation = 76
        start_stream(helper, stream_id, generation)
        preview_sample_count = SAMPLE_RATE_HZ // 5
        preview_byte_count = preview_sample_count * SAMPLE_WIDTH_BYTES
        early_speech = pcm[:preview_byte_count]
        require(len(early_speech) == preview_byte_count, "JFK fixture was shorter than the early-speech probe")
        next_sequence = append_all(helper, stream_id, generation, early_speech)
        first_watermark = preview_sample_count
        helper.send(Frame(STREAM_DECODE, stream_id, generation, u64(1) + u64(first_watermark)))
        first = helper.expect(HYPOTHESIS, stream_id, generation, timeout=inference_timeout())
        revision, watermark, _, evidence, _ = parse_hypothesis(first.payload)
        require(
            (revision, watermark, evidence) == (1, first_watermark, 2),
            "first 200 ms of JFK did not carry speech evidence",
        )

        silence = b"\x00\x00" * preview_sample_count
        helper.send(
            Frame(
                AUDIO_APPEND,
                stream_id,
                generation,
                append_payload(next_sequence, first_watermark, silence),
            )
        )
        accepted = helper.expect(AUDIO_ACCEPTED, stream_id, generation)
        second_watermark = first_watermark + preview_sample_count
        require(accepted.payload == u64(next_sequence) + u64(second_watermark), "silence append mismatch")
        helper.send(Frame(STREAM_DECODE, stream_id, generation, u64(2) + u64(second_watermark)))
        second = helper.expect(HYPOTHESIS, stream_id, generation, timeout=inference_timeout())
        revision, watermark, _, evidence, _ = parse_hypothesis(second.payload)
        require(
            (revision, watermark, evidence) == (2, second_watermark, 1),
            "decode-scoped silence was contaminated by earlier-window speech evidence",
        )
        helper.send(Frame(STREAM_CANCEL, stream_id, generation))
        helper.expect(CANCELLED, stream_id, generation)

        fixture_generation = generation + 1
        for speech_sample_count in (SAMPLE_RATE_HZ * 18 // 100, SAMPLE_RATE_HZ // 5, SAMPLE_RATE_HZ // 4):
            speech_pcm = pcm[: speech_sample_count * SAMPLE_WIDTH_BYTES]
            speech_watermark, speech_evidence = fresh_stream_evidence(speech_pcm, fixture_generation)
            require(speech_watermark == speech_sample_count, "early JFK speech watermark mismatch")
            require(speech_evidence == 2, f"first {speech_sample_count * 1_000 // SAMPLE_RATE_HZ} ms of JFK did not carry speech evidence")
            fixture_generation += 1

        phase_stream_id = uuid.uuid4().bytes
        phase_generation = fixture_generation
        phase_slice_samples = SAMPLE_RATE_HZ // 5
        speech_half_samples = SAMPLE_RATE_HZ * 9 // 100
        quiet_samples = phase_slice_samples - speech_half_samples
        straddling_speech = pcm[: speech_half_samples * 2 * SAMPLE_WIDTH_BYTES]
        require(
            len(straddling_speech) == speech_half_samples * 2 * SAMPLE_WIDTH_BYTES,
            "JFK fixture was shorter than the straddling-speech probe",
        )
        first_phase_slice = (
            b"\x00\x00" * quiet_samples
            + straddling_speech[: speech_half_samples * SAMPLE_WIDTH_BYTES]
        )
        second_phase_slice = (
            straddling_speech[speech_half_samples * SAMPLE_WIDTH_BYTES :]
            + b"\x00\x00" * quiet_samples
        )
        start_stream(helper, phase_stream_id, phase_generation)
        append_all(helper, phase_stream_id, phase_generation, first_phase_slice)
        helper.send(Frame(STREAM_DECODE, phase_stream_id, phase_generation, u64(1) + u64(phase_slice_samples)))
        first_phase_response = helper.expect(HYPOTHESIS, phase_stream_id, phase_generation, timeout=inference_timeout())
        _, first_phase_watermark, _, first_phase_evidence, _ = parse_hypothesis(first_phase_response.payload)
        require(first_phase_watermark == phase_slice_samples, "first phase-offset watermark mismatch")

        helper.send(
            Frame(
                AUDIO_APPEND,
                phase_stream_id,
                phase_generation,
                append_payload(1, phase_slice_samples, second_phase_slice),
            )
        )
        second_phase_watermark = phase_slice_samples * 2
        require(
            helper.expect(AUDIO_ACCEPTED, phase_stream_id, phase_generation).payload
            == u64(1) + u64(second_phase_watermark),
            "second phase-offset append mismatch",
        )
        helper.send(Frame(STREAM_DECODE, phase_stream_id, phase_generation, u64(2) + u64(second_phase_watermark)))
        second_phase_response = helper.expect(HYPOTHESIS, phase_stream_id, phase_generation, timeout=inference_timeout())
        _, observed_second_watermark, _, second_phase_evidence, _ = parse_hypothesis(second_phase_response.payload)
        require(observed_second_watermark == second_phase_watermark, "second phase-offset watermark mismatch")
        require(
            2 in (first_phase_evidence, second_phase_evidence),
            "detectable 180 ms JFK speech was suppressed when split across two 200 ms preview scopes",
        )
        helper.send(Frame(STREAM_CANCEL, phase_stream_id, phase_generation))
        helper.expect(CANCELLED, phase_stream_id, phase_generation)
        fixture_generation += 1

        for non_speech_sample_count in (SAMPLE_RATE_HZ // 5, SAMPLE_RATE_HZ // 4):
            non_speech_fixtures = {
                "zero silence": b"\x00\x00" * non_speech_sample_count,
                "one-kHz square wave": b"".join(
                    struct.pack("<h", 28_000 if (index // 8) % 2 == 0 else -28_000)
                    for index in range(non_speech_sample_count)
                ),
                "alternating full-scale samples": b"".join(
                    struct.pack("<h", 30_000 if index % 2 == 0 else -30_000)
                    for index in range(non_speech_sample_count)
                ),
                "keyboard-click impulse": keyboard_click_fixture(non_speech_sample_count),
                "deterministic broadband noise": deterministic_broadband_noise(non_speech_sample_count),
            }
            for fixture_name, fixture_pcm in non_speech_fixtures.items():
                fixture_watermark, fixture_evidence = fresh_stream_evidence(fixture_pcm, fixture_generation)
                require(fixture_watermark == non_speech_sample_count, f"{fixture_name} watermark mismatch")
                require(
                    fixture_evidence == 1,
                    f"{non_speech_sample_count * 1_000 // SAMPLE_RATE_HZ} ms {fixture_name} was misclassified as preview speech",
                )
                fixture_generation += 1

        helper.shutdown()
    finally:
        helper.terminate()

    no_vad = Helper(executable, model, VERSION_2, use_vad=False)
    try:
        stream_id = uuid.uuid4().bytes
        generation = 77
        start_stream(no_vad, stream_id, generation)
        silence = b"\x00\x00" * 16_000
        append_all(no_vad, stream_id, generation, silence)
        no_vad.send(Frame(STREAM_DECODE, stream_id, generation, u64(1) + u64(16_000)))
        response = no_vad.expect(HYPOTHESIS, stream_id, generation, timeout=inference_timeout())
        _, _, _, evidence, _ = parse_hypothesis(response.payload)
        require(evidence == 0, "runtime without configured VAD did not emit unknown evidence")
        no_vad.send(Frame(STREAM_CANCEL, stream_id, generation))
        no_vad.expect(CANCELLED, stream_id, generation)
        no_vad.shutdown()
    finally:
        no_vad.terminate()


def test_cancel_during_finish_preserves_restart(executable: Path, model: Path, audio: Path, pcm: bytes) -> None:
    helper = Helper(executable, model, VERSION_2)
    try:
        stream_id = uuid.uuid4().bytes
        generation = 78
        start_stream(helper, stream_id, generation)
        append_all(helper, stream_id, generation, pcm)
        helper.send(Frame(STREAM_FINISH, stream_id, generation, finish_payload(helper, audio, pcm)))
        helper.send(Frame(STREAM_CANCEL, stream_id, generation))
        response = helper.read(timeout=5.0)
        require(
            response.operation == CANCELLED
            and response.request_id == stream_id
            and response.generation == generation,
            "cancel during finish did not promptly acknowledge cancellation",
        )
        helper.expect_no_frame(0.5)

        replacement_id = uuid.uuid4().bytes
        start_stream(helper, replacement_id, generation + 1)
        helper.send(Frame(STREAM_CANCEL, replacement_id, generation + 1))
        helper.expect(CANCELLED, replacement_id, generation + 1)
        helper.shutdown()
    finally:
        helper.terminate()


def test_shutdown_validation(executable: Path, model: Path, _: Path, __: bytes) -> None:
    helper = Helper(executable, model, VERSION_2)
    try:
        malformed_id = uuid.uuid4().bytes
        helper.send(Frame(SHUTDOWN, malformed_id, 0, b"not-empty"))
        require_error(helper.expect(ERROR, malformed_id, 0), 1, SHUTDOWN)

        stream_id = uuid.uuid4().bytes
        start_stream(helper, stream_id, 91)
        wrong_generation_id = uuid.uuid4().bytes
        helper.send(Frame(SHUTDOWN, wrong_generation_id, 1))
        require_error(helper.expect(ERROR, wrong_generation_id, 1), 1, SHUTDOWN)

        valid_id = uuid.uuid4().bytes
        helper.send(Frame(SHUTDOWN, valid_id, 0))
        helper.expect(STOPPED, valid_id, 0)
        helper.input.close()
        helper.process.wait(timeout=5.0)
        helper._stop_monitor()
        require(helper.process.returncode == 0, "valid active-session shutdown did not stop cleanly")
    finally:
        helper.terminate()


def test_crash_after_final(executable: Path, model: Path, audio: Path, pcm: bytes) -> None:
    helper = Helper(executable, model, VERSION_2)
    try:
        stream_id = uuid.uuid4().bytes
        generation = 79
        start_stream(helper, stream_id, generation)
        append_all(helper, stream_id, generation, pcm)
        helper.send(Frame(STREAM_FINISH, stream_id, generation, finish_payload(helper, audio, pcm)))
        response = helper.expect(FINAL_RESULT, stream_id, generation, timeout=inference_timeout())
        decoded = json.loads(response.payload)
        require(isinstance(decoded.get("transcription"), list), "pre-crash final result schema was malformed")
        helper.expect_no_frame()
        helper.force_crash_and_expect_eof()
    finally:
        helper.terminate()


def test_cpu_attestation_cannot_qualify_as_metal(_: Path, __: Path, ___: Path, ____: bytes) -> None:
    backend = classify_observed_backend({"cpu": 1, "metal": 0, "unknown": 0})
    require(backend == "observed-cpu", "CPU attestation was mislabeled")
    require(
        not qualifies_as_production_metal(backend, "default", passed=1, expected=1),
        "CPU fallback was allowed to qualify as production Metal",
    )
    require(
        classify_observed_backend({"cpu": 0, "metal": 0, "unknown": 1}) == "unobserved",
        "unknown backend attestation did not fail closed",
    )


def test_global_oversized_header(executable: Path, _: Path, __: Path, ___: bytes) -> None:
    process = subprocess.Popen(
        (str(executable), "--protocol-version", "2"),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    require(process.stdin is not None and process.stdout is not None, "helper pipes unavailable")
    monitor = RuntimeNetworkMonitor(process)
    try:
        request_id = uuid.uuid4().bytes
        process.stdin.write(struct.pack(">IHH16sQI", MAGIC, VERSION_2, LOAD, request_id, 0, MAXIMUM_PAYLOAD_BYTES + 1))
        process.stdin.flush()
        process.stdin.close()
        process.wait(timeout=5.0)
        require(process.returncode == 65, f"oversized header returned {process.returncode}, expected 65")
        require(process.stdout.read(1) == b"", "oversized header unexpectedly produced a response")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5.0)
        monitor.stop()


def run_before_ready_case(executable: Path, model: Path, eof: bool) -> None:
    process = subprocess.Popen(
        (str(executable), "--protocol-version", "2"),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    require(process.stdin is not None and process.stdout is not None, "helper pipes unavailable")
    monitor = RuntimeNetworkMonitor(process)
    try:
        request_id = uuid.uuid4().bytes
        payload = string(str(model)) + string(RUNTIME_IDENTITY) + string(MODEL_IDENTITY) + string(VAD_IDENTITY)
        encoded = Frame(LOAD, request_id, 0, payload).encoded(VERSION_2)
        if eof:
            process.stdin.write(encoded[:20])
            process.stdin.flush()
            process.stdin.close()
            process.wait(timeout=5.0)
            require(process.returncode == 65, f"pre-ready EOF returned {process.returncode}, expected 65")
        else:
            process.stdin.write(encoded)
            process.stdin.flush()
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5.0)
            require(process.returncode == -signal.SIGKILL, "pre-ready forced crash was not observed")
        drained = process.stdout.read()
        Helper.canary_scanned_surface_count += 1
        require(PUBLIC_CANARY not in drained, "public protocol canary escaped before readiness")
        require(not drained, "helper emitted readiness after pre-ready interruption")
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5.0)
        monitor.stop()


def run_interruption_case(
    executable: Path,
    model: Path,
    audio: Path,
    pcm: bytes,
    phase: str,
    eof: bool,
) -> None:
    helper = Helper(executable, model, VERSION_2)
    try:
        stream_id = uuid.uuid4().bytes
        generation = 85
        start_stream(helper, stream_id, generation)
        if phase == "append":
            encoded = Frame(AUDIO_APPEND, stream_id, generation, append_payload(0, 0, pcm[:4_000])).encoded(VERSION_2)
            helper.send_bytes(encoded[: 36 + 10])
        elif phase in ("hypothesis", "finish"):
            append_all(helper, stream_id, generation, pcm)
            if phase == "hypothesis":
                helper.send(Frame(STREAM_DECODE, stream_id, generation, u64(1) + u64(len(pcm) // 2)))
            else:
                helper.send(Frame(STREAM_FINISH, stream_id, generation, finish_payload(helper, audio, pcm)))
        elif phase != "before-append":
            raise TestFailure(f"unknown interruption phase: {phase}")

        if eof:
            helper.close_input_and_expect_eof(timeout=30.0)
        else:
            helper.force_crash_and_expect_eof()
    finally:
        helper.terminate()


def test_v2_stream_vocabulary_prompt_accepted(executable: Path, model: Path, audio: Path, pcm: bytes) -> None:
    helper = Helper(executable, model, VERSION_2)
    try:
        stream_id = uuid.uuid4().bytes
        generation = 201
        configuration = stream_configuration(
            helper.vad_model,
            helper.vad_identity,
            prompt="Language: en. Terms: Kubernetes.",
            vocabulary_prompt="Kubernetes.",
        )
        helper.send(Frame(STREAM_START, stream_id, generation, configuration))
        started = helper.expect(STREAM_STARTED, stream_id, generation)
        require(started.payload == helper.identity_payload(), "stream-start identity payload mismatch")
        append_all(helper, stream_id, generation, pcm)
        helper.send(Frame(STREAM_FINISH, stream_id, generation, finish_with_configuration(audio, pcm, configuration)))
        response = helper.expect(FINAL_RESULT, stream_id, generation, timeout=inference_timeout())
        require_rich_result(response.payload)
        helper.shutdown()
    finally:
        helper.terminate()


def test_v1_one_shot_vocabulary_prompt_accepted(executable: Path, model: Path, audio: Path, _: bytes) -> None:
    helper = Helper(executable, model, VERSION_1)
    try:
        request_id = uuid.uuid4().bytes
        helper.send(
            Frame(
                TRANSCRIBE,
                request_id,
                8,
                one_shot_configuration(
                    audio,
                    prompt="Language: en. Terms: Kubernetes.",
                    vocabulary_prompt="Kubernetes.",
                ),
            )
        )
        response = helper.expect(RESULT, request_id, 8, timeout=inference_timeout())
        require_rich_result(response.payload)
        helper.shutdown()
    finally:
        helper.terminate()


def test_prompted_jfk_accepted_verification(executable: Path, model: Path, audio: Path, _: bytes) -> None:
    helper = Helper(executable, model, VERSION_2)
    observed: object = None
    try:
        request_id = uuid.uuid4().bytes
        helper.send(
            Frame(
                TRANSCRIBE,
                request_id,
                9,
                one_shot_configuration(
                    audio,
                    prompt="Topic: country.",
                    vocabulary_prompt="Kubernetes.",
                    vad_model=helper.vad_model,
                ),
            )
        )
        response = helper.expect(RESULT, request_id, 9, timeout=inference_timeout())
        decoded = json.loads(response.payload)
        observed = decoded.get("verification") if isinstance(decoded, dict) else decoded
        try:
            require_rich_result(response.payload)
            require(isinstance(observed, dict), "prompted JFK result omitted verification")
            require(observed["triggered"] is True, "verification.triggered was not true")
            windows = observed["windows"]
            require(len(windows) == 1, "verification did not contain exactly one window")
            window = windows[0]
            require(window["seek"] == 0, "verification window seek was not 0")
            require(window["decision"] == "accepted", "verification window decision was not accepted")
            require(window["tier"] == 1, "verification window tier was not 1")
            prompted = window["P"]
            require(isinstance(prompted, dict), "verification window P was not scored")
            require(prompted["words"] >= 20, "verification window P counted too few words")
            suspects = {entry["word"]: entry for entry in prompted["suspect"]}
            require("country" in suspects, "verification window P did not list the spoken label word")
            require(suspects["country"]["group"] == "label", "country was not a label word")
            require(suspects["country"]["occurrences"] == 2, "country was not counted twice")
            require(suspects["country"]["first"] >= 5.0, "spoken country was not acoustically supported")
            require(window["V"] is None, "an accepted window scored a vocabulary retry")
            # The repeated label word is corroborated by the prompt-free decode,
            # which hears `country` as often.
            require(window["wordsN"] >= 20, "prompt-free decode did not hear the sentence")
        except TestFailure as error:
            raise TestFailure(
                f"{error}; observed verification={json.dumps(observed, sort_keys=True, ensure_ascii=True)}"
            ) from error
        helper.shutdown()
    finally:
        helper.terminate()


def test_vocabulary_prompt_malformed_payloads(executable: Path, model: Path, audio: Path, _: bytes) -> None:
    helper = Helper(executable, model, VERSION_2)
    try:
        generation = 210
        stream_base = helper.stream_configuration()
        transcribe_base = one_shot_configuration(audio)
        malformed_stream = (
            ("bit 2 set without a vocabulary string", with_vocabulary_flag(stream_base)),
            ("bit 2 clear with a trailing vocabulary string", stream_base + string("Kubernetes.")),
            ("bit 2 set with an empty vocabulary string", with_vocabulary_flag(stream_base) + string("")),
        )
        for offset, (_label, payload) in enumerate(malformed_stream):
            stream_id = uuid.uuid4().bytes
            helper.send(Frame(STREAM_START, stream_id, generation + offset, payload))
            require_error(helper.expect(ERROR, stream_id, generation + offset), 1, STREAM_START)

        malformed_transcribe = (
            ("bit 2 set without a vocabulary string", with_vocabulary_flag(transcribe_base)),
            ("bit 2 clear with a trailing vocabulary string", transcribe_base + string("Kubernetes.")),
            ("bit 2 set with an empty vocabulary string", with_vocabulary_flag(transcribe_base) + string("")),
        )
        for offset, (_label, payload) in enumerate(malformed_transcribe):
            request_id = uuid.uuid4().bytes
            helper.send(Frame(TRANSCRIBE, request_id, generation + 10 + offset, payload))
            require_error(helper.expect(ERROR, request_id, generation + 10 + offset), 1, TRANSCRIBE)
        helper.shutdown()
    finally:
        helper.terminate()


def declared_configuration() -> dict[str, object]:
    return {
        "audio": {
            "channelCount": CHANNEL_COUNT,
            "sampleRateHz": SAMPLE_RATE_HZ,
            "sampleWidthBytes": SAMPLE_WIDTH_BYTES,
            "encoding": "signed-integer-little-endian",
        },
        "streamRequest": {
            "threads": STREAM_THREAD_COUNT,
            "beamSize": 1,
            "bestOf": 1,
            "flags": 3,
            "language": "en",
            "prompt": None,
            "suppressRegex": None,
            "suppressNonSpeechTokens": True,
            "vadEnabled": True,
        },
        "inferenceThresholds": {
            "temperature": 0.0,
            "temperatureIncrement": 0.2,
            "entropyThreshold": 2.4,
            "logProbabilityThreshold": -1.0,
            "noSpeechThreshold": 0.6,
        },
        "vadThresholds": {
            "threshold": 0.5,
            "minimumSpeechDurationMS": 250,
            "previewThreshold": 0.12,
            "previewMinimumSpeechDurationMS": 50,
            "minimumSilenceDurationMS": 100,
            "maximumSpeechDurationSeconds": "FLT_MAX",
            "speechPadMS": 30,
            "samplesOverlap": 0.1,
            "previewScope": "newly-accepted-audio-since-prior-admitted-decode",
        },
        "bounds": {
            "maximumPayloadBytes": MAXIMUM_PAYLOAD_BYTES,
            "maximumStringBytes": 1024 * 1024,
            "maximumAppendSamples": MAXIMUM_APPEND_SAMPLES,
            "maximumAppendBytes": MAXIMUM_APPEND_SAMPLES * SAMPLE_WIDTH_BYTES,
            "maximumHypothesisBytes": 1024 * 1024,
            "previewWindowSamples": PREVIEW_WINDOW_SAMPLES,
            "maximumStreamSamples": MAXIMUM_STREAM_SAMPLES,
        },
        "harnessTimeoutsSeconds": {
            "defaultFrameRead": 5.0,
            "loadReady": 15.0,
            "backendAttestation": 2.0,
            "inference": inference_timeout(),
            "networkMonitorStartup": 3.0,
            "networkPollInterval": RuntimeNetworkMonitor.poll_interval_seconds,
        },
    }


def manifest_path(path: Path, repository: Path, absolute: bool = False) -> str:
    resolved = path.resolve()
    if absolute:
        return str(resolved)
    try:
        return str(resolved.relative_to(repository.resolve()))
    except ValueError:
        return str(resolved)


def source_fixture_manifest(
    repository: Path,
    helper_source: Path,
    helper_binary: Path,
    model: Path,
    vad_model: Path,
    audio: Path,
) -> dict[str, object]:
    entries = [
        {"role": "harnessSource", "path": manifest_path(Path(__file__), repository), "sha256": sha256(Path(__file__))},
        {"role": "helperSource", "path": manifest_path(helper_source, repository), "sha256": sha256(helper_source)},
        {"role": "promptScoringHeader", "path": manifest_path(helper_source.parent / "steno_prompt_scoring.h", repository), "sha256": sha256(helper_source.parent / "steno_prompt_scoring.h")},
        {"role": "promptVerificationHeader", "path": manifest_path(helper_source.parent / "steno_prompt_verification.h", repository), "sha256": sha256(helper_source.parent / "steno_prompt_verification.h")},
        {"role": "helperBinary", "path": manifest_path(helper_binary, repository), "sha256": sha256(helper_binary)},
        {"role": "audioFixture", "path": manifest_path(audio, repository), "sha256": sha256(audio)},
        {"role": "whisperModel", "path": manifest_path(model, repository, absolute=True), "sha256": sha256(model)},
        {"role": "vadModel", "path": manifest_path(vad_model, repository, absolute=True), "sha256": sha256(vad_model)},
    ]
    entries.sort(key=lambda entry: str(entry["role"]))
    return {
        "algorithm": "sha256-canonical-json-v1",
        "sha256": canonical_json_sha256(entries),
        "entries": entries,
    }


def environment_evidence() -> dict[str, object]:
    hardware_profile = checked_command_output(
        ("/usr/sbin/system_profiler", "SPHardwareDataType", "-detailLevel", "mini")
    )

    def profile_value(label: str) -> str:
        prefix = f"{label}:"
        values = [line.strip()[len(prefix):].strip() for line in hardware_profile.splitlines() if line.strip().startswith(prefix)]
        require(len(values) == 1 and bool(values[0]), f"hardware profile omitted {label}")
        return values[0]

    memory = profile_value("Memory")
    memory_match = re.fullmatch(r"([0-9]+) GB", memory)
    require(memory_match is not None, "hardware profile memory format was unsupported")
    return {
        "hardware": {
            "modelIdentifier": profile_value("Model Identifier"),
            "chip": profile_value("Chip"),
            "architecture": platform.machine(),
            "logicalProcessorCount": os.cpu_count(),
            "memoryBytes": int(memory_match.group(1)) * 1024 * 1024 * 1024,
        },
        "operatingSystem": {
            "name": "macOS",
            "version": checked_command_output(("/usr/bin/sw_vers", "-productVersion")),
            "build": checked_command_output(("/usr/bin/sw_vers", "-buildVersion")),
        },
    }


def validate_receipt(receipt: dict[str, object], fixture: AudioFixture) -> None:
    expected_root_keys = {
        "schemaVersion", "generatedAt", "git", "protocolVersions", "execution", "environment",
        "identity", "configuration", "sourceFixtureManifest", "cases", "hashes", "artifacts",
        "audio", "canary", "fallback", "network",
    }
    require(set(receipt) == expected_root_keys, "receipt root schema did not match schema v2")
    require(receipt["schemaVersion"] == RECEIPT_SCHEMA_VERSION, "receipt schema version mismatch")
    require(receipt["protocolVersions"] == [VERSION_1, VERSION_2], "receipt protocol versions mismatch")
    git = receipt["git"]
    require(isinstance(git, dict), "receipt git evidence was malformed")
    require(bool(re.fullmatch(r"[0-9a-f]{40}", str(git.get("sha", "")))), "receipt git SHA was invalid")
    require(git.get("state") in ("clean", "dirty"), "receipt git state was invalid")
    require(git.get("state") == ("dirty" if git.get("dirty") else "clean"), "receipt git state disagreed with dirty flag")

    manifest = receipt["sourceFixtureManifest"]
    require(isinstance(manifest, dict) and isinstance(manifest.get("entries"), list), "source/fixture manifest was malformed")
    require(manifest.get("algorithm") == "sha256-canonical-json-v1", "source/fixture manifest algorithm mismatch")
    require(manifest.get("sha256") == canonical_json_sha256(manifest["entries"]), "source/fixture manifest SHA mismatch")
    roles = [entry.get("role") for entry in manifest["entries"] if isinstance(entry, dict)]
    require(roles == sorted(roles), "source/fixture manifest was not role-sorted")
    expected_roles = {"harnessSource", "helperSource", "helperBinary", "promptScoringHeader", "promptVerificationHeader", "audioFixture", "whisperModel", "vadModel"}
    require(set(roles) == expected_roles and len(roles) == len(expected_roles), "source/fixture manifest roles were incomplete")
    for entry in manifest["entries"]:
        require(isinstance(entry, dict), "source/fixture manifest entry was malformed")
        require(bool(re.fullmatch(r"[0-9a-f]{64}", str(entry.get("sha256", "")))), "manifest artifact SHA was invalid")

    artifacts = receipt["artifacts"]
    require(isinstance(artifacts, dict), "receipt artifacts were malformed")
    require(Path(str(artifacts["model"]["path"])).is_absolute(), "model path was not absolute")
    require(Path(str(artifacts["vadModel"]["path"])).is_absolute(), "VAD path was not absolute")
    for artifact in artifacts.values():
        require(bool(re.fullmatch(r"[0-9a-f]{64}", str(artifact["sha256"]))), "artifact SHA was invalid")
    hashes = receipt["hashes"]
    require(isinstance(hashes, dict), "receipt hash evidence was malformed")
    require(hashes.get("sourceFixtureManifestSHA256") == manifest.get("sha256"), "flat manifest SHA disagreed")
    require(hashes.get("helperBinarySHA256") == artifacts["helper"]["sha256"], "helper artifact SHA disagreed")
    require(hashes.get("modelSHA256") == artifacts["model"]["sha256"], "model artifact SHA disagreed")
    require(hashes.get("vadModelSHA256") == artifacts["vadModel"]["sha256"], "VAD artifact SHA disagreed")
    require(hashes.get("audioSHA256") == artifacts["audioFixture"]["sha256"], "audio artifact SHA disagreed")

    identity = receipt["identity"]
    require(isinstance(identity, dict), "receipt runtime identity was malformed")
    require(
        set(identity) == {
            "schema", "capabilities", "runtime", "model", "vad",
            "currentASRContextCount", "peakASRContextCount",
            "helperBinary", "helperBinarySHA256",
        },
        "receipt runtime identity schema was malformed",
    )
    require(identity.get("schema") == IDENTITY_SCHEMA, "runtime identity schema mismatch")
    require(identity.get("capabilities") == IDENTITY_CAPABILITIES, "runtime capabilities mismatch")
    require(identity.get("runtime") == RUNTIME_IDENTITY, "runtime identity mismatch")
    require(identity.get("model") == MODEL_IDENTITY, "model identity mismatch")
    require(identity.get("vad") == VAD_IDENTITY, "VAD identity mismatch")
    require(identity.get("currentASRContextCount") == CURRENT_ASR_CONTEXT_COUNT, "current ASR context count mismatch")
    require(identity.get("peakASRContextCount") == PEAK_ASR_CONTEXT_COUNT, "peak ASR context count mismatch")
    require(identity.get("helperBinarySHA256") == artifacts["helper"]["sha256"], "helper identity SHA disagreed")

    audio = receipt["audio"]
    require(isinstance(audio, dict), "receipt audio evidence was malformed")
    require(audio.get("expectedSampleCount") == fixture.expected_sample_count, "expected sample count mismatch")
    require(audio.get("observedSampleCount") == fixture.observed_sample_count, "observed sample count mismatch")
    require(audio.get("expectedSampleCount") == audio.get("observedSampleCount"), "fixture sample counts disagreed")
    require(audio.get("fnv1a64") == f"{fnv1a(fixture.pcm):016x}", "receipt PCM FNV mismatch")

    cases = receipt["cases"]
    require(isinstance(cases, dict) and isinstance(cases.get("rows"), list), "receipt case evidence was malformed")
    rows = cases["rows"]
    require(cases.get("expected") == len(rows), "receipt expected case count mismatch")
    require(cases.get("passed") == sum(row.get("status") == "passed" for row in rows), "receipt passed count mismatch")
    require(cases.get("failed") == sum(row.get("status") == "failed" for row in rows), "receipt failed count mismatch")
    require(cases.get("skipped") == sum(row.get("status") == "skipped" for row in rows), "receipt skipped count mismatch")
    required_row_keys = {"name", "category", "status", "durationMS", "failureReason", "skipReason"}
    for row in rows:
        require(set(row) == required_row_keys, "receipt case row schema mismatch")
        require(row["status"] in ("passed", "failed", "skipped"), "receipt case result was invalid")
        require(isinstance(row["durationMS"], int) and row["durationMS"] >= 0, "receipt case duration was invalid")
        require((row["status"] == "failed") == (row["failureReason"] is not None), "receipt failure reason mismatch")
        require((row["status"] == "skipped") == (row["skipReason"] is not None), "receipt skip reason mismatch")
    require(cases.get("failureRows") == [row for row in rows if row["status"] == "failed"], "receipt failure rows were incomplete")
    require(cases.get("skipRows") == [row for row in rows if row["status"] == "skipped"], "receipt skip rows were incomplete")
    categories = cases.get("categories")
    require(isinstance(categories, dict), "receipt category evidence was malformed")
    for category, counts in categories.items():
        category_rows = [row for row in rows if row["category"] == category]
        require(counts.get("expected") == len(category_rows), "receipt category expected count mismatch")
        for result in ("passed", "failed", "skipped"):
            require(counts.get(result) == sum(row["status"] == result for row in category_rows), "receipt category result count mismatch")

    execution = receipt["execution"]
    require(isinstance(execution, dict), "receipt execution evidence was malformed")
    expected_matrix_counts = {"full-adversarial": 26, "reduced-adversarial": 16, "metal-smoke-only": 1}
    require(execution.get("matrix") in expected_matrix_counts, "receipt matrix kind was invalid")
    require(cases.get("expected") == expected_matrix_counts[execution["matrix"]], "receipt matrix row count mismatch")
    if execution.get("requestedDeviceMode") == "cpu-device-suppressed":
        require(execution.get("qualification") == "nonqualifying-cpu-diagnostic", "CPU receipt was not diagnostic-only")
        require(execution.get("productionMetalSmokePerformed") is False, "CPU receipt claimed a Metal qualification")
    network = receipt["network"]
    require(isinstance(network, dict), "receipt network evidence was malformed")
    if cases.get("failed") == 0:
        require(network.get("continuous") is True, "runtime network observation was not continuous")
        require(network.get("runtimeMonitorPerformed") is True, "runtime network monitor did not cover every helper")
        require(network.get("observedNetworkFileDescriptorCount") == 0, "runtime network evidence was nonzero")
        require(network.get("prohibitedUndefinedSymbols") == [], "helper imported a prohibited network symbol")
    require(receipt["configuration"] == declared_configuration(), "declared helper configuration drifted")

    serialized = json.dumps(receipt, ensure_ascii=True, sort_keys=True)
    require(PUBLIC_CANARY.decode("ascii") not in serialized, "public canary escaped into receipt")
    require("transcript" not in serialized.lower(), "receipt contained a transcript field")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--audio", required=True, type=Path)
    parser.add_argument(
        "--vad-model",
        type=Path,
        default=Path(__file__).resolve().parent.parent
        / "vendor/whisper.cpp/models/ggml-silero-v6.2.0.bin",
    )
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--skip-interruption-matrix", action="store_true")
    parser.add_argument("--metal-smoke-only", action="store_true")
    arguments = parser.parse_args()

    for path in (arguments.helper, arguments.model, arguments.audio, arguments.vad_model):
        require(path.is_file(), f"missing fixture: {path}")
    require(os.access(arguments.helper, os.X_OK), f"helper is not executable: {arguments.helper}")
    audio_fixture = read_public_audio_fixture(arguments.audio)
    pcm = audio_fixture.pcm
    global VAD_MODEL
    VAD_MODEL = arguments.vad_model.resolve()

    tests: list[tuple[str, str, Callable[[Path, Path, Path, bytes], None]]] = [
        ("v1 backward compatibility", "compatibility", test_v1_compatibility),
        ("v2 validation, cross-session, duplicate, and terminal rejection", "protocolValidation", test_validation_and_terminal_state),
        ("v2 out-of-order, malformed, and per-append size bounds", "protocolValidation", test_malformed_and_oversized_payloads),
        ("v2 finish priority and exactly one final", "terminalPriority", test_finish_priority_and_exactly_one_final),
        ("v2 finish rejects matching count with wrong FNV and emits no final", "authoritativeIntegrity", test_finish_rejects_wrong_fnv),
        ("v2 cancellation priority", "terminalPriority", test_cancel_priority),
        ("v2 decode-scoped Silero speech evidence", "speechEvidence", test_preview_speech_evidence),
        ("v2 cancel during finish preserves restart", "terminalPriority", test_cancel_during_finish_preserves_restart),
        ("v2 shutdown rejects malformed fields and permits active teardown", "protocolValidation", test_shutdown_validation),
        ("v2 crash after exactly one final", "lifecycleCrashEOF", test_crash_after_final),
        ("CPU attestation cannot qualify as Metal", "receiptIntegrity", test_cpu_attestation_cannot_qualify_as_metal),
        ("global oversized frame rejection", "parserBounds", test_global_oversized_header),
        ("v2 stream vocabulary-prompt configuration is accepted", "protocolValidation", test_v2_stream_vocabulary_prompt_accepted),
        ("v1 one-shot vocabulary-prompt field is accepted", "compatibility", test_v1_one_shot_vocabulary_prompt_accepted),
        ("v2 prompted JFK window emits accepted verification", "protocolValidation", test_prompted_jfk_accepted_verification),
        ("vocabulary-prompt flag and string mismatches are rejected", "protocolValidation", test_vocabulary_prompt_malformed_payloads),
    ]
    if arguments.metal_smoke_only:
        tests = [
            ("v2 Metal finish priority and exactly one final", "terminalPriority", test_finish_priority_and_exactly_one_final)
        ]
    elif not arguments.skip_interruption_matrix:
        tests.extend(
            (
                ("crash before ready", "lifecycleCrashEOF", lambda executable, model, _audio, _pcm: run_before_ready_case(executable, model, False)),
                ("EOF before ready", "lifecycleCrashEOF", lambda executable, model, _audio, _pcm: run_before_ready_case(executable, model, True)),
            )
        )
        for failure_mode in ("crash", "EOF"):
            for phase in ("before-append", "append", "hypothesis", "finish"):
                tests.append(
                    (
                        f"{failure_mode} during {phase}",
                        "lifecycleCrashEOF",
                        lambda executable, model, audio, pcm, phase=phase, eof=failure_mode == "EOF": run_interruption_case(
                            executable, model, audio, pcm, phase, eof
                        ),
                    )
                )

    started = time.monotonic()
    failures: list[str] = []
    case_results: list[dict[str, object]] = []
    for name, category, test in tests:
        case_started = time.monotonic()
        try:
            test(arguments.helper, arguments.model, arguments.audio, pcm)
            duration = time.monotonic() - case_started
            case_results.append(
                {
                    "name": name,
                    "category": category,
                    "status": "passed",
                    "durationMS": round(duration * 1_000),
                    "failureReason": None,
                    "skipReason": None,
                }
            )
            print(f"PASS {name} ({duration:.2f}s)")
        except Exception as error:  # keep running to produce a complete matrix
            duration = time.monotonic() - case_started
            failures.append(f"{name}: {error}")
            case_results.append(
                {
                    "name": name,
                    "category": category,
                    "status": "failed",
                    "durationMS": round(duration * 1_000),
                    "failureReason": str(error),
                    "skipReason": None,
                }
            )
            print(f"FAIL {name}: {error}", file=sys.stderr)

    elapsed = time.monotonic() - started
    print(f"Completed {len(tests)} real-helper cases in {elapsed:.2f}s")
    if arguments.receipt is not None:
        repository = Path(__file__).resolve().parent.parent
        helper_source = repository / "runtime-helper" / "steno_whisper_runtime.cpp"
        git_sha = checked_command_output(("git", "-C", str(repository), "rev-parse", "HEAD"))
        dirty = bool(
            checked_command_output(("git", "-C", str(repository), "status", "--porcelain"))
        )
        undefined_symbols = subprocess.run(
            ("nm", "-u", str(arguments.helper)), check=True, capture_output=True, text=True
        ).stdout
        prohibited_symbols = sorted(
            symbol
            for symbol in ("socket", "bind", "listen", "accept", "connect")
            if f"_{symbol}" in undefined_symbols
        )
        categories: dict[str, dict[str, int]] = {}
        for category in sorted({str(row["category"]) for row in case_results}):
            category_rows = [row for row in case_results if row["category"] == category]
            categories[category] = {
                "expected": len(category_rows),
                "passed": sum(row["status"] == "passed" for row in category_rows),
                "failed": sum(row["status"] == "failed" for row in category_rows),
                "skipped": sum(row["status"] == "skipped" for row in category_rows),
            }
        passed_count = sum(row["status"] == "passed" for row in case_results)
        failed_count = sum(row["status"] == "failed" for row in case_results)
        skipped_count = sum(row["status"] == "skipped" for row in case_results)
        requested_device_mode = (
            "cpu-device-suppressed" if os.environ.get("GGML_METAL_DEVICES") == "0" else "default"
        )
        observed_backend = classify_observed_backend(Helper.backend_counts)
        production_metal_performed = qualifies_as_production_metal(
            observed_backend,
            requested_device_mode,
            passed_count,
            len(case_results),
        )
        network_monitor_performed = (
            RuntimeNetworkMonitor.owned_process_count > 0
            and RuntimeNetworkMonitor.checked_process_count == RuntimeNetworkMonitor.owned_process_count
            and RuntimeNetworkMonitor.observed_network_fd_count == 0
            and (RuntimeNetworkMonitor.minimum_scan_count_per_process or 0) >= 2
        )
        manifest = source_fixture_manifest(
            repository,
            helper_source,
            arguments.helper,
            arguments.model,
            arguments.vad_model,
            arguments.audio,
        )
        helper_sha = sha256(arguments.helper)
        model_sha = sha256(arguments.model)
        vad_model_sha = sha256(arguments.vad_model)
        audio_sha = sha256(arguments.audio)
        harness_sha = sha256(Path(__file__).resolve())
        helper_source_sha = sha256(helper_source)
        qualification = (
            "qualifying-production-metal"
            if production_metal_performed
            else "nonqualifying-cpu-diagnostic"
            if requested_device_mode == "cpu-device-suppressed"
            else "nonqualifying-diagnostic"
        )
        receipt = {
            "schemaVersion": RECEIPT_SCHEMA_VERSION,
            "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "git": {"sha": git_sha, "dirty": dirty, "state": "dirty" if dirty else "clean"},
            "protocolVersions": [1, 2],
            "execution": {
                "requestedDeviceMode": requested_device_mode,
                "backend": observed_backend,
                "backendEligibleProcessCount": Helper.backend_eligible_process_count,
                "attestedProcessCount": sum(Helper.backend_counts.values()),
                "observedBackends": dict(Helper.backend_counts),
                "productionMetalSmokePerformed": production_metal_performed,
                "qualification": qualification,
                "matrix": (
                    "metal-smoke-only"
                    if arguments.metal_smoke_only
                    else "reduced-adversarial"
                    if arguments.skip_interruption_matrix
                    else "full-adversarial"
                ),
            },
            "environment": environment_evidence(),
            "identity": {
                "schema": IDENTITY_SCHEMA,
                "capabilities": IDENTITY_CAPABILITIES,
                "runtime": RUNTIME_IDENTITY,
                "model": MODEL_IDENTITY,
                "vad": VAD_IDENTITY,
                "currentASRContextCount": CURRENT_ASR_CONTEXT_COUNT,
                "peakASRContextCount": PEAK_ASR_CONTEXT_COUNT,
                "helperBinary": arguments.helper.name,
                "helperBinarySHA256": helper_sha,
            },
            "configuration": declared_configuration(),
            "sourceFixtureManifest": manifest,
            "cases": {
                "expected": len(case_results),
                "passed": passed_count,
                "failed": failed_count,
                "skipped": skipped_count,
                "categories": categories,
                "rows": case_results,
                "failureRows": [row for row in case_results if row["status"] == "failed"],
                "skipRows": [row for row in case_results if row["status"] == "skipped"],
            },
            "hashes": {
                "harnessSHA256": harness_sha,
                "helperSourceSHA256": helper_source_sha,
                "helperBinarySHA256": helper_sha,
                "modelSHA256": model_sha,
                "audioSHA256": audio_sha,
                "vadModelSHA256": vad_model_sha,
                "canarySHA256": hashlib.sha256(PUBLIC_CANARY).hexdigest(),
                "sourceFixtureManifestSHA256": manifest["sha256"],
            },
            "artifacts": {
                "helper": {"path": manifest_path(arguments.helper, repository), "sha256": helper_sha},
                "model": {"path": str(arguments.model.resolve()), "sha256": model_sha},
                "vadModel": {"path": str(arguments.vad_model.resolve()), "sha256": vad_model_sha},
                "audioFixture": {"path": manifest_path(arguments.audio, repository), "sha256": audio_sha},
            },
            "audio": {
                "expectedSampleCount": audio_fixture.expected_sample_count,
                "observedSampleCount": audio_fixture.observed_sample_count,
                "channelCount": audio_fixture.channel_count,
                "sampleWidthBytes": audio_fixture.sample_width_bytes,
                "sampleRateHz": audio_fixture.sample_rate_hz,
                "fnv1a64": f"{fnv1a(pcm):016x}",
            },
            "canary": {"scannedSurfaceCount": Helper.canary_scanned_surface_count, "escapes": 0},
            "fallback": {"performed": False, "attempts": 0, "successes": 0},
            "network": {
                "undefinedSymbolScanPerformed": True,
                "prohibitedUndefinedSymbols": prohibited_symbols,
                "runtimeMonitorPerformed": network_monitor_performed,
                "ownedProcessCount": RuntimeNetworkMonitor.owned_process_count,
                "checkedProcessCount": RuntimeNetworkMonitor.checked_process_count,
                "observedNetworkFileDescriptorCount": RuntimeNetworkMonitor.observed_network_fd_count,
                "observedNetworkFDCount": RuntimeNetworkMonitor.observed_network_fd_count,
                "continuous": network_monitor_performed,
                "scanCount": RuntimeNetworkMonitor.scan_count,
                "observationDurationMS": RuntimeNetworkMonitor.observation_duration_ms,
                "minimumScanCountPerProcess": RuntimeNetworkMonitor.minimum_scan_count_per_process or 0,
                "pollIntervalMS": round(RuntimeNetworkMonitor.poll_interval_seconds * 1_000),
            },
        }
        validate_receipt(receipt, audio_fixture)
        arguments.receipt.parent.mkdir(parents=True, exist_ok=True)
        arguments.receipt.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if failures:
        print("Failures:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except TestFailure as error:
        print(f"FAIL setup: {error}", file=sys.stderr)
        raise SystemExit(1)
