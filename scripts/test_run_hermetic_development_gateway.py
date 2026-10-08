import contextlib
import io
import signal
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import call, patch

from dev_gateway_preflight import validate_config
from run_hermetic_development_gateway import (
    checkout_revision,
    isolated_environment,
    main,
    retire_owned_process,
)


class HermeticRealGatewayRunnerTests(unittest.TestCase):
    def test_allowlisted_environment_never_inherits_personal_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            env = isolated_environment(
                {
                    "PATH": "/usr/bin:/bin",
                    "HOME": "/Users/private",
                    "AWS_SECRET_ACCESS_KEY": "private",
                    "OPENAI_API_KEY": "private",
                    "OPENCLAW_GATEWAY_TOKEN": "production-token",
                    "AWL_OPENCLAW_URL": "wss://production.ts.net",
                    "LANG": "en_US.UTF-8",
                    "MY_CUSTOM_SECRET": "private",
                },
                home=Path(directory), port=19021, revision="a" * 40,
                token="synthetic-only", full_chat=False, prove_abort=False,
            )
            self.assertEqual(validate_config(env)["session_key_kind"], "explicit-isolated")
            self.assertEqual(env["AWL_OPENCLAW_URL"], "ws://127.0.0.1:19021")
            self.assertEqual(env["AWL_OPENCLAW_TOKEN"], "synthetic-only")
            self.assertEqual(env["AWL_DEV_GATEWAY_HEALTH_ONLY"], "1")
            self.assertEqual(env["OPENCLAW_GATEWAY_TOKEN"], "synthetic-only")
            self.assertEqual(len(env["AWL_DEV_KEYCHAIN_NONCE"]), 20)
            self.assertNotEqual(env["HOME"], "/Users/private")
            for key in ("AWS_SECRET_ACCESS_KEY", "OPENAI_API_KEY",
                        "MY_CUSTOM_SECRET"):
                self.assertNotIn(key, env)

    def test_full_chat_and_abort_are_separate_explicit_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            kwargs = dict(home=Path(directory), port=19021, revision="a"*40,
                          token="synthetic-only", full_chat=True,
                          prove_abort=True)
            env = isolated_environment({}, **kwargs)
            self.assertEqual(env["AWL_DEV_GATEWAY_PROVE_ABORT"], "1")
            self.assertEqual(env["AWL_DEV_GATEWAY_HEALTH_ONLY"], "0")
            validate_config(env)
            with self.assertRaises(ValueError):
                isolated_environment({}, **{**kwargs, "full_chat": False})

    def test_real_source_revision_and_clean_checkout_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory)
            (checkout / "dist").mkdir()
            (checkout / "dist" / "entry.js").write_text("fixture")
            with patch(
                "run_hermetic_development_gateway.subprocess.run",
                side_effect=[
                    SimpleNamespace(stdout="a"*40+"\n"),
                    SimpleNamespace(stdout=""),
                ],
            ):
                self.assertTrue(checkout_revision(checkout, "a"*40))
            with patch(
                "run_hermetic_development_gateway.subprocess.run",
                side_effect=[
                    SimpleNamespace(stdout="a"*40+"\n"),
                    SimpleNamespace(stdout=" M src/modified.ts\n"),
                ],
            ):
                self.assertFalse(checkout_revision(checkout, "a"*40))
            with patch(
                "run_hermetic_development_gateway.subprocess.run",
                side_effect=[
                    SimpleNamespace(stdout="b"*40+"\n"),
                    SimpleNamespace(stdout=""),
                ],
            ):
                self.assertFalse(checkout_revision(checkout, "a"*40))
            self.assertFalse(checkout_revision(checkout, "invalid"))

    def test_retire_owned_process_after_parent_exit_still_signals_group(self):
        class Exited:
            pid = 9001
            def poll(self):
                return 0
        with patch("run_hermetic_development_gateway.os.killpg") as signal_group:
            retire_owned_process(Exited())
            self.assertEqual(signal_group.call_args_list, [
                call(9001, signal.SIGTERM),
                call(9001, signal.SIGKILL),
            ])

    def test_rejects_missing_pinned_checkout_before_process_launch(self):
        with (
            patch("run_hermetic_development_gateway.subprocess.Popen") as spawn,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            code = main([
                "--checkout", "/nonexistent/awl-hermetic-gateway",
                "--revision", "a" * 40,
            ])
            self.assertEqual(code, 2)
            spawn.assert_not_called()


if __name__ == "__main__":
    unittest.main()
