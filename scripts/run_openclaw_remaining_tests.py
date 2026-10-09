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
from swift_xctest_watchdog import PRESTART_XCTEST_TIMEOUT, run_bounded

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
# GitHub job. Only verified pre-suite stalls get one visible bounded
# re-execution; actual test failures and partially executed timeouts do not.
PER_CLASS_DEADLINE_SECONDS = 65
# Multiple XCTest launches occasionally stall before even starting a test.
# Group a few *complete* method names per process to reduce process churn,
# retaining deterministic coverage and bounded failure attribution.
# Never replay tests that have started. Track macOS 26 pre-suite stalls in #601.
PER_METHOD_GROUP_DEADLINE_SECONDS = 55
METHOD_GROUP_SIZE = 3
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


def method_batches(
    name: str, methods: list[str], *,
    group_size: int = METHOD_GROUP_SIZE
) -> list[tuple[list[str], str]]:
    """Partition each discovered XCTest method exactly once into regex filters.

    SwiftPM supports regex --filter; [./] accepts its module/class separator
    variants. Never match a prefix of another test method.
    """
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        raise ValueError("Invalid XCTest class identifier")
    if not methods or len(set(methods)) != len(methods):
        raise ValueError("Missing or duplicate XCTest methods")
    if not (1 <= group_size <= METHOD_GROUP_SIZE):
        raise ValueError("Invalid XCTest batch group size")
    if any(re.fullmatch(r"test[A-Za-z0-9_]+", method) is None for method in methods):
        raise ValueError("Invalid XCTest method name")
    batches: list[tuple[list[str], str]] = []
    for offset in range(0, len(methods), group_size):
        names = methods[offset:offset + group_size]
        pattern = (
            r"AgentWearLinkOpenClawTests[./]" + name +
            r"[./](?:" + "|".join(names) + r")$"
        )
        batches.append((names, pattern))
    return batches


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
            try:
                batches = method_batches(name, methods)
            except ValueError as error:
                print("OpenClaw XCTest method batch error: " + str(error),
                      file=sys.stderr)
                return 2
            print(f"OpenClaw XCTest class {index}/{len(classes)}: {name} "
                  f"({len(methods)} tests in {len(batches)} bounded batches)",
                  flush=True)
            for batch_index, (names, test_filter) in enumerate(batches, start=1):
                # Print only checked-in test method identifiers, never content.
                print(f"OpenClaw XCTest batch {batch_index}/{len(batches)}: "
                      f"{name}: {', '.join(names)}", flush=True)
                command = ["swift", "test", "--filter", test_filter]
                expected = [
                    f"AgentWearLinkOpenClawTests.{name} {method}"
                    for method in names
                ]
                code = run_bounded(
                    command, PER_METHOD_GROUP_DEADLINE_SECONDS,
                    expected_xctest_cases=expected,
                )
                if code == PRESTART_XCTEST_TIMEOUT:
                    # The first process never emitted an XCTest suite/case
                    # banner, and watchdog retired its entire owned group.
                    # Never retry actual test failures or partial test runs.
                    print(
                        "OpenClaw XCTest pre-suite stall: retrying the full "
                        f"{name} batch once with unchanged filters.",
                        flush=True,
                    )
                    code = run_bounded(
                        command, PER_METHOD_GROUP_DEADLINE_SECONDS,
                        expected_xctest_cases=expected,
                    )
                if code == PRESTART_XCTEST_TIMEOUT and len(names) > 1:
                    # A second full-batch pre-suite stall is not evidence of
                    # passing. Bisect into *every* exact test-method filter;
                    # require each method's own successful XCTest banner.
                    # Fail on any started-test failure or repeated unstarted
                    # method. Never waive one test or retry a partial run.
                    print(
                        "OpenClaw XCTest batch failed to start twice: "
                        "isolating every selected method with strict proof.",
                        flush=True,
                    )
                    code = 0
                    for single_names, single_filter in method_batches(
                        name, names, group_size=1
                    ):
                        single = single_names[0]
                        single_command = ["swift", "test", "--filter", single_filter]
                        single_expected = [
                            f"AgentWearLinkOpenClawTests.{name} {single}"
                        ]
                        code = run_bounded(
                            single_command, PER_METHOD_GROUP_DEADLINE_SECONDS,
                            expected_xctest_cases=single_expected,
                        )
                        if code == PRESTART_XCTEST_TIMEOUT:
                            print(
                                "OpenClaw XCTest single method pre-suite stall: "
                                f"one bounded retry for {name}.{single}.",
                                flush=True,
                            )
                            code = run_bounded(
                                single_command, PER_METHOD_GROUP_DEADLINE_SECONDS,
                                expected_xctest_cases=single_expected,
                            )
                        if code != 0:
                            print(
                                "OpenClaw XCTest isolated method failed: "
                                f"{name}.{single}; exit={code}",
                                file=sys.stderr,
                            )
                            break
                if code != 0:
                    print(f"OpenClaw XCTest batch failed or timed out: "
                          f"{name}: {', '.join(names)}; exit={code}",
                          file=sys.stderr)
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
