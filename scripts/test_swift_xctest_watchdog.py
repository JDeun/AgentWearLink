import contextlib
import io
import signal
import sys
import unittest
from unittest.mock import call, patch

from swift_xctest_watchdog import (
    main,
    parse_process_table,
    run_bounded,
    sample_categories,
    select_xctest_descendant,
)


class SwiftXCTestWatchdogTests(unittest.TestCase):
    def test_parses_process_table_and_finds_nested_xctest(self):
        table = parse_process_table(
            "100 1 /usr/bin/python3\n"
            "101 100 /usr/bin/swift\n"
            "102 101 /Applications/Xcode.app/Contents/Developer/usr/bin/xctest\n"
            "103 1 /usr/bin/xctest\n"
            "invalid row\n"
        )
        self.assertEqual(select_xctest_descendant(100, table), 102)
        self.assertEqual(select_xctest_descendant(103, table), 103)

    def test_reports_only_fixed_marker_categories(self):
        output = "AgentWearLinkOpenClaw.secret=token\nXCTest\npthread\n"
        self.assertEqual(
            sample_categories(output),
            {"AgentWearLink": 1, "OpenClaw": 1, "XCTest": 1, "pthread": 1},
        )

    def test_rejects_non_swift_or_invalid_deadline(self):
        with self.assertRaises(ValueError):
            run_bounded([sys.executable, "-c", "pass"], 1)
        with self.assertRaises(ValueError):
            run_bounded(["swift", "test"], 0)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(main(["--deadline-seconds", "1", "--", "python", "-V"]), 2)

    def test_success_and_nonzero_exit_preserved(self):
        class Process:
            pid = 123
            def __init__(self, status):
                self.status = status
            def wait(self, timeout=None):
                return self.status
            def poll(self):
                return self.status
        # Even a completed SwiftPM process owns a process group; a lingering
        # XCTest child must not be left alive when the parent returns 0.
        with (
            patch("swift_xctest_watchdog.subprocess.Popen", return_value=Process(0)),
            patch("swift_xctest_watchdog.os.killpg") as kill_group,
        ):
            self.assertEqual(run_bounded(["swift", "test", "--filter", "Suite"], 1), 0)
            self.assertEqual(
                kill_group.call_args_list,
                [call(123, signal.SIGTERM), call(123, signal.SIGKILL)],
            )
        with (
            patch("swift_xctest_watchdog.subprocess.Popen", return_value=Process(9)),
            patch("swift_xctest_watchdog.os.killpg") as kill_group,
        ):
            self.assertEqual(run_bounded(["swift", "test"], 1), 9)
            self.assertEqual(kill_group.call_count, 2)

    def test_empty_process_group_does_not_override_original_exit(self):
        class Process:
            pid = 777
            def wait(self, timeout=None):
                return 0
            def poll(self):
                return 0
        with (
            patch("swift_xctest_watchdog.subprocess.Popen", return_value=Process()),
            patch("swift_xctest_watchdog.os.killpg", side_effect=ProcessLookupError),
        ):
            self.assertEqual(run_bounded(["swift", "test"], 1), 0)

    def test_expired_deadline_invokes_diagnostics_before_cleanup(self):
        from subprocess import TimeoutExpired
        class Process:
            pid = 321
            def wait(self, timeout=None):
                raise TimeoutExpired("swift", timeout)
            def poll(self):
                return None
        order = []
        with (
            patch("swift_xctest_watchdog.subprocess.Popen", return_value=Process()),
            patch("swift_xctest_watchdog.safe_stack_diagnostics", side_effect=lambda _: order.append("sample")),
            patch("swift_xctest_watchdog.stop_owned_group", side_effect=lambda _: order.append("stop")),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(run_bounded(["swift", "test"], 1), 124)
        self.assertEqual(order, ["sample", "stop"])


if __name__ == "__main__":
    unittest.main()
