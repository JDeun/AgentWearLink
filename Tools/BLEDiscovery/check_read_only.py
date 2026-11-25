"""Static tripwire, not a substitute for code review or physical validation."""
import plistlib
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent
source = "\n".join(p.read_text() for directory in (root / "App", root / "Sources")
                   for p in directory.rglob("*.swift"))
forbidden = (
    r"\b(?:connect|cancelPeripheralConnection|retrievePeripherals|"
    r"discoverServices|discoverIncludedServices|discoverCharacteristics|discoverDescriptors|"
    r"readValue|writeValue|setNotifyValue|openL2CAPChannel|startAdvertising|"
    r"registerForConnectionEvents|publishL2CAPChannel)\s*\(",
    r"\b(?:CBPeripheralManager|CBAdvertisementDataManufacturerDataKey|"
    r"CBCentralManagerOptionRestoreIdentifierKey|URLSession|UserDefaults|FileManager|"
    r"UIPasteboard|Logger|AVAudioSession|CBAdvertisementDataIsConnectableKey)\b",
)
for pattern in forbidden:
    assert not re.search(pattern, source), f"Unexpected API surface: {pattern}"
assert "scanForPeripherals(withServices: [filter]," in source
assert "CBCentralManagerScanOptionAllowDuplicatesKey: false" in source
assert source.count("scanForPeripherals(") == 1
assert "retrieveConnectedPeripherals(withServices: [filter])" in source

# Policy tests inject timestamps directly; check that the app supplies one too.
probe_source = (root / "App/BLEProbe.swift").read_text()
discovery_delegate = re.search(
    r"(?ms)^    func centralManager\([^)]*\bdidDiscover\b[^)]*\)\s*\{\n(.*?)^    \}",
    probe_source,
)
assert discovery_delegate, "Missing advertisement delegate"
assert re.search(
    r"\bsession\.record\([^)]*\bobservation:\s*observation,\s*elapsedMS:\s*elapsedMS\(\)\s*\)",
    discovery_delegate[1],
), "Advertisement delegate must forward the monotonic callback time"


def check_plist(path):
    with path.open("rb") as f:
        plist = plistlib.load(f)
    assert plist.get("NSBluetoothAlwaysUsageDescription"), "Missing Bluetooth explanation"
    for key in ("UIBackgroundModes", "NSMicrophoneUsageDescription", "NSCameraUsageDescription",
                "UISupportedExternalAccessoryProtocols", "NSLocalNetworkUsageDescription"):
        assert key not in plist, f"Unexpected privilege: {key}"


check_plist(root / "App/Info.plist")
if len(sys.argv) > 1:
    assert len(sys.argv) == 2, "Expected one built Info.plist path"
    built = Path(sys.argv[1])
    check_plist(built)
    with built.open("rb") as f:
        assert plistlib.load(f)["CFBundleIdentifier"] == "dev.agentwearlink.research.blediscovery"
    print("Built BLE diagnostic bundle privacy check passed")
print("BLE discovery read-only API and plist tripwire passed")
