#!/usr/bin/env python3
"""Verify AgentWearLink's supported OpenClaw wire subset against pinned upstream source.

The pin is intentional: PRs remain reproducible and do not become red because
OpenClaw main moves. To adopt a newer upstream contract, update UPSTREAM_COMMIT,
review every assertion below, update the Swift contract tests, and record the
new pin in docs/openclaw-protocol-contract.md.
"""

from __future__ import annotations

import re
import sys
import urllib.error
import urllib.request

UPSTREAM_REPOSITORY = "openclaw/openclaw"
UPSTREAM_COMMIT = "172a5d6202214eea253234c3b04c8184df9fea70"
RAW_BASE = (
    f"https://raw.githubusercontent.com/{UPSTREAM_REPOSITORY}/"
    f"{UPSTREAM_COMMIT}/"
)

PATHS = {
    "version": "packages/gateway-protocol/src/version.ts",
    "frames": "packages/gateway-protocol/src/schema/frames.ts",
    "client_info": "packages/gateway-protocol/src/client-info.ts",
    "agent": "packages/gateway-protocol/src/schema/agent.ts",
    "chat": "packages/gateway-protocol/src/schema/logs-chat.ts",
    "device_auth": "packages/gateway-client/src/device-auth.ts",
    "wait": "src/agents/run-wait.types.ts",
    "connection": "src/gateway/server/connection.ts",
}


def fetch(path: str) -> str:
    url = RAW_BASE + path
    try:
        with urllib.request.urlopen(url, timeout=20) as response:
            return response.read().decode("utf-8")
    except (urllib.error.URLError, TimeoutError, UnicodeDecodeError) as exc:
        raise RuntimeError(f"unable to fetch pinned upstream source {path}: {exc}") from exc


def compact(source: str) -> str:
    return re.sub(r"\s+", " ", source)


def require(source: str, needle: str, label: str) -> None:
    if needle not in source:
        raise AssertionError(f"{label}: expected upstream contract fragment not found: {needle!r}")


def require_order(source: str, needles: list[str], label: str) -> None:
    cursor = -1
    for needle in needles:
        position = source.find(needle, cursor + 1)
        if position < 0:
            raise AssertionError(f"{label}: missing ordered fragment {needle!r}")
        if position <= cursor:
            raise AssertionError(f"{label}: fragment order changed at {needle!r}")
        cursor = position


def section(source: str, start: str, end: str) -> str:
    start_index = source.find(start)
    if start_index < 0:
        raise AssertionError(f"missing section start {start!r}")
    end_index = source.find(end, start_index + len(start))
    if end_index < 0:
        raise AssertionError(f"missing section end {end!r}")
    return source[start_index:end_index]


def verify() -> None:
    sources = {name: fetch(path) for name, path in PATHS.items()}

    version = compact(sources["version"])
    require(
        version,
        "export const PROTOCOL_VERSION = 4 as const;",
        "protocol version",
    )

    client_info = compact(sources["client_info"])
    for fragment in [
        'GATEWAY_CLIENT: "gateway-client"',
        'PROBE: "openclaw-probe"',
        'BACKEND: "backend"',
        'PROBE: "probe"',
    ]:
        require(client_info, fragment, "client identity registry")

    frames = compact(sources["frames"])
    connect = section(frames, "export const ConnectParamsSchema", "export const HelloOkSchema")
    for field in [
        "minProtocol:",
        "maxProtocol:",
        "client:",
        "role:",
        "scopes:",
        "device:",
        "auth:",
        "locale:",
    ]:
        require(connect, field, "connect params")
    auth = section(connect, "auth: Type.Optional", "locale:")
    require_order(
        auth,
        [
            "token:",
            "bootstrapToken:",
            "deviceToken:",
            "password:",
        ],
        "connect auth field placement",
    )

    hello = section(frames, "export const HelloOkSchema", "export const ErrorShapeSchema")
    for field in [
        'type: Type.Literal("hello-ok")',
        "protocol:",
        "server:",
        "features:",
        "snapshot:",
        "auth:",
        "policy:",
        "maxPayload:",
        "maxBufferedBytes:",
        "tickIntervalMs:",
    ]:
        require(hello, field, "hello-ok")

    handoff = section(hello, "deviceTokens: Type.Optional", "policy:")
    for field in ["deviceToken:", "role:", "scopes:", "issuedAtMs:"]:
        require(handoff, field, "bootstrap handoff grants")

    for auth_method in [
        '"none"',
        '"token"',
        '"password"',
        '"tailscale"',
        '"device-token"',
        '"bootstrap-token"',
        '"trusted-proxy"',
    ]:
        require(hello, auth_method, "hello auth method registry")

    for schema_name in [
        "RequestFrameSchema",
        "ResponseFrameSchema",
        "EventFrameSchema",
    ]:
        require(frames, f"export const {schema_name}", "frame envelopes")

    agent = compact(sources["agent"])
    agent_params = section(
        agent,
        "export const AgentParamsSchema",
        "export const AgentIdentityParamsSchema",
    )
    for field in ["message:", "sessionKey:", "attachments:", "idempotencyKey:"]:
        require(agent_params, field, "agent request")

    wait_params = section(
        agent,
        "export const AgentWaitParamsSchema",
        "export const WakeParamsSchema",
    )
    require(wait_params, "runId:", "agent.wait params")
    require(wait_params, "timeoutMs:", "agent.wait params")

    wait_result = compact(sources["wait"])
    require(
        wait_result,
        'status: "ok" | "timeout" | "error" | "pending";',
        "agent.wait statuses",
    )

    chat = compact(sources["chat"])
    abort = section(
        chat,
        "export const ChatAbortParamsSchema",
        "export const ChatInjectParamsSchema",
    )
    for field in [
        "sessionKey:",
        "agentId:",
        "runId:",
        "preserveSideRuns:",
        "discardPendingInput:",
    ]:
        require(abort, field, "chat.abort params")

    device_auth = compact(sources["device_auth"])
    require(device_auth, '"v3"', "device auth V3")
    require(device_auth, "normalizeDeviceMetadataForAuth(params.platform)", "device auth platform normalization")
    require(device_auth, "normalizeDeviceMetadataForAuth(params.deviceFamily)", "device auth device-family normalization")
    require_order(
        device_auth,
        [
            '"v3"',
            "params.deviceId",
            "params.clientId",
            "params.clientMode",
            "params.role",
            "scopes",
            "String(params.signedAtMs)",
            "token",
            "params.nonce",
            "platform",
            "deviceFamily",
        ],
        "device auth V3 tuple",
    )

    connection = compact(sources["connection"])
    challenge_index = connection.find('"connect.challenge"')
    if challenge_index < 0:
        raise AssertionError("connect.challenge event is absent from upstream server")
    challenge_window = connection[challenge_index : challenge_index + 700]
    require(challenge_window, "nonce:", "connect.challenge")
    require(challenge_window, "ts:", "connect.challenge")

    print(
        "OpenClaw protocol contract verified:",
        f"{UPSTREAM_REPOSITORY}@{UPSTREAM_COMMIT}",
    )


if __name__ == "__main__":
    try:
        verify()
    except Exception as exc:
        print(f"OpenClaw protocol contract verification failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
