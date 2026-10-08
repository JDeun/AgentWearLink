import contextlib
import io
import os
import signal
import subprocess
import sys
import unittest
from unittest.mock import call, patch

from dev_gateway_probe_runner import main, run_command, _stop_process_group


class DevelopmentGatewayProbeRunnerTests(unittest.TestCase):
    def test_successful_command(self):
        self.assertEqual(
            run_command([sys.executable, "-c", "print('private reply')"], timeout_seconds=5),
            0,
        )

    def test_nonzero_exit_does_not_log_untrusted_output(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            result = run_command(
                [sys.executable, "-c", "import sys; print('sensitive', file=sys.stderr); sys.exit(7)"],
                timeout_seconds=5,
            )
        self.assertEqual(result, 7)
        self.assertNotIn("sensitive", stderr.getvalue())

    def test_timeout_is_bounded_and_reports_only_a_stable_message(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            result = run_command(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                timeout_seconds=1,
            )
        self.assertEqual(result, 124)
        self.assertIn("deadline", stderr.getvalue())

    def test_parent_exit_still_cleans_private_process_group(self):
        class Exited:
            pid = 4444
            def poll(self):
                return 0
        with patch("dev_gateway_probe_runner.os.killpg") as kill_group:
            _stop_process_group(Exited())
            self.assertEqual(
                kill_group.call_args_list,
                [call(4444, signal.SIGTERM), call(4444, signal.SIGKILL)]
            )

    def test_empty_process_group_is_safe(self):
        class Exited:
            pid = 4444
            def poll(self):
                return 0
        with patch(
            "dev_gateway_probe_runner.os.killpg",
            side_effect=ProcessLookupError,
        ):
            _stop_process_group(Exited())

    def test_invalid_arguments_cannot_execute_an_arbitrary_target(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(main(["another-command"]), 2)
        self.assertIn("Usage:", stderr.getvalue())

    def test_nonpositive_deadline_is_rejected(self):
        with self.assertRaises(ValueError):
            run_command([sys.executable, "-c", "pass"], timeout_seconds=0)


if __name__ == "__main__":
    unittest.main()
