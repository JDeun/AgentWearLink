import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from run_openclaw_remaining_tests import (
    ISOLATED_CLASSES,
    PER_METHOD_GROUP_DEADLINE_SECONDS,
    PRESTART_XCTEST_TIMEOUT,
    METHOD_GROUP_SIZE,
    method_batches,
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

    def test_method_batches_cover_every_method_exactly_once(self):
        methods = [f"testCase{x}" for x in range(13)]
        batches = method_batches("OpenClawRecoveryMatrixTests", methods)
        self.assertEqual(len(batches), 5)
        self.assertEqual([name for names, _ in batches for name in names], methods)
        for names, pattern in batches:
            self.assertLessEqual(len(names), METHOD_GROUP_SIZE)
            import re
            for method in methods:
                full_name = (
                    "AgentWearLinkOpenClawTests.OpenClawRecoveryMatrixTests." + method
                )
                self.assertEqual(bool(re.search(pattern, full_name)), method in names)
                slash_name = (
                    "AgentWearLinkOpenClawTests/OpenClawRecoveryMatrixTests/" + method
                )
                self.assertEqual(bool(re.search(pattern, slash_name)), method in names)

    def test_method_batch_failure_fails_fast_without_retrying(self):
        methods = [f"testCase{x}" for x in range(4)]
        with (
            patch("run_openclaw_remaining_tests.discover_remaining",
                  return_value=["OpenClawRecoveryMatrixTests"]),
            patch("run_openclaw_remaining_tests.discover_method_shards",
                  return_value=methods),
            patch("run_openclaw_remaining_tests.run_bounded",
                  side_effect=[0, 124]) as run,
        ):
            self.assertEqual(main(), 124)
            self.assertEqual(run.call_count, 2)
            self.assertEqual(
                run.call_args.args,
                (["swift", "test", "--filter",
                  "AgentWearLinkOpenClawTests[./]OpenClawRecoveryMatrixTests"
                  "[./](?:testCase3)$"],
                 PER_METHOD_GROUP_DEADLINE_SECONDS),
            )

    def test_pre_suite_timeout_retries_only_the_same_complete_batch_once(self):
        methods = ["testCaseOne", "testCaseTwo"]
        with (
            patch("run_openclaw_remaining_tests.discover_remaining",
                  return_value=["OpenClawRecoveryMatrixTests"]),
            patch("run_openclaw_remaining_tests.discover_method_shards",
                  return_value=methods),
            patch("run_openclaw_remaining_tests.run_bounded",
                  side_effect=[PRESTART_XCTEST_TIMEOUT, 0]) as run,
        ):
            self.assertEqual(main(), 0)
            self.assertEqual(run.call_count, 2)
            self.assertEqual(run.call_args_list[0], run.call_args_list[1])
            self.assertEqual(
                run.call_args.kwargs["expected_xctest_cases"],
                ["AgentWearLinkOpenClawTests.OpenClawRecoveryMatrixTests testCaseOne",
                 "AgentWearLinkOpenClawTests.OpenClawRecoveryMatrixTests testCaseTwo"]
            )

    def test_repeated_pre_suite_timeout_fails_without_unbounded_retry(self):
        with (
            patch("run_openclaw_remaining_tests.discover_remaining",
                  return_value=["OpenClawRecoveryMatrixTests"]),
            patch("run_openclaw_remaining_tests.discover_method_shards",
                  return_value=["testCaseOne"]),
            patch("run_openclaw_remaining_tests.run_bounded",
                  side_effect=[PRESTART_XCTEST_TIMEOUT, PRESTART_XCTEST_TIMEOUT]) as run,
        ):
            self.assertEqual(main(), PRESTART_XCTEST_TIMEOUT)
            self.assertEqual(run.call_count, 2)

    def test_repeated_pre_suite_batch_stall_requires_every_single_method_pass(self):
        methods = ["testCaseA", "testCaseB", "testCaseC"]
        with (
            patch("run_openclaw_remaining_tests.discover_remaining",
                  return_value=["OpenClawRecoveryMatrixTests"]),
            patch("run_openclaw_remaining_tests.discover_method_shards",
                  return_value=methods),
            patch("run_openclaw_remaining_tests.run_bounded",
                  side_effect=[PRESTART_XCTEST_TIMEOUT, PRESTART_XCTEST_TIMEOUT, 0, 0, 0]) as run,
        ):
            self.assertEqual(main(), 0)
            self.assertEqual(run.call_count, 5)
            self.assertEqual(run.call_args_list[0], run.call_args_list[1])
            recovered = run.call_args_list[2:]
            for i, single in enumerate(methods):
                self.assertEqual(
                    recovered[i].kwargs["expected_xctest_cases"],
                    [f"AgentWearLinkOpenClawTests.OpenClawRecoveryMatrixTests {single}"],
                )
            self.assertEqual(
                len({item.args[0][-1] for item in recovered}), 3
            )

    def test_single_method_fallback_fails_closed_on_real_failure(self):
        methods = ["testCaseA", "testCaseB", "testCaseC"]
        with (
            patch("run_openclaw_remaining_tests.discover_remaining",
                  return_value=["OpenClawRecoveryMatrixTests"]),
            patch("run_openclaw_remaining_tests.discover_method_shards",
                  return_value=methods),
            patch("run_openclaw_remaining_tests.run_bounded",
                  side_effect=[PRESTART_XCTEST_TIMEOUT, PRESTART_XCTEST_TIMEOUT, 0, 1]) as run,
        ):
            self.assertEqual(main(), 1)
            self.assertEqual(run.call_count, 4)

    def test_single_method_fallback_retries_only_pre_suite_stall(self):
        methods = ["testCaseA", "testCaseB"]
        with (
            patch("run_openclaw_remaining_tests.discover_remaining",
                  return_value=["OpenClawRecoveryMatrixTests"]),
            patch("run_openclaw_remaining_tests.discover_method_shards",
                  return_value=methods),
            patch("run_openclaw_remaining_tests.run_bounded",
                  side_effect=[PRESTART_XCTEST_TIMEOUT, PRESTART_XCTEST_TIMEOUT,
                               PRESTART_XCTEST_TIMEOUT, 0, 0]) as run,
        ):
            self.assertEqual(main(), 0)
            self.assertEqual(run.call_count, 5)
            self.assertEqual(run.call_args_list[2], run.call_args_list[3])

    def test_method_batches_refuse_duplicate_or_untrusted_names(self):
        for names in ([], ["testGood", "testGood"], ["testBad|Other"]):
            with self.assertRaises(ValueError):
                method_batches("OpenClawRecoveryMatrixTests", names)
        for size in (0, -1, METHOD_GROUP_SIZE + 1):
            with self.assertRaises(ValueError):
                method_batches("OpenClawRecoveryMatrixTests", ["testGood"], group_size=size)


if __name__ == "__main__":
    unittest.main()
