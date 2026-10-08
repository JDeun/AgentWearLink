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
    if os.environ.get("AWL_DEV_GATEWAY_EXPECT_PAIRING") == "1":
        # A negative-contract smoke needs exactly one fresh read-only process.
        # Use a deliberately shorter limit; the macOS build already ran in
        # its own workflow step. A zero-test / hung SwiftPM process is no proof.
        if target != "awl-openclaw-probe":
            print("Negative pairing requires the read-only probe.", file=sys.stderr)
            return 2
        timeout = 60
    if os.environ.get("AWL_DEV_GATEWAY_USE_BUILT_PROBE") == "1":
        # Avoid launching SwiftPM (which can hang independently of Gateway)
        # after a separately verified swift build. Only these two targets
        # are accepted; no external binary path is read from environment.
        import pathlib
        executable = pathlib.Path(".build/debug") / target
        if not executable.is_file():
            print("Verified built development probe is missing.", file=sys.stderr)
            return 127
        command = [str(executable)]
    else:
        command = ["swift", "run", "--quiet", target]
    status = run_command(command, timeout_seconds=timeout)
    if os.environ.get("AWL_DEV_GATEWAY_EXPECT_PAIRING") == "1":
        category = {0: "unexpected-success", 3: "pairing-required",
                    124: "timeout", 127: "probe-unavailable"}.get(status, "other-failure")
        print("Isolated real Gateway negative probe category: " + category, file=sys.stderr)
    if status == 3:
        print("Development Gateway pairing approval required; inspect only the isolated Gateway.", file=sys.stderr)
    elif status not in (0, 124, 130):
        print("Development Gateway probe failed; output redacted.", file=sys.stderr)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
