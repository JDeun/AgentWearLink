"""Static tripwire, not a substitute for code review or physical validation."""
import plistlib
import re
from pathlib import Path

root = Path(__file__).resolve().parent
source = "\n".join(p.read_text() for p in (root / "App").glob("*.swift"))
forbidden = (
    r"\b(?:connect|cancelPeripheralConnection|retrievePeripherals|"
    r"discoverServices|discoverIncludedServices|discoverCharacteristics|discoverDescriptors|"
    r"readValue|writeValue|setNotifyValue|openL2CAPChannel|startAdvertising|"
    r"registerForConnectionEvents|publishL2CAPChannel)\s*\(",
    r"\b(?:CBPeripheralManager|CBAdvertisementDataManufacturerDataKey|"
    r"CBCentralManagerOptionRestoreIdentifierKey|URLSession|UserDefaults|FileManager|"
    r"UIPasteboard|Logger|AVAudioSession)\b",
)
for pattern in forbidden:
    assert not re.search(pattern, source), f"Unexpected API surface: {pattern}"
assert "scanForPeripherals(withServices: [filter]," in source
assert "CBCentralManagerScanOptionAllowDuplicatesKey: false" in source
assert source.count("scanForPeripherals(") == 1
assert "retrieveConnectedPeripherals(withServices: [filter])" in source
with (root / "App/Info.plist").open("rb") as f:
    plist = plistlib.load(f)
assert "NSBluetoothAlwaysUsageDescription" in plist
for key in ("UIBackgroundModes", "NSMicrophoneUsageDescription", "NSCameraUsageDescription",
            "UISupportedExternalAccessoryProtocols", "NSLocalNetworkUsageDescription"):
    assert key not in plist, f"Unexpected privilege: {key}"
print("BLE discovery read-only API and plist tripwire passed")
