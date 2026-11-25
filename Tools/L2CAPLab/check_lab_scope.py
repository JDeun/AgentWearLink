"""Static tripwire for isolated lab apps; not a security or physical proof."""
import plistlib
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent
source = "\n".join(p.read_text() for p in (root / "App").rglob("*.swift"))
for forbidden in (
    r"\b(?:writeValue|setNotifyValue|retrievePeripherals|retrieveConnectedPeripherals|removeAllServices)\s*\(",
    r"\b(?:URLSession|UserDefaults|FileManager|UIPasteboard|Logger|AVAudioSession|CBCentralManagerOptionRestoreIdentifierKey|CBPeripheralManagerOptionRestoreIdentifierKey)\b",
):
    assert not re.search(forbidden, source), forbidden
assert source.count("openL2CAPChannel(") == 1
assert source.count("publishL2CAPChannel(withEncryption: true)") == 1
assert source.count("scanForPeripherals(withServices: [filter]") == 1
assert "invite.matchesMarker(characteristic.value)" in source
assert "responderChannelOpened(generation: token" in source
assert "manager.unpublishL2CAPChannel(psm)" in source
assert "retiredServer" in source
assert "private var lifecycle = LabDriverLifecycle()" in source
assert "lifecycle.tick(generation: token" in source
assert "lifecycle.move(generation: token" in source
assert "lifecycle.retire(generation: old)" in source
assert "retiredCallbacks.consume(.publishing)" in source
assert "retiredCallbacks.consume(.adding)" in source
assert "retiredCallbacks.consume(.advertising)" in source
assert source.count("lifecycle.acknowledgeServerOperation(generation: token") == 3
for path, identifier in zip(sys.argv[1:], (
    "dev.agentwearlink.research.l2cap.phone", "dev.agentwearlink.research.l2cap.mac"
)):
    with Path(path).open("rb") as f:
        plist = plistlib.load(f)
    assert plist.get("CFBundleIdentifier") == identifier
    assert plist.get("NSBluetoothAlwaysUsageDescription")
    for forbidden in ("UIBackgroundModes", "NSMicrophoneUsageDescription", "NSCameraUsageDescription",
                      "UISupportedExternalAccessoryProtocols", "NSLocalNetworkUsageDescription"):
        assert forbidden not in plist, forbidden
assert len(sys.argv) in (1, 3)
print("Lab scope and requested built plist checks passed")
