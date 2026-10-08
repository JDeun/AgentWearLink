import json
import subprocess
import unittest

from boot_ios_simulator import boot_with_deadline, query_state


class Clock:
    def __init__(self):
        self.now = 0.0

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def simulator_runner(states, *, hangs_on_boot=False):
    calls = []
    remaining = iter(states)

    def run(args, **kwargs):
        calls.append(args)
        if args[2] == "boot":
            if hangs_on_boot:
                raise subprocess.TimeoutExpired(args, timeout=35)
            return subprocess.CompletedProcess(args, 0, "", "")
        value = next(remaining, "Shutdown")
        payload = {"devices": {"iOS test runtime": [{"udid": "TEST-SIM", "state": value}]}}
        return subprocess.CompletedProcess(args, 0, json.dumps(payload), "")
    return run, calls


class BootIOSSimulatorTests(unittest.TestCase):
    def test_already_booted_does_not_restart_the_simulator(self):
        run, calls = simulator_runner(["Booted"])
        self.assertTrue(boot_with_deadline("TEST-SIM", runner=run))
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][2], "list")

    def test_hung_boot_command_can_still_result_in_booted_device(self):
        run, calls = simulator_runner(
            ["Shutdown", "Shutdown", "Booted"], hangs_on_boot=True
        )
        clock = Clock()
        self.assertTrue(
            boot_with_deadline(
                "TEST-SIM", runner=run, clock=clock.time, sleep=clock.sleep,
                budget_seconds=20,
            )
        )
        self.assertTrue(any(call[2] == "boot" for call in calls))

    def test_missing_device_never_falsely_reports_ready(self):
        def run(args, **kwargs):
            if args[2] == "boot":
                return subprocess.CompletedProcess(args, 1, "", "")
            return subprocess.CompletedProcess(args, 0, '{"devices":{}}', "")

        clock = Clock()
        self.assertFalse(
            boot_with_deadline(
                "TEST-SIM", runner=run, clock=clock.time, sleep=clock.sleep,
                budget_seconds=6,
            )
        )
        self.assertGreaterEqual(clock.now, 6)

    def test_malformed_simctl_output_is_not_treated_as_ready(self):
        def run(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, "not json", "")
        self.assertIsNone(query_state("TEST-SIM", runner=run))


if __name__ == "__main__":
    unittest.main()
