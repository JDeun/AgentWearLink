#!/usr/bin/env python3
"""Bound macOS runner simctl boot independently of simulator readiness polling.

On hosted runners, simctl boot can block after a simulator is already Booted.
This script uses no physical device and reads no credentials.
"""
from __future__ import annotations

import json
import subprocess
import sys
import time


def query_state(udid: str, *, runner=subprocess.run) -> str | None:
    try:
        result = runner(
            ["xcrun", "simctl", "list", "devices", "available", "-j"],
            capture_output=True,
            text=True,
            timeout=12,
            check=False,
        )
        if result.returncode:
            return None
        devices = json.loads(result.stdout).get("devices", {})
        for runtime in devices.values():
            for device in runtime:
                if device.get("udid") == udid:
                    return device.get("state")
    except (subprocess.TimeoutExpired, ValueError, TypeError, OSError):
        return None
    return None


def boot_with_deadline(
    udid: str,
    *,
    runner=subprocess.run,
    clock=time.monotonic,
    sleep=time.sleep,
    budget_seconds: float = 240,
) -> bool:
    deadline = clock() + budget_seconds
    if query_state(udid, runner=runner) == "Booted":
        return True

    # simctl boot may block despite the device finishing boot. A CLI timeout
    # does not stop CoreSimulatorService's independently running boot.
    try:
        runner(
            ["xcrun", "simctl", "boot", udid],
            capture_output=True,
            text=True,
            timeout=35,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        pass

    # Individual polls are bounded, not just the enclosing workflow step.
    while clock() < deadline:
        if query_state(udid, runner=runner) == "Booted":
            return True
        sleep(min(2, max(0, deadline - clock())))
    return False


def main(argv: list[str]) -> int:
    if len(argv) != 2 or not argv[1].strip():
        print("Usage: boot_ios_simulator.py SIMULATOR_UDID", file=sys.stderr)
        return 2
    udid = argv[1].strip()
    if boot_with_deadline(udid):
        print("Selected iPhone simulator reached Booted state.")
        return 0
    print("Selected iPhone simulator did not boot within the bounded CI deadline.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
