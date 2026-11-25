import json
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import analyze_reports as ar

def report(role, size=64, **overrides):
    initiator = role == "initiator"
    fields = {
        "report-version": "1", "scope": "synthetic-lab-only",
        "role": role, "phase": "finished", "outcome": "success",
        "fixture-bytes": str(size), "sent-bytes": str(size), "verified-received-bytes": str(size),
        "link-elapsed-ms": "10" if initiator else "not-observed",
        "channel-elapsed-ms": "20" if initiator else "not-observed",
        "transfer-elapsed-ms": "30", "total-elapsed-ms": "60" if initiator else "30",
        "meta-transport": "not-tested", "wake-and-power": "not-tested",
        "driver-terminal": "completed" if initiator else "peer-closed-after-local-complete",
        "listener-to-open-ms": "not-observed" if initiator else "50",
        "cleanup": "requested-not-physically-verified",
    }
    fields.update(overrides)
    return "\n".join(f"{k}={v}" for k, v in fields.items())

def setup_failure():
    return "\n".join([
        "scope=synthetic-lab-only", "outcome=not-tested", "meta-transport=not-tested",
        "wake-and-power=not-tested", "driver-terminal=radio-unavailable",
        "listener-to-open-ms=not-observed", "cleanup=requested-not-physically-verified",
    ])

def trial(size=64, number=1, **overrides):
    value = {"size": size, "trial": number, "initiator": report("initiator", size),
             "responder": report("responder", size)}
    value.update(overrides)
    return value

def manifest(trials):
    return json.dumps({"schema": 1, "trials": trials}).encode()

def assess(trials):
    return ar.assess(ar.load_manifest(manifest(trials)))

def cli(raw):
    return subprocess.run([sys.executable, str(ROOT / "analyze_reports.py")],
                          input=raw, capture_output=True, check=False)

class ReportTests(unittest.TestCase):
    def test_complete_matrix_is_only_text_assessment(self):
        result = assess([trial(size, n) for size, n in ar.EXPECTED])
        self.assertEqual(result["counts"], {"passed": 9, "failed": 0, "missing": 0, "invalid": 0})
        self.assertEqual(result["assessment"], "all-report-pairs-passed")
        self.assertEqual(result["physical-evidence"], "not-verified")
        self.assertEqual(result["correlation"], "manual-not-verified")
        self.assertEqual(result["by-size"][0]["initiator-total-ms"], {"n":3,"min":60,"median":60,"max":60})
        self.assertEqual(cli(manifest([trial(s,n) for s,n in ar.EXPECTED])).returncode, 0)

    def test_missing_slots_and_peer(self):
        result = assess([trial(responder=None)])
        self.assertEqual(result["counts"]["missing"], 9)
        self.assertEqual(result["trials"][0]["initiator"]["state"], "passed")
        self.assertEqual(result["by-size"][0]["initiator-total-ms"], {"n":0})
        self.assertEqual(cli(manifest([])).returncode, 1)

    def test_setup_failure_is_preserved_even_when_peer_missing(self):
        result = assess([trial(initiator=setup_failure(), responder=None)])
        self.assertEqual(result["trials"][0]["state"], "failed")
        self.assertEqual(result["trials"][0]["initiator"]["reason"], "radio-unavailable")

    def test_success_policy_but_cancelled_driver_is_not_pass(self):
        result = assess([trial(responder=report("responder", **{"driver-terminal":"cancelled"}))])
        self.assertEqual(result["trials"][0]["state"], "failed")
        self.assertEqual(result["counts"]["passed"], 0)

    def test_responder_drain_requires_passing_peer(self):
        drain = report("responder", **{"driver-terminal":"responder-drain-deadline"})
        self.assertEqual(assess([trial(responder=drain)])["counts"]["passed"], 1)
        self.assertEqual(assess([trial(initiator=None, responder=drain)])["counts"]["passed"], 0)

    def test_failure_policy_not_counted_as_success(self):
        failed = report("initiator", **{"outcome":"transferTimeout","driver-terminal":"transferTimeout",
            "verified-received-bytes":"0","transfer-elapsed-ms":"10100","total-elapsed-ms":"10130"})
        result = assess([trial(initiator=failed)])
        self.assertEqual(result["trials"][0]["state"], "failed")
        self.assertEqual(result["trials"][0]["initiator"]["policy-outcome"], "transferTimeout")

    def test_invalid_schema_values_never_pass(self):
        cases = [
            {"report-version":"2"}, {"phase":"transferring"}, {"role":"responder"},
            {"fixture-bytes":"1024"}, {"sent-bytes":"65"}, {"verified-received-bytes":"63"},
            {"sent-bytes":"063"}, {"total-elapsed-ms":"59"}, {"transfer-elapsed-ms":"10000"},
            {"link-elapsed-ms":"not-observed"}, {"listener-to-open-ms":"12"},
            {"driver-terminal":"peer-closed-after-local-complete"}, {"outcome":"pending"},
            {"meta-transport":"verified"}, {"cleanup":"verified"}, {"wake-and-power":"verified"},
            {"total-elapsed-ms":str(2**64)}, {"link-elapsed-ms":"10000"},
        ]
        for values in cases:
            with self.subTest(values=values):
                self.assertEqual(assess([trial(initiator=report("initiator", **values))])["counts"]["invalid"], 1)

    def test_responder_missing_or_invented_time(self):
        for values in ({"link-elapsed-ms":"0"}, {"channel-elapsed-ms":"0"},
                       {"listener-to-open-ms":"not-observed"}, {"listener-to-open-ms":"90000"},
                       {"total-elapsed-ms":"31"}):
            self.assertEqual(assess([trial(responder=report("responder", **values))])["counts"]["invalid"], 1)

    def test_duplicate_unknown_and_private_text_not_echoed(self):
        secret = "PRIVATE-INVITATION-DO-NOT-ECHO"
        for raw in (report("initiator")+"\nrole=initiator",
                    report("initiator")+"\npeer="+secret,
                    report("initiator", **{"driver-terminal":secret}),
                    report("initiator").replace("phase=finished\n", ""),
                    "A"*2049, "", 123):
            run = cli(manifest([trial(initiator=raw)]))
            self.assertEqual(run.returncode, 1)
            self.assertNotIn(secret.encode(), run.stdout+run.stderr)
            self.assertEqual(json.loads(run.stdout)["counts"]["invalid"], 1)

    def test_crlf_and_single_newline(self):
        result = assess([trial(initiator=report("initiator").replace("\n","\r\n")+"\r\n")])
        self.assertEqual(result["counts"]["passed"], 1)

    def test_wrong_order_and_failed_success_terminal(self):
        for values in ({"sent-bytes":"20","verified-received-bytes":"3"},
                       {"outcome":"ioError","verified-received-bytes":"0"}):
            self.assertEqual(assess([trial(initiator=report("initiator", **values))])["counts"]["invalid"],1)

    def test_duplicate_or_invalid_manifest_is_exit_two(self):
        for raw in (manifest([trial(),trial()]), manifest([trial(size=64,number=4)]),
                    manifest([trial(number=True)]), b'{"schema":1,"schema":1,"trials":[]}',
                    b'{"schema":true,"trials":[]}', b'{"schema":1,"trials":NaN}',
                    b'{"schema":1,"trials":[],"note":"PRIVATE-INVITATION-DO-NOT-ECHO"}',
                    b"["*10000, b"\xff", b" "*65537):
            run = cli(raw)
            self.assertEqual(run.returncode, 2)
            self.assertNotIn(b"PRIVATE-INVITATION-DO-NOT-ECHO", run.stdout+run.stderr)
            self.assertEqual(json.loads(run.stdout)["assessment"], "invalid-manifest")

if __name__ == "__main__":
    unittest.main()
