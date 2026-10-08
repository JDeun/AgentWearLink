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


def run_bounded(command: list[str], deadline_seconds: int) -> int:
    if deadline_seconds <= 0 or command[:2] != ["swift", "test"]:
        raise ValueError("only bounded 'swift test' executions are permitted")
    process = subprocess.Popen(command, start_new_session=True)
    try:
        try:
            return process.wait(timeout=deadline_seconds)
        except subprocess.TimeoutExpired:
            print("AWL XCTest: subprocess deadline exceeded; collecting bounded diagnostics.", file=sys.stderr)
            safe_stack_diagnostics(process.pid)
            return 124
        except KeyboardInterrupt:
            print("AWL XCTest: interrupted.", file=sys.stderr)
            return 130
    finally:
        stop_owned_group(process)


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
