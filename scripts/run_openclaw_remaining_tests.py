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
# A previously hanging test class is further sharded by *method* so that
# a stalled XCTest process identifies its exact scenario, not just its class.
PER_METHOD_DEADLINE_SECONDS = 30
METHOD_ISOLATED_CLASSES = frozenset({"OpenClawRecoveryMatrixTests"})
METHOD_DECLARATION = re.compile(r"(?m)^\s*func\s+(test[A-Za-z0-9_]+)\s*\(")
SUITE_ROOT = Path("Tests/AgentWearLinkOpenClawTests")
DECLARATION = re.compile(
    r"\bclass\s+(\w+)\s*:\s*XCTestCase\b"
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


def discover_method_shards(root: Path, name: str) -> list[str]:
    """Discover every XCTest method in a method-isolated class.

    Fail closed if the expected source changes; never silently drop a method.
    """
    source = (root / (name + ".swift")).read_text(encoding="utf-8")
    if len(DECLARATION.findall(source)) != 1 or DECLARATION.findall(source)[0] != name:
        raise ValueError("Ambiguous method-isolated XCTest source: " + name)
    methods = METHOD_DECLARATION.findall(source)
    if not methods or len(methods) != len(set(methods)):
        raise ValueError("Missing or duplicate XCTest method: " + name)
    return sorted(methods)


def main() -> int:
    try:
        classes = discover_remaining(SUITE_ROOT)
        if not METHOD_ISOLATED_CLASSES.issubset(set(classes)):
            raise ValueError("Method-isolated class excluded from remaining tests")
        method_shards = {
            name: discover_method_shards(SUITE_ROOT, name)
            for name in METHOD_ISOLATED_CLASSES
        }
    except (OSError, ValueError) as error:
        print("OpenClaw XCTest discovery error: " + str(error), file=sys.stderr)
        return 2
    print("OpenClaw remaining XCTest classes:", len(classes), flush=True)
    for index, name in enumerate(classes, start=1):
        # Test names originate in trusted checked-out sources and are validated
        # as identifiers, never interpreted by a shell.
        methods = method_shards.get(name)
        if methods is not None:
            print(f"OpenClaw XCTest class {index}/{len(classes)}: {name} "
                  f"({len(methods)} method-isolated tests)", flush=True)
            for method_index, method in enumerate(methods, start=1):
                test = f"AgentWearLinkOpenClawTests.{name}.{method}"
                print(f"OpenClaw XCTest method {method_index}/{len(methods)}: "
                      f"{name}.{method}", flush=True)
                code = run_bounded(
                    ["swift", "test", "--filter", test],
                    PER_METHOD_DEADLINE_SECONDS,
                )
                if code != 0:
                    print(f"OpenClaw XCTest method failed or timed out: "
                          f"{name}.{method}; exit={code}", file=sys.stderr)
                    return code
            continue
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
