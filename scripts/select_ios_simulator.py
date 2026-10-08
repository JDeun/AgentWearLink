#!/usr/bin/env python3
"""Choose a real available iPhone simulator, preferring already-booted devices.

If no iPhone has been booted, prefer the highest available iOS runtime instead
of taking the first (often older or broken) entry returned by simctl.
"""
from __future__ import annotations

import json
import re
import sys


def select_iphone_simulator(payload: dict) -> str:
    candidates: list[tuple[bool, tuple[int, ...], str, str]] = []
    for runtime, devices in payload.get("devices", {}).items():
        version = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
        if not version or not isinstance(devices, list):
            continue
        runtime_version = tuple(
            int(part) for part in version.groups() if part is not None
        )
        for device in devices:
            if not isinstance(device, dict):
                continue
            name = device.get("name", "")
            udid = device.get("udid", "")
            if (
                not isinstance(name, str)
                or not name.startswith("iPhone")
                or not isinstance(udid, str)
                or not re.fullmatch(r"[0-9A-Fa-f-]{30,40}", udid)
                or device.get("isAvailable", True) is not True
            ):
                continue
            candidates.append((
                device.get("state") == "Booted",
                runtime_version,
                name,
                udid,
            ))
    if not candidates:
        raise ValueError("No available iPhone simulator with a valid UDID")
    # Existing Booted devices avoid expensive/fragile cold boot. Otherwise,
    # choose the latest installed iOS runtime, keeping tie-break deterministic.
    return max(candidates)[-1]


def main() -> int:
    try:
        print(select_iphone_simulator(json.load(sys.stdin)))
        return 0
    except (ValueError, TypeError, json.JSONDecodeError):
        print("No usable iPhone simulator in simctl inventory.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
