import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from run_openclaw_remaining_tests import (
    ISOLATED_CLASSES,
    discover_remaining,
    main,
)


class RemainingOpenClawXCTestShardsTests(unittest.TestCase):
    def make_source(self, root: Path, name: str, declaration: str) -> None:
        (root / (name + ".swift")).write_text(declaration, encoding="utf-8")

    def test_all_sources_partitioned_without_duplicate_suites(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for class_name in ISOLATED_CLASSES:
                self.make_source(root, class_name, f"final class {class_name}: XCTestCase {{}}")
            self.make_source(root, "Extra", "final class ExtraTests: XCTestCase {}")
            self.assertEqual(discover_remaining(root), ["ExtraTests"])

    def test_new_test_without_xctest_discovery_is_not_silently_skipped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for class_name in ISOLATED_CLASSES:
                self.make_source(root, class_name, f"final class {class_name}: XCTestCase {{}}")
            self.make_source(root, "New", "struct NewTests {}")
            with self.assertRaises(ValueError):
                discover_remaining(root)

    def test_duplicate_test_class_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for class_name in ISOLATED_CLASSES:
                self.make_source(root, class_name, f"final class {class_name}: XCTestCase {{}}")
            self.make_source(root, "One", "final class ExtraTests: XCTestCase {}")
            self.make_source(root, "Two", "final class ExtraTests: XCTestCase {}")
            with self.assertRaises(ValueError):
                discover_remaining(root)

    def test_rejects_missing_explicit_class(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_source(root, "Extra", "final class ExtraTests: XCTestCase {}")
            with self.assertRaises(ValueError):
                discover_remaining(root)

    def test_stops_on_first_failed_or_timed_out_test_class(self):
        with (
            patch("run_openclaw_remaining_tests.discover_remaining",
                  return_value=["ATests", "BTests"]),
            patch("run_openclaw_remaining_tests.run_bounded",
                  side_effect=[0, 124]) as run,
        ):
            self.assertEqual(main(), 124)
            self.assertEqual(run.call_count, 2)


if __name__ == "__main__":
    unittest.main()
