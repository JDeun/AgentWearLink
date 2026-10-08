import unittest

from select_ios_simulator import select_iphone_simulator

OLD = "4E3A6BB3-F417-4829-8DF5-0EA652541F40"
NEW = "A1B2C3D4-E5F6-4A11-8111-112233445566"


class IOSSimulatorSelectionTests(unittest.TestCase):
    def inventory(self, booted=False):
        return {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
                {"name": "iPhone 17 Pro", "udid": OLD, "state": "Shutdown",
                 "isAvailable": True}
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                {"name": "iPhone 17", "udid": NEW,
                 "state": "Booted" if booted else "Shutdown",
                 "isAvailable": True}
            ],
        }}

    def test_newest_runtime_is_preferred_over_unstable_first_entry(self):
        self.assertEqual(select_iphone_simulator(self.inventory()), NEW)

    def test_booted_device_preferred_even_on_older_runtime(self):
        payload = self.inventory()
        payload["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-26-4"][0]["state"] = "Booted"
        self.assertEqual(select_iphone_simulator(payload), OLD)

    def test_unavailable_device_is_not_selected(self):
        payload = self.inventory()
        payload["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-26-5"][0]["isAvailable"] = False
        self.assertEqual(select_iphone_simulator(payload), OLD)

    def test_missing_invalid_and_non_iphone_devices_fail_closed(self):
        for payload in (
            {"devices": {}},
            {"devices": {"iOS-26-5": [{"name": "iPad Air", "udid": NEW}]}},
            {"devices": {"iOS-26-5": [{"name": "iPhone 17", "udid": "not-a-uuid"}]}},
        ):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                select_iphone_simulator(payload)


if __name__ == "__main__":
    unittest.main()
