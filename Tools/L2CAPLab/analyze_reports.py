"""Offline consistency checker for AWL's sanitized lab reports, not proof of hardware."""
import json
import re
import statistics
import sys

SIZES = (64, 1024, 4096)
EXPECTED = tuple((size, trial) for size in SIZES for trial in range(1, 4))
MAX_INPUT = 65536
MAX_REPORT = 2048
UINT64_MAX = (1 << 64) - 1
LIMIT = 10000
OUTCOMES = frozenset((
    "success", "cancelled", "disconnected", "linkTimeout", "channelTimeout",
    "transferTimeout", "clockRegression", "ioError", "invalidCount",
    "unexpectedPayload", "prematureEOF",
))
PASS_TERMINALS = {
    "initiator": frozenset(("completed",)),
    "responder": frozenset(("peer-closed-after-local-complete", "responder-drain-deadline")),
}
TERMINALS = OUTCOMES - {"success"} | frozenset((
    "completed", "peer-closed-after-local-complete", "responder-drain-deadline",
    "no-fixture", "setup-timeout", "missing-streams", "stream-error",
    "radio-state-lost", "radio-unavailable", "ambiguous-fixture", "connect-failed",
    "lab-service-mismatch", "lab-marker-missing", "lab-marker-mismatch",
    "channel-open-failed", "publish-failed", "service-add-failed", "advertising-failed",
    "unexpected-incoming-channel",
))
COMMON = {
    "scope": "synthetic-lab-only",
    "meta-transport": "not-tested",
    "wake-and-power": "not-tested",
    "cleanup": "requested-not-physically-verified",
}
BASE_KEYS = set(COMMON) | {"outcome", "driver-terminal", "listener-to-open-ms"}
TIME_KEYS = ("link-elapsed-ms", "channel-elapsed-ms", "transfer-elapsed-ms", "total-elapsed-ms")
FULL_KEYS = BASE_KEYS | set(TIME_KEYS) | {
    "report-version", "role", "phase", "fixture-bytes", "sent-bytes", "verified-received-bytes",
}

class Invalid(ValueError):
    """Only fixed error codes may be emitted."""

def require(condition, code):
    if not condition:
        raise Invalid(code)

def uint(text):
    require(re.fullmatch(r"0|[1-9][0-9]{0,19}", text) is not None, "invalid-number")
    number = int(text)
    require(number <= UINT64_MAX, "number-overflow")
    return number

def timing(text):
    return None if text == "not-observed" else uint(text)

def parse_report(raw, role, size):
    require(type(raw) is str and len(raw) <= MAX_REPORT and raw.isascii(), "invalid-report-text")
    # Accept app text with LF or CRLF and one final newline, but no arbitrary whitespace.
    lines = raw.replace("\r\n", "\n").removesuffix("\n").split("\n")
    fields = {}
    for line in lines:
        require(line.count("=") == 1, "invalid-report-line")
        key, value = line.split("=", 1)
        require(key not in fields, "duplicate-report-key")
        require(key in FULL_KEYS, "unknown-report-key")
        fields[key] = value
    require(set(fields) in (BASE_KEYS, FULL_KEYS), "invalid-report-schema")
    require(all(fields[k] == v for k, v in COMMON.items()), "invalid-evidence-marker")
    terminal = fields["driver-terminal"]
    require(terminal in TERMINALS, "unknown-terminal")
    listener = timing(fields["listener-to-open-ms"])
    outcome = fields["outcome"]
    all_pass_terminals = PASS_TERMINALS["initiator"] | PASS_TERMINALS["responder"]

    if set(fields) == BASE_KEYS:
        require(outcome == "not-tested" and terminal not in all_pass_terminals
                and listener is None, "inconsistent-setup-terminal")
        return {"state": "failed", "reason": terminal}

    require(fields["report-version"] == "1", "unsupported-report-version")
    require(fields["role"] == role and fields["phase"] == "finished", "wrong-role-or-phase")
    require(outcome in OUTCOMES, "unknown-outcome")
    require(uint(fields["fixture-bytes"]) == size, "wrong-fixture-size")
    sent = uint(fields["sent-bytes"])
    received = uint(fields["verified-received-bytes"])
    require(sent <= size and received <= size, "count-exceeds-fixture")
    if role == "initiator":
        require(received == 0 or sent == size, "invalid-transfer-order")
    else:
        require(sent == 0 or received == size, "invalid-transfer-order")
    link, channel, transfer, total = (timing(fields[k]) for k in TIME_KEYS)
    require(total is not None, "missing-total-time")
    require(all(t is None or t <= total for t in (link, channel, transfer)), "inconsistent-time")
    if role == "initiator":
        require(listener is None, "unexpected-listener-time")
        require(channel is None or link is not None, "missing-link-time")
        require(transfer is None or channel is not None, "missing-channel-time")
        require(all(t is None or t < LIMIT for t in (link, channel)), "late-stage-transition")
        stage_sum = sum(t for t in (link, channel, transfer) if t is not None)
        require(stage_sum <= total and (transfer is None or stage_sum == total), "inconsistent-time")
        require(transfer is not None or (sent == 0 and received == 0), "io-before-channel")
    else:
        require(link is None and channel is None, "invented-responder-stage-time")
        require(listener is not None and listener < 90000, "invalid-listener-time")
        require(transfer is not None and transfer == total, "inconsistent-time")

    if outcome != "success":
        require(terminal not in all_pass_terminals, "inconsistent-terminal")
        require(not (sent == size and received == size), "inconsistent-counts")
        return {"state": "failed", "reason": terminal, "policy-outcome": outcome}

    require(sent == size and received == size, "incomplete-success-count")
    require(transfer is not None and transfer < LIMIT and total < 3 * LIMIT, "late-success")
    if terminal not in PASS_TERMINALS[role]:
        require(terminal not in all_pass_terminals, "wrong-role-terminal")
        return {"state": "failed", "reason": terminal, "policy-outcome": outcome}
    return {"state": "passed", "total-ms": total, "transfer-ms": transfer}

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate-json-key")
        result[key] = value
    return result

def no_constant(_value):
    raise Invalid("invalid-json-number")

def load_manifest(raw):
    require(type(raw) is bytes and len(raw) <= MAX_INPUT, "manifest-too-large")
    try:
        obj = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object,
                         parse_constant=no_constant)
    except Invalid:
        raise
    except (ValueError, RecursionError):
        raise Invalid("invalid-json") from None
    require(type(obj) is dict and set(obj) == {"schema", "trials"}, "invalid-manifest-schema")
    require(type(obj["schema"]) is int and obj["schema"] == 1, "unsupported-manifest-version")
    require(type(obj["trials"]) is list and len(obj["trials"]) <= len(EXPECTED), "invalid-trial-list")
    slots = {}
    for trial in obj["trials"]:
        require(type(trial) is dict and set(trial) == {"size", "trial", "initiator", "responder"},
                "invalid-trial-schema")
        size, number = trial["size"], trial["trial"]
        require(type(size) is int and type(number) is int and (size, number) in EXPECTED, "invalid-trial-slot")
        require((size, number) not in slots, "duplicate-trial-slot")
        slots[(size, number)] = trial
    return slots

def endpoint(raw, role, size):
    if raw is None:
        return {"state": "missing", "reason": "missing-report"}
    try:
        return parse_report(raw, role, size)
    except Invalid as err:
        return {"state": "invalid", "reason": str(err)}

def describe(values):
    if not values:
        return {"n": 0}
    return {"n": len(values), "min": min(values), "median": statistics.median(values), "max": max(values)}

def assess(slots):
    rows = []
    counts = {state: 0 for state in ("passed", "failed", "missing", "invalid")}
    for size, number in EXPECTED:
        raw = slots.get((size, number), {})
        i = endpoint(raw.get("initiator"), "initiator", size)
        r = endpoint(raw.get("responder"), "responder", size)
        states = {i["state"], r["state"]}
        # Invalid text takes precedence; a known failure is preserved even when its peer is missing.
        state = next(s for s in ("invalid", "failed", "missing", "passed") if s in states)
        counts[state] += 1
        rows.append({"size": size, "trial": number, "state": state, "initiator": i, "responder": r})
    by_size = []
    for size in SIZES:
        pairs = [row for row in rows if row["size"] == size and row["state"] == "passed"]
        by_size.append({
            "size": size, "passing-pairs": len(pairs), "expected-pairs": 3,
            "initiator-total-ms": describe([row["initiator"]["total-ms"] for row in pairs]),
            "responder-transfer-ms": describe([row["responder"]["transfer-ms"] for row in pairs]),
        })
    return {
        "schema": 1, "assessment": "all-report-pairs-passed" if counts["passed"] == 9 else "matrix-not-passed",
        "scope": "sanitized-text-consistency-only",
        "correlation": "manual-not-verified", "physical-evidence": "not-verified",
        "link-encryption": "not-verified", "physical-cleanup": "not-verified",
        "meta-transport": "not-tested", "wake-and-power": "not-tested",
        "counts": counts, "trials": rows, "by-size": by_size,
    }

def main():
    try:
        slots = load_manifest(sys.stdin.buffer.read(MAX_INPUT + 1))
        result = assess(slots)
    except Invalid as err:
        print(json.dumps({"assessment": "invalid-manifest", "reason": str(err)}, sort_keys=True))
        return 2
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["assessment"] == "all-report-pairs-passed" else 1

if __name__ == "__main__":
    sys.exit(main())
