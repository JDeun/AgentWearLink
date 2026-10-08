#!/usr/bin/env python3
"""Run every remaining OpenClaw XCTest class in its own bounded Swift process.

Do not shrink test coverage to mask macOS XCTest hangs. A test class added to
this target is discovered on the next CI run instead of silently falling into
a growing, cross-suite catch-all process.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path
from swift_xctest_watchdog import run_bounded

ISOLATED_CLASSES = frozenset({
    "OpenClawProtocolTests",
    "OpenClawRPCDispatcherTests",
    "OpenClawNativeAgentAdapterTests",
    "OpenClawRPCRegistryTests",
    "OpenClawGatewayConnectionTests",
    "OpenClawGatewayStateTests",
    "OpenClawPairingTests",
})
# Keep this short enough that a single hanging suite cannot exhaust the
# GitHub job. The first timeout exits nonzero; retries are never automatic.
PER_CLASS_DEADLINE_SECONDS = 65
SUITE_ROOT = Path("Tests/AgentWearLinkOpenClawTests")
DECLARATION = re.compile(
    r"\\bclass\\s+(\\w+)\\s*:\\s*XCTestCase\\b"
)


def discover_remaining(root: Path) -> list[str]:
    if not root.is_dir():
        raise ValueError("OpenClaw test source directory missing")
    found: set[str] = set()
    for path in sorted(root.glob("*.swift")):
        if path.name == "TestSynchronization.swift":
            continue
        source = path.read_text(encoding="utf-8")
        classes = DECLARATION.findall(source)
        if not classes:
            raise ValueError("OpenClaw test source lacks an XCTestCase: " + path.name)
        for name in classes:
            if name in found:
                raise ValueError("Duplicate OpenClaw XCTest class name: " + name)
            found.add(name)
    missing = ISOLATED_CLASSES - found
    if missing:
        raise ValueError("An explicitly isolated XCTest class disappeared: " + ", ".join(sorted(missing)))
    remainder = sorted(found - ISOLATED_CLASSES)
    if not remainder:
        raise ValueError("OpenClaw XCTest discovery returned no remaining tests")
    return remainder


def main() -> int:
    try:
        classes = discover_remaining(SUITE_ROOT)
    except (OSError, ValueError) as error:
        print("OpenClaw XCTest discovery error: " + str(error), file=sys.stderr)
        return 2
    print("OpenClaw remaining XCTest classes:", len(classes), flush=True)
    for index, name in enumerate(classes, start=1):
        # Test names originate in trusted checked-out sources and are validated
        # as identifiers, never interpreted by a shell.
        print(f"OpenClaw XCTest class {index}/{len(classes)}: {name}", flush=True)
        code = run_bounded(
            ["swift", "test", "--filter", f"AgentWearLinkOpenClawTests.{name}"],
            PER_CLASS_DEADLINE_SECONDS,
        )
        if code != 0:
            print(f"OpenClaw XCTest class failed or timed out: {name}; exit={code}", file=sys.stderr)
            return code
    print("All discovered remaining OpenClaw XCTest classes passed.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
