#!/usr/bin/env python3
"""Fail-closed checks for an *isolated local* real OpenClaw Gateway test.

This validator is pure and safe to run in CI; it does not start a Gateway,
read credentials, or make network requests.
"""

from __future__ import annotations

import ipaddress
import os
import re
import sys
from urllib.parse import urlsplit


def validate_config(config: dict[str, str]) -> dict[str, str]:
    if config.get("AWL_ALLOW_DEV_GATEWAY_TEST") != "1":
        raise ValueError("set AWL_ALLOW_DEV_GATEWAY_TEST=1 explicitly")

    endpoint = config.get("AWL_OPENCLAW_URL", "")
    try:
        parsed = urlsplit(endpoint)
        hostname = parsed.hostname
        port = parsed.port
    except ValueError as exc:
        raise ValueError("invalid Gateway URL") from exc
    if (
        parsed.scheme not in ("ws", "wss")
        or not hostname
        or port is None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in ("", "/")
    ):
        raise ValueError("use a loopback ws:// or wss:// URL with an explicit port and no credentials")

    if hostname != "localhost":
        try:
            if not ipaddress.ip_address(hostname).is_loopback:
                raise ValueError("remote gateways are prohibited by this development harness")
        except ValueError as exc:
            raise ValueError("Gateway hostname must be a loopback IP or localhost") from exc

    if not config.get("AWL_OPENCLAW_TOKEN", "").strip():
        raise ValueError("an isolated development Gateway token is required")
    if config.get("AWL_OPENCLAW_BOOTSTRAP_TOKEN"):
        raise ValueError("bootstrap grants must not be supplied to the development harness")

    session_key = config.get("AWL_OPENCLAW_SESSION_KEY", "").strip()
    # Fail closed on arbitrary existing session keys. A development marker alone
    # does not prove the running Gateway is isolated; require both an explicit
    # opt-in and an AWL-specific session namespace to reduce cross-use mistakes.
    if not re.fullmatch(r"agent:[A-Za-z0-9_-]+:awl-dev-[A-Za-z0-9_-]+", session_key):
        raise ValueError("use a dedicated agent:<id>:awl-dev-<name> development session key")

    revision = config.get("AWL_DEV_GATEWAY_REVISION", "")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", revision):
        raise ValueError("record the exact 40-character Gateway source commit as AWL_DEV_GATEWAY_REVISION")

    if config.get("AWL_OPENCLAW_EXPOSURE", "loopback") != "loopback":
        raise ValueError("development harness only accepts AWL_OPENCLAW_EXPOSURE=loopback")
    if config.get("AWL_OPENCLAW_CHAT_MESSAGE"):
        raise ValueError("leave AWL_OPENCLAW_CHAT_MESSAGE unset; harness creates a harmless marker")
    if config.get("AWL_DEV_GATEWAY_PROVE_ABORT", "0") not in ("0", "1"):
        raise ValueError("AWL_DEV_GATEWAY_PROVE_ABORT must be 0 or 1")
    if config.get("AWL_DEV_GATEWAY_HEALTH_ONLY", "0") not in ("0", "1"):
        raise ValueError("AWL_DEV_GATEWAY_HEALTH_ONLY must be 0 or 1")
    if (config.get("AWL_DEV_GATEWAY_PROVE_ABORT") == "1"
            and config.get("AWL_DEV_GATEWAY_HEALTH_ONLY") == "1"):
        raise ValueError("abort proof requires mutating Gateway probe")
    if config.get("AWL_DEV_GATEWAY_ABORT_ASSERT"):
        raise ValueError("leave AWL_DEV_GATEWAY_ABORT_ASSERT unset; only the runner may set it")

    return {
        "gateway_url": endpoint,
        "gateway_revision": revision,
        "session_key_kind": "explicit-isolated",
    }


def main() -> int:
    try:
        config = validate_config(dict(os.environ))
    except ValueError as exc:
        print(f"Development Gateway preflight failed: {exc}", file=sys.stderr)
        return 2
    print(
        "Development Gateway preflight OK:"
        f" revision={config['gateway_revision']}"
        " endpoint=loopback isolated_session=yes"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
