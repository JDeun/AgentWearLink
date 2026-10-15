import CoreBluetooth
import Foundation

/// Keeps a pending Bluetooth LE connection to the paired glasses so iOS wakes
/// (or, after eviction, relaunches) the app when the glasses come back, with
/// no silent-audio keep-alive while they are away.
///
/// iOS keeps a `connect(_:)` request alive while the app is suspended and
/// delivers `didConnect` when the peripheral appears; with a restore
/// identifier it relaunches an evicted app (Apple TN3115; not after a user
/// force quit, which the Start Listening shortcut covers). The glasses are
/// found by Meta's registered Bluetooth service UUID 0xFD5F (Bluetooth SIG
/// assigned numbers: "Meta Platforms Technologies, LLC"). The anchor never
/// discovers services or exchanges data; it only holds the link request.
/// Precedent: LoopFollow holds such a request to another vendor's device as
/// its low-battery alternative to a silent-audio keep-alive.
@MainActor
final class GlassesWakeAnchor: NSObject, CBCentralManagerDelegate {
    static let restoreIdentifier = "dev.agentwearlink.companion.glassesWake"
    static let metaService = CBUUID(string: "FD5F")
    private static let knownKey = "awl.companion.glassesPeripherals"

    var onLinked: (() -> Void)?
    var onUnlinked: (() -> Void)?
    var onLog: ((String) -> Void)?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    /// Create at launch (also on a background relaunch), so restored state is
    /// delivered. Creating the manager may show the Bluetooth permission
    /// prompt once; the app already declares NSBluetoothAlwaysUsageDescription.
    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: false,
        ])
    }

    /// Call when the glasses are known to be connected (e.g. a DAT session
    /// just started) to pick up a newly paired pair.
    func refresh() {
        guard let central, central.state == .poweredOn else { return }
        adoptConnected(central)
    }

    // MARK: CBCentralManagerDelegate

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        MainActor.assumeIsolated {
            for peripheral in restored { peripherals[peripheral.identifier] = peripheral }
            onLog?("glasses wake: restored \(restored.count) peripheral(s)")
            if restored.contains(where: { $0.state == .connected }) { onLinked?() }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard central.state == .poweredOn else {
                onLog?("glasses wake: bluetooth state \(central.state.rawValue)")
                return
            }
            let known = (defaults.stringArray(forKey: Self.knownKey) ?? []).compactMap(UUID.init(uuidString:))
            for peripheral in central.retrievePeripherals(withIdentifiers: known) {
                peripherals[peripheral.identifier] = peripheral
            }
            adoptConnected(central)
            for peripheral in peripherals.values { hold(peripheral, central) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            onLog?("glasses wake: linked")
            onLinked?()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            onLog?("glasses wake: unlinked")
            onUnlinked?()
            // Re-arm immediately: the pending request is what wakes us later.
            hold(peripheral, central)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            onLog?("glasses wake: connect failed, re-arming")
            hold(peripheral, central)
        }
    }

    // MARK: Private

    private func adoptConnected(_ central: CBCentralManager) {
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.metaService])
        guard !connected.isEmpty else { return }
        for peripheral in connected where peripherals[peripheral.identifier] == nil {
            peripherals[peripheral.identifier] = peripheral
            onLog?("glasses wake: anchored a pair")
            hold(peripheral, central)
        }
        defaults.set(peripherals.keys.map(\.uuidString), forKey: Self.knownKey)
    }

    private func hold(_ peripheral: CBPeripheral, _ central: CBCentralManager) {
        guard peripheral.state != .connecting else { return }
        central.connect(peripheral, options: nil)
    }
}
