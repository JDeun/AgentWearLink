import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from run_openclaw_remaining_tests import (
    ISOLATED_CLASSES,
    PER_METHOD_DEADLINE_SECONDS,
    discover_method_shards,
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

    def test_method_shards_cover_each_declared_test_exactly_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_source(
                root, "OpenClawRecoveryMatrixTests",
                "final class OpenClawRecoveryMatrixTests: XCTestCase {\n"
                "    func testReconnect() async throws {}\n"
                "    func testStop() async throws {}\n"
                "}\n",
            )
            self.assertEqual(
                discover_method_shards(root, "OpenClawRecoveryMatrixTests"),
                ["testReconnect", "testStop"],
            )

    def test_method_shards_fail_closed_for_duplicate_methods(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_source(
                root, "OpenClawRecoveryMatrixTests",
                "final class OpenClawRecoveryMatrixTests: XCTestCase {\n"
                "    func testReconnect() {}\n"
                "    func testReconnect() {}\n"
                "}\n",
            )
            with self.assertRaises(ValueError):
                discover_method_shards(root, "OpenClawRecoveryMatrixTests")

    def test_stops_on_first_failed_or_timed_out_test_class(self):
        with (
            patch("run_openclaw_remaining_tests.METHOD_ISOLATED_CLASSES", frozenset()),
            patch("run_openclaw_remaining_tests.discover_remaining",
                  return_value=["ATests", "BTests"]),
            patch("run_openclaw_remaining_tests.run_bounded",
                  side_effect=[0, 124]) as run,
        ):
            self.assertEqual(main(), 124)
            self.assertEqual(run.call_count, 2)

    def test_method_shard_failure_names_the_specific_method(self):
        with (
            patch("run_openclaw_remaining_tests.discover_remaining",
                  return_value=["OpenClawRecoveryMatrixTests"]),
            patch("run_openclaw_remaining_tests.discover_method_shards",
                  return_value=["testReconnect", "testStop"]),
            patch("run_openclaw_remaining_tests.run_bounded",
                  side_effect=[0, 124]) as run,
        ):
            self.assertEqual(main(), 124)
            self.assertEqual(run.call_count, 2)
            self.assertEqual(
                run.call_args.args,
                (["swift", "test", "--filter",
                  "AgentWearLinkOpenClawTests.OpenClawRecoveryMatrixTests.testStop"],
                 PER_METHOD_DEADLINE_SECONDS),
            )


if __name__ == "__main__":
    unittest.main()
