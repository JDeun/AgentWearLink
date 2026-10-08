import os
import unittest

from dev_gateway_preflight import validate_config


class DevelopmentGatewayPreflightTests(unittest.TestCase):
    def setUp(self):
        self.valid = {
            "AWL_ALLOW_DEV_GATEWAY_TEST": "1",
            "AWL_OPENCLAW_URL": "ws://127.0.0.1:18789",
            "AWL_OPENCLAW_TOKEN": "synthetic-dev-only-token",
            "AWL_OPENCLAW_SESSION_KEY": "agent:main:awl-dev-isolated",
            "AWL_DEV_GATEWAY_REVISION": "a" * 40,
            "AWL_OPENCLAW_EXPOSURE": "loopback",
        }

    def test_accepts_explicit_isolated_loopback(self):
        self.assertEqual(validate_config(self.valid)["session_key_kind"], "explicit-isolated")

    def test_rejects_remote_and_tailnet_urls(self):
        for url in ["wss://mac-mini.ts.net", "ws://100.100.1.1:18789", "ws://8.8.8.8:18789"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                validate_config({**self.valid, "AWL_OPENCLAW_URL": url})

    def test_rejects_credential_bearing_urls(self):
        for url in ["ws://user:password@127.0.0.1:18789", "ws://127.0.0.1:18789/?token=secret"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                validate_config({**self.valid, "AWL_OPENCLAW_URL": url})

    def test_rejects_mutation_without_explicit_opt_in(self):
        with self.assertRaises(ValueError):
            validate_config({**self.valid, "AWL_ALLOW_DEV_GATEWAY_TEST": "0"})

    def test_abort_proof_requires_exact_opt_in_and_script_owned_flag(self):
        self.assertEqual(
            validate_config({
                **self.valid, "AWL_DEV_GATEWAY_PROVE_ABORT": "1"
            })["session_key_kind"],
            "explicit-isolated",
        )
        for change in [
            {"AWL_DEV_GATEWAY_PROVE_ABORT": "true"},
            {"AWL_DEV_GATEWAY_PROVE_ABORT": "2"},
            {"AWL_DEV_GATEWAY_ABORT_ASSERT": "1"},
        ]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_config({**self.valid, **change})

    def test_health_only_and_disposable_keychain_are_explicit(self):
        approved = {
            **self.valid,
            "AWL_DEV_GATEWAY_HEALTH_ONLY": "1",
            "AWL_DEV_KEYCHAIN_NONCE": "0123456789abcdefabcd",
        }
        self.assertEqual(
            validate_config(approved)["session_key_kind"],
            "explicit-isolated",
        )
        for change in [
            {"AWL_DEV_GATEWAY_HEALTH_ONLY": "true"},
            {"AWL_DEV_GATEWAY_PROVE_ABORT": "1"},
            {"AWL_DEV_KEYCHAIN_NONCE": "too-short"},
            {"AWL_DEV_KEYCHAIN_NONCE": "A" * 20},
        ]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_config({**approved, **change})

    def test_rejects_default_session_and_missing_revision(self):
        for change in [
            {"AWL_OPENCLAW_SESSION_KEY": "agent:main:main"},
            {"AWL_OPENCLAW_SESSION_KEY": "agent:main:personal"},
            {"AWL_OPENCLAW_SESSION_KEY": "agent:main:awl-dev-"},
            {"AWL_OPENCLAW_SESSION_KEY": "agent:main:awl-dev-test:extra"},
            {"AWL_OPENCLAW_SESSION_KEY": "agent:main:AWL-DEV-test"},
            {"AWL_DEV_GATEWAY_REVISION": ""},
            {"AWL_OPENCLAW_TOKEN": ""},
            {"AWL_OPENCLAW_BOOTSTRAP_TOKEN": "unwanted"},
            {"AWL_OPENCLAW_CHAT_MESSAGE": "unwanted"},
        ]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_config({**self.valid, **change})


if __name__ == "__main__":
    unittest.main()
