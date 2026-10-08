#!/usr/bin/env python3
"""Bound and sanitize opt-in real development-Gateway Swift smoke probes.

The Swift production probes own their network/session lifetimes. This wrapper
owns *process* lifetime so a wedged handshake or xctest-like teardown cannot
leave the operator's isolated Gateway harness running indefinitely.
"""
from __future__ import annotations

import os
import signal
import subprocess
import sys
from collections.abc import Sequence

_ALLOWED_TARGETS = frozenset({"awl-openclaw-probe", "awl-openclaw-chat-probe"})
_HEALTH_TIMEOUT_SECONDS = 300
_CHAT_TIMEOUT_SECONDS = 300
_TERMINATION_GRACE_SECONDS = 3


def _stop_process_group(process: subprocess.Popen[bytes]) -> None:
    """Reap our *entire private session* even if the Swift parent exited.

    A successful SwiftPM wrapper can outlive its own child test/probe process
    group. Never leave an owned descendant attached to the next health probe.
    """
    parent_running = process.poll() is None
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    if parent_running:
        try:
            process.wait(timeout=_TERMINATION_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    if process.poll() is None:
        process.wait()


def run_command(command: Sequence[str], *, timeout_seconds: int) -> int:
    """Return a stable status without forwarding untrusted Gateway output."""
    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be positive")
    try:
        process = subprocess.Popen(
            list(command),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        print("Development Gateway probe process could not start.", file=sys.stderr)
        return 127

    try:
        try:
            return process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            print("Development Gateway probe exceeded its process deadline.", file=sys.stderr)
            return 124
    except KeyboardInterrupt:
        print("Development Gateway probe interrupted.", file=sys.stderr)
        return 130
    finally:
        _stop_process_group(process)


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 1 or args[0] not in _ALLOWED_TARGETS:
        print("Usage: dev_gateway_probe_runner.py <health|chat Swift target>", file=sys.stderr)
        return 2
    target = args[0]
    timeout = _CHAT_TIMEOUT_SECONDS if target == "awl-openclaw-chat-probe" else _HEALTH_TIMEOUT_SECONDS
    status = run_command(["swift", "run", "--quiet", target], timeout_seconds=timeout)
    if status == 3:
        print("Development Gateway pairing approval required; inspect only the isolated Gateway.", file=sys.stderr)
    elif status not in (0, 124, 130):
        print("Development Gateway probe failed; output redacted.", file=sys.stderr)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
