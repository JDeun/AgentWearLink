"""Offline tests for scripts/verify-openclaw-protocol-contract.py (no network)."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).with_name("verify-openclaw-protocol-contract.py")
spec = importlib.util.spec_from_file_location("verify_contract", SCRIPT)
verify_contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_contract)

# chat.abort as published by OpenClaw 2026.9.6 (eb377ac5): no discardPendingInput.
ABORT_2026_9_6 = """export const ChatAbortParamsSchema = closedObject({
  sessionKey: NonEmptyString,
  agentId: Type.Optional(NonEmptyString),
  runId: Type.Optional(NonEmptyString),
  preserveSideRuns: Type.Optional(Type.Boolean()),
});
export const ChatInjectParamsSchema = closedObject({});"""

ABORT_WITHOUT_RUN_ID = """export const ChatAbortParamsSchema = closedObject({
  sessionKey: NonEmptyString,
  agentId: Type.Optional(NonEmptyString),
});
export const ChatInjectParamsSchema = closedObject({});"""


class AbortSurfaceTests(unittest.TestCase):
    def test_accepts_release_without_fields_awl_never_encodes(self):
        verify_contract.check_chat_abort(verify_contract.compact(ABORT_2026_9_6))

    def test_rejects_release_missing_a_field_awl_encodes(self):
        with self.assertRaisesRegex(AssertionError, "runId"):
            verify_contract.check_chat_abort(verify_contract.compact(ABORT_WITHOUT_RUN_ID))

    def test_checked_fields_match_what_the_swift_client_encodes(self):
        swift = (Path(__file__).resolve().parents[1]
                 / "Sources/AgentWearLinkOpenClaw/OpenClawAgentRun.swift").read_text()
        body = swift.split("public struct OpenClawChatAbortParams", 1)[1].split("public init", 1)[0]
        encoded = {line.split("let ", 1)[1].split(":", 1)[0].strip()
                   for line in body.splitlines() if "public let " in line}
        self.assertEqual(encoded, {f.rstrip(":") for f in verify_contract.CHAT_ABORT_ENCODED_FIELDS})


class CommitSelectionTests(unittest.TestCase):
    def test_defaults_to_pinned_commit(self):
        self.assertEqual(verify_contract.parse_commit([]), verify_contract.UPSTREAM_COMMIT)

    def test_accepts_full_sha_override(self):
        sha = "eb377ac59e6c9fd6c7705028034812becf00271b"
        self.assertEqual(verify_contract.parse_commit(["--commit", sha]), sha)

    def test_rejects_short_or_symbolic_refs(self):
        for bad in ("eb377ac", "main", "v2026.10.2"):
            with self.assertRaises(SystemExit):
                verify_contract.parse_commit(["--commit", bad])

    def test_fetch_uses_requested_commit(self):
        seen = []

        class Resp:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return b"x"

        def fake_urlopen(url, timeout):
            seen.append(url)
            return Resp()

        with mock.patch.object(verify_contract.urllib.request, "urlopen", fake_urlopen):
            verify_contract.fetch("a/b.ts", commit="0" * 40)
        self.assertIn("/" + "0" * 40 + "/a/b.ts", seen[0])


if __name__ == "__main__":
    unittest.main()
