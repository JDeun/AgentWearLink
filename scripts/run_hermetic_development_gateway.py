#!/usr/bin/env python3
"""Run a real, pinned OpenClaw dev Gateway in disposable loopback state.

This is an opt-in layer-2 integration runner; it never starts the owner's
installed Gateway service, attaches to their Tailnet, or reuses live sessions.
No provider credentials, Gateway responses, tokens or process output are logged.
"""
from __future__ import annotations

import argparse
import contextlib
import errno
import json
import os
import re
import select
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

from dev_gateway_preflight import validate_config

ROOT = Path(__file__).resolve().parent.parent
GATEWAY_START_DEADLINE = 45
PROBE_DEADLINE = 900
_REVISION = re.compile(r"^[0-9a-fA-F]{40}$")
_SAFE_PROBE_PHASES = frozenset({
    "handshake-started", "socket-opened",
    "challenge-received", "assemble-started", "assemble-complete",
    "connect-sending", "connect-sent",
    "response-received", "gateway-not-paired-unstructured",
    "gateway-verified-user-required", "gateway-device-proof-rejected",
    "gateway-shared-auth-rejected", "gateway-invalid-request",
    "gateway-unavailable", "gateway-startup-pending",
    "gateway-profile-unavailable",
    "gateway-auth-denied", "gateway-unrecognized", "authenticated",
    "health-accepted", "pairing-required", "probe-error",
    "chat-started", "chat-authenticated", "chat-delta", "chat-terminal",
    "chat-provider-ingress", "chat-abort-confirmed",
    "chat-two-turns-completed",
})
_SAFE_PROBE_RESULTS = frozenset({
    "challenge-timeout", "hello-timeout", "unexpected-connect-response",
    "challenge-required", "invalid-challenge", "missing-hello",
    "invalid-policy", "connect-invalidated", "handshake-other",
    "gateway-auth-denied", "gateway-invalid-request",
    "gateway-pairing-code", "gateway-device-token-rejected",
    "gateway-other", "transport-disconnected", "protocol-mismatch",
    "gateway-state-error", "frame-invalid", "decoding-failed", "other-error",
    "chat-no-delta", "chat-no-terminal", "chat-session-mismatch", "chat-other-error",
    "chat-provider-not-executing",
    "chat-duplicate-interaction", "chat-interaction-mismatch",
})


def safe_probe_result(path: Path) -> str:
    """Never relay the raw Gateway, Keychain or Swift error payload."""
    try:
        category = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        return "unobserved"
    return category if category in _SAFE_PROBE_RESULTS else "unobserved"


def safe_probe_phase(path: Path) -> str:
    """Emit only protocol-phase vocabulary, never file-supplied text."""
    try:
        phase = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        return "unobserved"
    return phase if phase in _SAFE_PROBE_PHASES else "unobserved"



def may_retry_negative_gateway_startup(
    *, phase: str, exit_code: int, attempt: int, max_attempts: int
) -> bool:
    """Only pinned upstream's structured startup-pending response is retryable.

    A refusal is never counted as passed without an actual pairing-required
    error. Invalid requests, credential denials, missing diagnostics, and
    arbitrary UNAVAILABLE conditions fail closed.
    """
    return (
        phase == "gateway-startup-pending"
        and exit_code == 1
        and max_attempts > 0
        and 0 <= attempt < max_attempts - 1
    )


def positive_health_gateway_config() -> dict[str, object]:
    """Enable local approval only on a disposable synthetic positive Gateway."""
    return {
        "gateway": {
            "nodes": {
                "pairing": {
                    "autoApproveLocal": True,
                    "autoApproveCidrs": [],
                }
            }
        }
    }


def synthetic_agent_gateway_config(model_port: int, workspace: Path) -> dict[str, object]:
    """Pinned real Gateway + its OWN local mock Responses model; no credentials.

    A concrete agent turn goes through real Gateway RPC/run/event handling,
    but the deterministic model is NOT a live LLM or a private provider.
    """
    if not (1 <= model_port <= 65535):
        raise ValueError("invalid synthetic model port")
    return {
        **positive_health_gateway_config(),
        "models": {
            "mode": "replace",
            "catalogRefresh": {"enabled": False},
            "providers": {
                "openai": {
                    "baseUrl": f"http://127.0.0.1:{model_port}/v1",
                    "apiKey": "sk-awl-synthetic-test-not-secret",
                    "api": "openai-responses",
                    "agentRuntime": {"id": "openclaw"},
                    "request": {"allowPrivateNetwork": True},
                    "models": [{
                        "id": "gpt-5.6-luna",
                        "name": "AWL Synthetic Fixture",
                        "api": "openai-responses",
                        "agentRuntime": {"id": "openclaw"},
                        "reasoning": False,
                        "input": ["text"],
                        "cost": {
                            "input": 0, "output": 0,
                            "cacheRead": 0, "cacheWrite": 0,
                        },
                        "contextWindow": 32000,
                        "maxTokens": 2048,
                    }],
                }
            },
        },
        "agents": {"defaults": {
            "workspace": str(workspace),
            "model": {"primary": "openai/gpt-5.6-luna"},
            "models": {"openai/gpt-5.6-luna": {
                "params": {"transport": "sse", "openaiWsWarmup": False},
            }},
        }},
        "tools": {"profile": "minimal", "deny": ["*"]},
    }


def synthetic_model_request_count(port: int) -> int | None:
    """Return only one nonnegative numeric aggregate; never provider payloads."""
    if not (1 <= port <= 65535):
        return None
    try:
        request = urllib.request.Request(f"http://127.0.0.1:{port}/health")
        # Never use inherited corporate/user HTTP proxy settings, nor a
        # user-provided hostname or any URL returned by the mock service.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=3) as response:
            if response.status != 200:
                return None
            data = json.loads(response.read(8192))
        count = (data.get("requests", {}).get("ingress", {}).get("responses")
                 if isinstance(data, dict) and isinstance(data.get("requests"), dict)
                 else None)
        return (count if isinstance(count, int) and not isinstance(count, bool)
                and 0 <= count <= 10000 else None)
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
        return None


def synthetic_model_received_request(port: int, *, exact_requests: int | None = None) -> bool:
    count = synthetic_model_request_count(port)
    return (count is not None and count >= 1
            and (exact_requests is None or count == exact_requests))


def negative_pairing_gateway_config() -> dict[str, object]:
    """Disable the *upstream default* silent local device approval.

    OpenClaw's autoApproveLocal is true by default. Without an explicit
    override a loopback unapproved-device rejection is not a valid test.
    This configuration is generated only inside the owned disposable state.
    """
    return {
        "gateway": {
            "nodes": {
                "pairing": {
                    "autoApproveLocal": False,
                    "autoApproveCidrs": [],
                }
            }
        }
    }


def checkout_revision(checkout: Path, expected: str) -> bool:
    """Validate the operator-pinned *source* checkout without editing it."""
    if not _REVISION.fullmatch(expected) or not checkout.is_dir():
        return False
    if not (checkout / "dist" / "entry.js").is_file():
        return False
    try:
        head = subprocess.run(
            ["git", "-C", str(checkout), "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=10, check=True,
        ).stdout.strip()
        dirty = subprocess.run(
            ["git", "-C", str(checkout), "status", "--porcelain",
             "--untracked-files=no"],
            capture_output=True, text=True, timeout=10, check=True,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False
    return head.lower() == expected.lower() and not dirty


def isolated_environment(
    original: dict[str, str],
    *,
    home: Path,
    port: int,
    revision: str,
    token: str,
    full_chat: bool,
    prove_abort: bool,
) -> dict[str, str]:
    if not (1 <= port <= 65535):
        raise ValueError("invalid local port")
    if prove_abort and not full_chat:
        raise ValueError("abort proof requires full chat opt-in")

    # Strip inherited model/provider secrets. A full-chat development model
    # should use a separate, deliberately isolated configuration/provider.
    # Deliberately carry only the minimum host toolchain environment.
    # A suffix-denylist could miss AWS_SECRET_ACCESS_KEY, credential files,
    # third-party provider tokens, shell auto-import or arbitrary app secrets.
    allowed = frozenset({
        "PATH", "LANG", "LC_ALL", "TMPDIR", "DEVELOPER_DIR", "SDKROOT",
        "SYSTEMROOT", "COMSPEC",
    })
    env = {k: v for k, v in original.items() if k in allowed}
    env["HOME"] = str(home / "home")
    (home / "home").mkdir(mode=0o700, exist_ok=True)
    env.update({
        "OPENCLAW_STATE_DIR": str(home / "state"),
        "OPENCLAW_CONFIG_PATH": str(home / "state" / "openclaw.json"),
        "OPENCLAW_WORKSPACE_DIR": str(home / "workspace"),
        "OPENCLAW_GATEWAY_PORT": str(port),
        "OPENCLAW_GATEWAY_TOKEN": token,
        "OPENCLAW_SKIP_CHANNELS": "1",
        "OPENCLAW_LOAD_SHELL_ENV": "0",
        "AWL_DEV_KEYCHAIN_NONCE": secrets.token_hex(10),
        "AWL_ALLOW_DEV_GATEWAY_TEST": "1",
        "AWL_OPENCLAW_URL": f"ws://127.0.0.1:{port}",
        "AWL_OPENCLAW_EXPOSURE": "loopback",
        "AWL_OPENCLAW_TOKEN": token,
        "AWL_OPENCLAW_SESSION_KEY": "agent:main:awl-dev-hermetic",
        "AWL_DEV_GATEWAY_REVISION": revision,
        "AWL_DEV_GATEWAY_HEALTH_ONLY": "0" if full_chat else "1",
        "AWL_DEV_GATEWAY_PROVE_ABORT": "1" if prove_abort else "0",
    })
    return env


def local_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def gateway_reachable(process: subprocess.Popen[bytes], port: int,
                      *, deadline_seconds: int = GATEWAY_START_DEADLINE) -> bool:
    deadline = time.monotonic() + deadline_seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            return False
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return True
        except OSError:
            time.sleep(0.25)
    return False


def cleanup_disposable_gateway_directory(
    directory: tempfile.TemporaryDirectory[str],
    *,
    attempts: int = 16,
    interval_seconds: float = 0.5,
) -> None:
    """Bound an APFS ENOTEMPTY race while an owned Gateway is shutting down.

    The process group is retired before this cleanup begins. The pinned
    upstream may still briefly finish creating plugin-clone staging files.
    Only re-attempt cleanup of the exact tempfile-owned directory; permission
    errors and persistent ENOTEMPTY remain fatal. Never hide cleanup leaks.
    """
    if attempts < 1 or interval_seconds < 0:
        raise ValueError("Invalid disposable cleanup retry budget")
    for index in range(attempts):
        try:
            directory.cleanup()
            return
        except OSError as error:
            if (error.errno not in (errno.ENOTEMPTY, errno.EEXIST)
                    or index + 1 >= attempts):
                raise
            time.sleep(interval_seconds)


@contextlib.contextmanager
def disposable_gateway_state():
    """Own disposal of the state even on an early return or exception."""
    directory = tempfile.TemporaryDirectory(prefix="awl-real-dev-gateway-")
    try:
        yield Path(directory.name)
    finally:
        cleanup_disposable_gateway_directory(directory)


def retire_owned_process(process: subprocess.Popen[bytes]) -> None:
    """Never touch another Gateway: only our unique start_new_session group."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    if process.poll() is None:
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    if process.poll() is None:
        process.wait()


_REQUEST_ID = re.compile(r"^[A-Za-z0-9_:-]{8,128}$")


def approve_one_isolated_pairing(
    node: str,
    checkout: Path,
    env: dict[str, str],
    *,
    input_stream=None,
    timeout_seconds: int = 120,
) -> bool:
    """Human-entered exact request ID; never bulk/auto approve devices.

    This can only run inside the disposable loopback Gateway created here.
    No personal Mac mini/Tailnet credentials or session data are consulted.
    """
    entry = input_stream if input_stream is not None else sys.stdin
    state = Path(env.get("OPENCLAW_STATE_DIR", ""))
    gateway_url = env.get("AWL_OPENCLAW_URL", "")
    token = env.get("AWL_OPENCLAW_TOKEN", "")
    expected_home = state.parent / "home"
    if (env.get("AWL_OPENCLAW_EXPOSURE") != "loopback"
            or not re.fullmatch(r"ws://127\.0\.0\.1:[0-9]{1,5}", gateway_url)
            or not state.name == "state"
            or env.get("HOME") != str(expected_home)
            or not state.parent.name.startswith("awl-real-dev-gateway-")
            or not token
            or env.get("OPENCLAW_GATEWAY_TOKEN") != token
            or not entry.isatty()):
        return False
    try:
        listed = subprocess.run(
            [node, str(checkout / "dist" / "entry.js"),
             "devices", "list", "--json", "--url", gateway_url],
            cwd=checkout, env=env,
            stdin=subprocess.DEVNULL, capture_output=True,
            timeout=20, check=False,
        )
        if listed.returncode != 0 or len(listed.stdout) > 128_000:
            return False
        document = json.loads(listed.stdout.decode("utf-8"))
        pending = document.get("pending")
        if not isinstance(pending, list) or len(pending) > 16:
            return False
        allowed: list[str] = []
        for item in pending:
            if not isinstance(item, dict):
                continue
            request_id = item.get("requestId") or item.get("id")
            if isinstance(request_id, str) and _REQUEST_ID.fullmatch(request_id):
                allowed.append(request_id)
        if not allowed:
            return False
        print("Only the disposable local Gateway's pending request IDs:")
        for request_id in allowed:
            print("  " + request_id)
        print("Inspect each request locally before approval. Enter the exact "
              "request ID; any other input cancels. No token is displayed.")
        ready, _, _ = select.select([entry], [], [], timeout_seconds)
        if not ready:
            return False
        selected = entry.readline().strip()
        if selected not in allowed:
            return False
        approved = subprocess.run(
            [node, str(checkout / "dist" / "entry.js"),
             "devices", "approve", selected, "--url", gateway_url],
            cwd=checkout, env=env,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=20, check=False,
        )
        return approved.returncode == 0
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", required=True,
                        help="Local built OpenClaw Git checkout (not a service)")
    parser.add_argument("--revision", required=True,
                        help="Exact Git HEAD, 40 hex characters")
    parser.add_argument("--full-chat", action="store_true",
                        help="Opt in to a harmless real Gateway agent run")
    parser.add_argument("--prove-abort", action="store_true",
                        help="Opt in to accepted-run cancellation proof")
    parser.add_argument("--config-template",
                        help="Optional isolated dev Gateway config JSON file")
    parser.add_argument("--approve-isolated-pairing", action="store_true",
                        help="Allow a human to approve exact pending IDs on this "
                             "disposable Gateway only; TTY required")
    parser.add_argument("--expect-pairing-required", action="store_true",
                        help="Require unapproved real Gateway pairing rejection")
    parser.add_argument("--expect-health-ok", action="store_true",
                        help="Require real localhost hello-ok and health with ephemeral identity")
    parser.add_argument("--expect-grant-reconnect", action="store_true",
                        help="Verify two separate Swift processes and an issued "
                             "read-only grant without shared token in the second")
    parser.add_argument("--expect-native-keychain-grant-reconnect", action="store_true",
                        help="CI-only real Gateway grant reuse through native macOS Keychain")
    parser.add_argument("--expect-agent-stream", action="store_true",
                        help="Run production native agent against pinned real "
                             "Gateway with a synthetic local Responses model")
    parser.add_argument("--expect-agent-abort", action="store_true",
                        help="Require confirmed real chat.abort after synthetic provider ingress")
    parser.add_argument("--expect-agent-session", action="store_true",
                        help="Prove exactly two native agent requests reuse one real "
                             "Gateway session without duplicate model execution")
    args = parser.parse_args(argv)
    contract_count = sum((args.expect_pairing_required, args.expect_health_ok,
                          args.expect_grant_reconnect,
                          args.expect_native_keychain_grant_reconnect,
                          args.expect_agent_stream,
                          args.expect_agent_abort, args.expect_agent_session))
    contract = contract_count == 1
    if (contract_count > 1 or contract and
            (args.approve_isolated_pairing or args.full_chat
             or args.prove_abort or args.config_template)):
        print("Isolated Gateway runner: synthetic contract modes must be "
              "exclusive, read-only and without external config.",
              file=sys.stderr)
        return 2

    if args.expect_native_keychain_grant_reconnect and (
            os.environ.get("CI") != "true"
            or os.environ.get("AWL_RUN_NATIVE_KEYCHAIN_INTEGRATION") != "1"):
        print("Native Keychain contract requires explicit disposable macOS CI opt-in.",
              file=sys.stderr)
        return 2

    checkout = Path(args.checkout).expanduser().resolve()
    if not checkout_revision(checkout, args.revision):
        print("Isolated Gateway runner: revision, source cleanliness or built CLI mismatch.",
              file=sys.stderr)
        return 2
    if args.prove_abort and not args.full_chat:
        print("Isolated Gateway runner: abort requires full chat.", file=sys.stderr)
        return 2
    if args.full_chat and os.environ.get("AWL_DEV_ISOLATED_MODEL_ACK") != "1":
        print("Isolated Gateway runner: acknowledge a harmless isolated model first.",
              file=sys.stderr)
        return 2
    node = shutil.which("node")
    if node is None:
        print("Isolated Gateway runner: Node.js is unavailable.", file=sys.stderr)
        return 2

    with disposable_gateway_state() as temp:
        (temp / "state").mkdir(mode=0o700)
        (temp / "workspace").mkdir(mode=0o700)

        if args.config_template:
            template = Path(args.config_template).expanduser().resolve()
            if not template.is_file() or not args.full_chat:
                print("Isolated Gateway runner: config template requires full chat.",
                      file=sys.stderr)
                return 2
            # Explicitly selected configuration is copied, never modified.
            shutil.copyfile(template, temp / "state" / "openclaw.json")
            (temp / "state" / "openclaw.json").chmod(0o600)

        port = local_port()
        synthetic_agent = (args.expect_agent_stream or args.expect_agent_abort
                           or args.expect_agent_session)
        model_port = local_port() if synthetic_agent else None
        if model_port == port:
            model_port = local_port()

        if contract:
            # These configs exist solely inside the disposable loopback state.
            configuration = temp / "state" / "openclaw.json"
            config_data = (
                negative_pairing_gateway_config() if args.expect_pairing_required
                else synthetic_agent_gateway_config(model_port, temp / "workspace")
                if synthetic_agent and model_port is not None
                else positive_health_gateway_config()
            )
            with configuration.open("x", encoding="utf-8") as stream:
                json.dump(config_data, stream)
            configuration.chmod(0o600)

        env = isolated_environment(
            dict(os.environ), home=temp, port=port,
            revision=args.revision, token=secrets.token_urlsafe(32),
            full_chat=args.full_chat or synthetic_agent,
            prove_abort=args.prove_abort,
        )
        if contract:
            # Exactly one private, prebuilt real-Gateway CI contract.
            marker = ("AWL_DEV_GATEWAY_EXPECT_PAIRING" if args.expect_pairing_required
                      else "AWL_DEV_GATEWAY_EXPECT_GRANT_RECONNECT"
                      if (args.expect_grant_reconnect or
                          args.expect_native_keychain_grant_reconnect)
                      else "AWL_DEV_GATEWAY_EXPECT_AGENT_STREAM"
                      if args.expect_agent_stream
                      else "AWL_DEV_GATEWAY_EXPECT_AGENT_ABORT"
                      if args.expect_agent_abort
                      else "AWL_DEV_GATEWAY_EXPECT_AGENT_SESSION"
                      if args.expect_agent_session
                      else "AWL_DEV_GATEWAY_EXPECT_HEALTH_OK")
            env[marker] = "1"
            if args.expect_agent_abort and model_port is not None:
                env["AWL_DEV_GATEWAY_MODEL_PORT"] = str(model_port)
                env["AWL_DEV_GATEWAY_PROVE_ABORT"] = "1"
            if args.expect_agent_session:
                env["AWL_DEV_GATEWAY_SESSION_ASSERT"] = "1"
                if model_port is None:
                    raise ValueError("Synthetic session requires local model port")
                env["AWL_DEV_GATEWAY_MODEL_PORT"] = str(model_port)
            if args.expect_native_keychain_grant_reconnect:
                env["CI"] = "true"
                env["AWL_RUN_NATIVE_KEYCHAIN_INTEGRATION"] = "1"
                env["AWL_DEV_GATEWAY_NATIVE_KEYCHAIN"] = "1"
            if args.expect_grant_reconnect:
                grant_directory = temp / "grant-cache"
                grant_directory.mkdir(mode=0o700)
                env["AWL_DEV_GATEWAY_GRANT_STORE"] = str(grant_directory)
            env["AWL_DEV_GATEWAY_USE_BUILT_PROBE"] = "1"
            env["AWL_DEV_GATEWAY_PHASE_FILE"] = str(temp / "probe-phase")
            env["AWL_DEV_GATEWAY_RESULT_FILE"] = str(temp / "probe-result")
        try:
            validate_config(env)
        except ValueError:
            print("Isolated Gateway runner: safety preflight failed.", file=sys.stderr)
            return 2

        # The pinned upstream's own E2E mock Responses provider remains a
        # separate ephemeral 127.0.0.1 process. It never reads cloud keys,
        # personal sessions or private model endpoints.
        model_process = None
        if synthetic_agent:
            assert model_port is not None
            mock_env = dict(env)
            mock_env.update({
                "MOCK_PORT": str(model_port),
                "MOCK_BIND_HOST": "127.0.0.1",
                "SUCCESS_MARKER": "AWL_ISOLATED_SYNTHETIC_AGENT_OK",
            })
            if args.expect_agent_abort:
                control = temp / "held-model.json"
                with control.open("x", encoding="utf-8") as held:
                    json.dump({
                        "hold": True,
                        "response": {"text": "AWL_ISOLATED_SYNTHETIC_AGENT_OK"},
                    }, held)
                control.chmod(0o600)
                mock_env["MOCK_RESPONSE_CONTROL"] = str(control)
            try:
                model_process = subprocess.Popen(
                    [node, str(checkout / "scripts/e2e/mock-openai-server.mjs")],
                    cwd=checkout, env=mock_env, stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            except OSError:
                print("Isolated Gateway runner: synthetic model failed to start.",
                      file=sys.stderr)
                return 1
            if not gateway_reachable(model_process, model_port,
                                     deadline_seconds=20):
                retire_owned_process(model_process)
                print("Isolated Gateway runner: synthetic model not ready.",
                      file=sys.stderr)
                return 1

        # Use the actual checked-out CLI rather than an unrelated globally
        # installed OpenClaw version. No force/restart/service commands.
        command = [
            node, str(checkout / "dist" / "entry.js"), "gateway",
            "--dev", "--allow-unconfigured", "--bind", "loopback",
            "--port", str(port), "--auth", "token", "--tailscale", "off",
        ]
        try:
            gateway = subprocess.Popen(
                command, cwd=checkout, env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True,
            )
        except OSError:
            if model_process is not None:
                retire_owned_process(model_process)
            print("Isolated Gateway runner: pinned Gateway did not start.",
                  file=sys.stderr)
            return 1

        try:
            if not gateway_reachable(gateway, port):
                print("Isolated Gateway runner: loopback Gateway not ready.",
                      file=sys.stderr)
                return 1
            # TCP readiness is NOT counted as authenticated Gateway proof.
            # Existing production Swift probes verify connect/auth/health.
            deadline = time.monotonic() + PROBE_DEADLINE
            # Only the exact request ID explicitly entered by a human can
            # enable local pairing. Read-only and write-probe identities
            # require independent approvals, never implicit privilege reuse.
            attempt_limit = 6 if contract else 3
            for approval_attempt in range(attempt_limit):
                if contract:
                    # A failed attempt cannot lend stale evidence to the next.
                    (temp / "probe-phase").unlink(missing_ok=True)
                    (temp / "probe-result").unlink(missing_ok=True)
                try:
                    remaining = max(1, int(deadline - time.monotonic()))
                    result = subprocess.run(
                        ["bash", str(ROOT / "scripts" /
                                     "run-openclaw-development-gateway.sh")],
                        cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        timeout=remaining, check=False,
                    )
                except (OSError, subprocess.TimeoutExpired):
                    print("Isolated Gateway runner: bounded probes failed.",
                          file=sys.stderr)
                    return 1
                if contract:
                    if args.expect_pairing_required and result.returncode == 3:
                        print("Isolated real Gateway rejected unapproved read-only identity as expected.")
                        return 0
                    if args.expect_health_ok and result.returncode == 0:
                        print("Isolated real Gateway authenticated read-only health accepted.")
                        return 0
                    if args.expect_agent_session and result.returncode == 0:
                        if (model_port is not None
                                and synthetic_model_request_count(model_port) is not None
                                and synthetic_model_request_count(model_port) >= 2
                                and safe_probe_phase(temp / "probe-phase") ==
                                    "chat-two-turns-completed"):
                            print("Isolated real Gateway completed two distinct "
                                  "native agent turns in the same session; "
                                  "each turn advanced synthetic model ingress.")
                            return 0
                        count = (synthetic_model_request_count(model_port)
                                 if model_port is not None else None)
                        safe_count = str(count) if count is not None else "unobserved"
                        phase = safe_probe_phase(temp / "probe-phase")
                        failure = safe_probe_result(temp / "probe-result")
                        print("Isolated real Gateway same-session contract failed: "
                              "aggregate-model-ingress=" + safe_count
                              + " last-phase=" + phase
                              + " failure-class=" + failure,
                              file=sys.stderr)
                        return 1
                    if args.expect_agent_abort and result.returncode == 0:
                        if (model_port is not None
                                and synthetic_model_received_request(model_port)
                                and safe_probe_phase(temp / "probe-phase") ==
                                    "chat-abort-confirmed"):
                            print("Isolated real Gateway confirmed chat.abort "
                                  "for active run after synthetic model ingress.")
                            return 0
                        print("Isolated real Gateway abort lacks active-run "
                              "provider ingress or abort confirmation.",
                              file=sys.stderr)
                        return 1
                    if args.expect_agent_stream and result.returncode == 0:
                        if model_port is not None and synthetic_model_received_request(model_port):
                            print("Isolated real Gateway native agent emitted "
                                  "incremental text and terminal completion "
                                  "using a synthetic local model.")
                            return 0
                        print("Isolated real Gateway agent stream: synthetic "
                              "model request was not observed.", file=sys.stderr)
                        return 1
                    if (args.expect_grant_reconnect or
                            args.expect_native_keychain_grant_reconnect) and result.returncode == 0:
                        # The second Swift process must not receive *either*
                        # the AWL shared Gateway bearer or the upstream token.
                        # It only loads the device grant the real Gateway
                        # issued to the first process in disposable storage.
                        second = dict(env)
                        second.pop("AWL_OPENCLAW_TOKEN", None)
                        second.pop("OPENCLAW_GATEWAY_TOKEN", None)
                        second["AWL_DEV_GATEWAY_RECONNECT_STORED_ONLY"] = "1"
                        (temp / "probe-phase").unlink(missing_ok=True)
                        (temp / "probe-result").unlink(missing_ok=True)
                        try:
                            reconnect = subprocess.run(
                                [sys.executable, str(ROOT / "scripts" /
                                                     "dev_gateway_probe_runner.py"),
                                 "awl-openclaw-probe"],
                                cwd=ROOT, env=second, stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=max(1, int(deadline - time.monotonic())),
                                check=False,
                            )
                        except (OSError, subprocess.TimeoutExpired):
                            print("Isolated real Gateway device-grant reconnect timed out.",
                                  file=sys.stderr)
                            return 1
                        if reconnect.returncode == 0:
                            if args.expect_native_keychain_grant_reconnect:
                                print("Isolated real Gateway-issued read-only grant "
                                      "persisted in native macOS Keychain; a second "
                                      "Swift process connected without shared token.")
                            else:
                                print("Isolated real Gateway issued read-only grant "
                                      "and second Swift process connected without shared token.")
                            return 0
                        print("Isolated real Gateway second-process grant-only "
                              "reconnect failed (last-phase="
                              + safe_probe_phase(temp / "probe-phase")
                              + ", failure-class="
                              + safe_probe_result(temp / "probe-result") + ")",
                              file=sys.stderr)
                        return 1
                    categories = {
                        0: "unexpected-auth-success",
                        1: "handshake-or-protocol-failure",
                        124: "probe-timeout",
                        127: "probe-binary-unavailable",
                    }
                    category = categories.get(result.returncode, "unexpected-exit")
                    phase = safe_probe_phase(temp / "probe-phase")
                    failure = safe_probe_result(temp / "probe-result")
                    if (gateway.poll() is None
                            and may_retry_negative_gateway_startup(
                                phase=phase, exit_code=result.returncode,
                                attempt=approval_attempt,
                                max_attempts=attempt_limit,
                            )
                            and time.monotonic() + 1 < deadline):
                        print("Isolated Gateway startup sidecars not ready; "
                              "retrying bounded read-only contract probe.",
                              file=sys.stderr)
                        time.sleep(1)
                        continue
                    mode = ("negative-contract" if args.expect_pairing_required
                            else "native-keychain-grant-contract" if args.expect_native_keychain_grant_reconnect
                            else "disposable-grant-contract" if args.expect_grant_reconnect
                            else "agent-stream-contract" if args.expect_agent_stream
                            else "active-agent-abort-contract" if args.expect_agent_abort
                            else "agent-session-contract" if args.expect_agent_session
                            else "positive-health-contract")
                    print("Isolated real Gateway " + mode + " failed: "
                          + category + " (last-phase=" + phase
                          + ", failure-class=" + failure + ")",
                          file=sys.stderr)
                    return 1
                if result.returncode == 0:
                    print("Isolated Gateway runner: real loopback Gateway probes passed; "
                          "no physical/Tailnet claim.")
                    return 0
                if (result.returncode != 3
                        or not args.approve_isolated_pairing
                        or approval_attempt >= 2
                        or time.monotonic() >= deadline):
                    print("Isolated Gateway runner: real probe did not pass.",
                          file=sys.stderr)
                    return 1
                if not approve_one_isolated_pairing(
                    node, checkout, env,
                    timeout_seconds=min(120, max(1, int(deadline - time.monotonic()))),
                ):
                    print("Isolated Gateway runner: pairing not approved.",
                          file=sys.stderr)
                    return 1
            return 1
        finally:
            retire_owned_process(gateway)
            if model_process is not None:
                retire_owned_process(model_process)
            if args.expect_native_keychain_grant_reconnect:
                # Always clean ONLY the randomized CI service, including after
                # connection or grant-reuse failure. No private item is touched.
                cleanup_env = dict(env)
                cleanup_env.pop("AWL_OPENCLAW_TOKEN", None)
                cleanup_env.pop("OPENCLAW_GATEWAY_TOKEN", None)
                cleanup_env.pop("AWL_DEV_GATEWAY_RECONNECT_STORED_ONLY", None)
                cleanup_env["AWL_DEV_GATEWAY_NATIVE_KEYCHAIN_CLEANUP"] = "1"
                try:
                    cleanup = subprocess.run(
                        [sys.executable, str(ROOT / "scripts" /
                                             "dev_gateway_probe_runner.py"),
                         "awl-openclaw-probe"],
                        cwd=ROOT, env=cleanup_env, stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        timeout=30, check=False,
                    )
                except (OSError, subprocess.TimeoutExpired) as exc:
                    raise RuntimeError(
                        "Disposable native Keychain cleanup did not finish"
                    ) from exc
                if cleanup.returncode != 0:
                    raise RuntimeError(
                        "Disposable native Keychain cleanup was unsuccessful"
                    )


if __name__ == "__main__":
    raise SystemExit(main())
