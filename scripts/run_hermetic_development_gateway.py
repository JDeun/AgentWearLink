#!/usr/bin/env python3
"""Run a real, pinned OpenClaw dev Gateway in disposable loopback state.

This is an opt-in layer-2 integration runner; it never starts the owner's
installed Gateway service, attaches to their Tailnet, or reuses live sessions.
No provider credentials, Gateway responses, tokens or process output are logged.
"""
from __future__ import annotations

import argparse
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
})
_SAFE_PROBE_RESULTS = frozenset({
    "challenge-timeout", "hello-timeout", "unexpected-connect-response",
    "challenge-required", "invalid-challenge", "missing-hello",
    "invalid-policy", "connect-invalidated", "handshake-other",
    "gateway-auth-denied", "gateway-invalid-request",
    "gateway-pairing-code", "gateway-device-token-rejected",
    "gateway-other", "transport-disconnected", "protocol-mismatch",
    "gateway-state-error", "frame-invalid", "decoding-failed", "other-error",
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
                        help="Validate that the real ephemeral Gateway rejects an "
                             "unapproved client, without granting permission")
    args = parser.parse_args(argv)
    if args.expect_pairing_required and (args.approve_isolated_pairing or args.full_chat or args.prove_abort):
        print("Isolated Gateway runner: negative pairing test must be read-only.",
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

    with tempfile.TemporaryDirectory(prefix="awl-real-dev-gateway-") as directory:
        temp = Path(directory)
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

        if args.expect_pairing_required:
            # The pinned upstream defaults to silent localhost approval.
            # Force explicit device-pairing rejection in disposable state only.
            # This is not a production Mac mini / operator Gateway setting.
            configuration = temp / "state" / "openclaw.json"
            with configuration.open("x", encoding="utf-8") as stream:
                json.dump(negative_pairing_gateway_config(), stream)
            configuration.chmod(0o600)

        port = local_port()
        env = isolated_environment(
            dict(os.environ), home=temp, port=port,
            revision=args.revision, token=secrets.token_urlsafe(32),
            full_chat=args.full_chat, prove_abort=args.prove_abort,
        )
        if args.expect_pairing_required:
            # Narrow negative test to a single independently built Swift
            # executable and one unapproved device challenge. The status
            # classifier never emits Gateway responses or private identifiers.
            env["AWL_DEV_GATEWAY_EXPECT_PAIRING"] = "1"
            env["AWL_DEV_GATEWAY_USE_BUILT_PROBE"] = "1"
            env["AWL_DEV_GATEWAY_PHASE_FILE"] = str(temp / "probe-phase")
            env["AWL_DEV_GATEWAY_RESULT_FILE"] = str(temp / "probe-result")
        try:
            validate_config(env)
        except ValueError:
            print("Isolated Gateway runner: safety preflight failed.", file=sys.stderr)
            return 2

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
            attempt_limit = 6 if args.expect_pairing_required else 3
            for approval_attempt in range(attempt_limit):
                if args.expect_pairing_required:
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
                if args.expect_pairing_required:
                    if result.returncode == 3:
                        print("Isolated real Gateway rejected unapproved read-only identity as expected.")
                        return 0
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
                              "retrying bounded negative contract probe.",
                              file=sys.stderr)
                        time.sleep(1)
                        continue
                    print("Isolated real Gateway negative-contract failed: "
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


if __name__ == "__main__":
    raise SystemExit(main())
