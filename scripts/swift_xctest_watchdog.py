#!/usr/bin/env python3
"""Bound SwiftPM XCTest on CI and summarize a hung macOS test process.

Diagnostics only contain allowlisted stack *category counts*: raw sample stacks,
commands, arguments, environment, and Swift/Gateway output are never copied to
artifacts or printed by this watchdog. The ordinary swift test output remains
under GitHub Actions' existing redaction policy.
"""
from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

_STACK_MARKERS = (
    "AgentWearLink",
    "OpenClaw",
    "XCTest",
    "swift_task",
    "libswift_Concurrency",
    "libdispatch",
    "pthread",
    "mach_msg",
)
_SAMPLE_SECONDS = "2"
_SAMPLE_TIMEOUT_SECONDS = 12


def parse_process_table(output: str) -> dict[int, tuple[int, str]]:
    """Parse 'ps -axo pid=,ppid=,comm=' without trusting command arguments."""
    entries: dict[int, tuple[int, str]] = {}
    for line in output.splitlines():
        fields = line.strip().split(maxsplit=2)
        if len(fields) != 3:
            continue
        try:
            pid, ppid = int(fields[0]), int(fields[1])
        except ValueError:
            continue
        entries[pid] = (ppid, fields[2])
    return entries


def select_xctest_descendant(
    root_pid: int, entries: dict[int, tuple[int, str]]
) -> int:
    """Select a child XCTest host, falling back to the owned swift process."""
    descendants = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, (parent_pid, _) in entries.items():
            if parent_pid in descendants and pid not in descendants:
                descendants.add(pid)
                changed = True
    matches = [
        pid for pid in descendants
        if pid != root_pid and (
            entries[pid][1].split("/")[-1].lower() == "xctest"
            or entries[pid][1].split("/")[-1].lower().endswith(".xctest")
        )
    ]
    return min(matches) if matches else root_pid


def sample_categories(text: str) -> dict[str, int]:
    """Keep only fixed category names and counts, never untrusted stack text."""
    counts: dict[str, int] = {}
    for marker in _STACK_MARKERS:
        count = sum(1 for line in text.splitlines() if marker in line)
        if count:
            counts[marker] = count
    return counts


def safe_stack_diagnostics(root_pid: int) -> None:
    if sys.platform != "darwin":
        print("AWL XCTest timeout: macOS stack sampling unavailable.", file=sys.stderr)
        return
    try:
        result = subprocess.run(
            ["/bin/ps", "-axo", "pid=,ppid=,comm="],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, timeout=5, check=True,
        )
        pid = select_xctest_descendant(root_pid, parse_process_table(result.stdout))
        with tempfile.TemporaryDirectory(prefix="awl-xctest-") as temporary:
            dest = Path(temporary) / "sample.txt"
            result = subprocess.run(
                ["/usr/bin/sample", str(pid), _SAMPLE_SECONDS, "-file", str(dest)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=_SAMPLE_TIMEOUT_SECONDS, check=False,
            )
            if result.returncode != 0 or not dest.is_file():
                print("AWL XCTest timeout: process sample unavailable.", file=sys.stderr)
                return
            # Bounded read: exclude potentially huge/sensitive raw stack dumps.
            with dest.open("r", encoding="utf-8", errors="replace") as handle:
                markers = sample_categories(handle.read(2_000_000))
            summary = ", ".join(f"{name}={count}" for name, count in markers.items())
            print(f"AWL XCTest timeout: allowlisted stack markers: {summary or 'none'}", file=sys.stderr)
    except (OSError, subprocess.SubprocessError):
        print("AWL XCTest timeout: process sample unavailable.", file=sys.stderr)


def stop_owned_group(process: subprocess.Popen[bytes]) -> None:
    """Retire the *owned session* even after the SwiftPM parent has exited.

    subprocess.Popen(start_new_session=True) makes process.pid the sole
    process-group ID for this invocation. SwiftPM may exit with success while
    an xctest child is still alive. Checking only process.poll() would then
    leak that child into the next test shard and eventually saturate the
    macOS XCTest worker. Never scan or signal unrelated runner processes.
    """
    parent_running = process.poll() is None
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass

    if parent_running:
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass

    # The parent may have exited successfully *during* the grace period
    # while a child remains in the same session. A final group kill still
    # applies to those owned children. ESRCH means there is nothing left.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass

    if process.poll() is None:
        process.wait()


_MAX_VERIFICATION_LOG_BYTES = 2_000_000

# A dedicated, non-successful signal for a validated pre-XCTest-start timeout.
# The caller may explicitly retry only this narrow class once.
PRESTART_XCTEST_TIMEOUT = 125


def unstarted_xctest_timeout_output(output: bytes, *, truncated: bool) -> bool:
    """Only classify a fully captured build-only attempt as pre-test stall.

    If XCTest has emitted any suite or case start banner, or evidence was
    truncated, never retry: real test execution may already have begun.
    """
    return (
        not truncated
        and b"Build complete!" in output
        and b"Test Suite '" not in output
        and b"Test Case '-[" not in output
    )



def verify_xctest_case_output(output: bytes, expected_cases: list[str]) -> bool:
    """Require an actual XCTest pass banner once for every selected method.

    SwiftPM may return zero when a --filter regex selects zero tests. Counting
    only process exit codes would silently omit required recovery scenarios.
    """
    if not expected_cases or len(set(expected_cases)) != len(expected_cases):
        return False
    lines = output.decode("utf-8", errors="replace").splitlines()
    passed = [
        line for line in lines
        if "Test Case '-[" in line and "]' passed" in line
    ]
    return all(
        sum(f"Test Case '-[{case}]' passed" in line for line in passed) == 1
        for case in expected_cases
    ) and len(passed) == len(expected_cases)


def run_bounded(
    command: list[str],
    deadline_seconds: int,
    *,
    expected_xctest_cases: list[str] | None = None,
) -> int:
    if deadline_seconds <= 0 or command[:2] != ["swift", "test"]:
        raise ValueError("only bounded 'swift test' executions are permitted")
    if expected_xctest_cases is not None and not expected_xctest_cases:
        raise ValueError("expected_xctest_cases cannot be empty")

    # For the filtered recovery batches only, capture output in a temporary,
    # private file, echo it unchanged after completion and verify actual cases.
    # Other XCTest shards retain their ordinary live stdout/stderr behavior.
    capture = tempfile.TemporaryFile(mode="w+b") if expected_xctest_cases else None
    try:
        process = subprocess.Popen(
            command,
            start_new_session=True,
            stdout=capture if capture else None,
            stderr=subprocess.STDOUT if capture else None,
        )
        try:
            try:
                status = process.wait(timeout=deadline_seconds)
            except subprocess.TimeoutExpired:
                print("AWL XCTest: subprocess deadline exceeded; collecting bounded diagnostics.",
                      file=sys.stderr)
                safe_stack_diagnostics(process.pid)
                status = 124
            except KeyboardInterrupt:
                print("AWL XCTest: interrupted.", file=sys.stderr)
                status = 130
        finally:
            stop_owned_group(process)

        if capture is not None:
            capture.seek(0)
            output = capture.read(_MAX_VERIFICATION_LOG_BYTES + 1)
            truncated = len(output) > _MAX_VERIFICATION_LOG_BYTES
            if truncated:
                output = output[:_MAX_VERIFICATION_LOG_BYTES]
            sys.stdout.buffer.write(output)
            sys.stdout.buffer.flush()
            if status == 0 and (
                truncated
                or not verify_xctest_case_output(output, expected_xctest_cases or [])
            ):
                print("AWL XCTest: selected test case execution proof missing or ambiguous.",
                      file=sys.stderr)
                return 1
            if status == 124 and unstarted_xctest_timeout_output(
                output, truncated=truncated
            ):
                print(
                    "AWL XCTest: bounded timeout before XCTest suite startup; "
                    "eligible for one explicitly logged complete retry.",
                    file=sys.stderr,
                )
                return PRESTART_XCTEST_TIMEOUT
        return status
    finally:
        if capture is not None:
            capture.close()

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Bound a macOS Swift XCTest subprocess.")
    parser.add_argument("--deadline-seconds", type=int, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    try:
        return run_bounded(command, args.deadline_seconds)
    except (ValueError, OSError):
        print("AWL XCTest: invalid or unavailable Swift test command.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
