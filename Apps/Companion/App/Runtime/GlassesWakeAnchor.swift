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
///
/// The link is held only while listening is wanted after setup (`active`);
/// turning listening off cancels it, and "모두 지우고 처음부터" forgets the
/// stored peripherals. New pairs are adopted only when the DAT session shows
/// the glasses connected (`refresh()`), not any Meta device in range.
@MainActor
final class GlassesWakeAnchor: NSObject, CBCentralManagerDelegate {
    static let restoreIdentifier = "dev.agentwearlink.companion.glassesWake"
    static let metaService = CBUUID(string: "FD5F")
    private static let knownKey = CompanionSettingsStore.Key.glassesPeripherals

    var onLinked: (() -> Void)?
    var onUnlinked: (() -> Void)?
    var onLog: ((String) -> Void)?

    /// Peripherals with a pending (or established) link request: what can
    /// wake the app. Zero means the keep-alive must not rely on the anchor.
    var anchoredCount: Int { active ? peripherals.count : 0 }

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var failures: [UUID: Int] = [:]
    private var retries: [UUID: Task<Void, Never>] = [:]
    private var active = false
    /// `refresh()` came before Bluetooth was powered on.
    private var adoptWhenPoweredOn = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    /// Create at launch (also on a background relaunch, synchronously in
    /// `didFinishLaunching`), so restored state is delivered. Creating the
    /// manager may show the Bluetooth permission prompt once; the app already
    /// declares NSBluetoothAlwaysUsageDescription.
    func start(active: Bool) {
        self.active = active
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: false,
        ])
    }

    /// Hold the links while listening is wanted after setup; cancel them
    /// otherwise.
    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        guard let central, central.state == .poweredOn else { return }
        if active {
            onLog?("glasses wake: holding \(peripherals.count) pair(s)")
            for peripheral in peripherals.values { hold(peripheral, central) }
        } else {
            onLog?("glasses wake: released (listening off)")
            release(central)
        }
    }

    /// "모두 지우고 처음부터": cancel every link and forget the peripherals.
    func forget() {
        if let central, central.state == .poweredOn { release(central) }
        peripherals.removeAll()
        failures.removeAll()
        defaults.removeObject(forKey: Self.knownKey)
        adoptWhenPoweredOn = false
    }

    /// Call when the glasses are known to be connected (a DAT session just
    /// started) to pick up a newly paired pair.
    func refresh() {
        guard let central, central.state == .poweredOn else {
            adoptWhenPoweredOn = true
            return
        }
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
            if adoptWhenPoweredOn {
                adoptWhenPoweredOn = false
                adoptConnected(central)
            } else {
                logCounts(connected: nil)
            }
            guard active else { return }
            for peripheral in peripherals.values { hold(peripheral, central) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            failures[peripheral.identifier] = nil
            guard active else { return }
            onLog?("glasses wake: linked")
            onLinked?()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard active, peripherals[peripheral.identifier] != nil else { return }
            onLog?("glasses wake: unlinked")
            onUnlinked?()
            // Re-arm immediately: the pending request is what wakes us later.
            hold(peripheral, central)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard active, peripherals[peripheral.identifier] != nil else { return }
            let id = peripheral.identifier
            let count = (failures[id] ?? 0) + 1
            failures[id] = count
            let delay = WakeAnchorBackoff.delay(afterFailures: count)
            onLog?("glasses wake: connect failed \(count)x, re-arming in \(Int(delay)) s")
            retries[id]?.cancel()
            retries[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.active,
                      let central = self.central, central.state == .poweredOn,
                      let peripheral = self.peripherals[id] else { return }
                self.retries[id] = nil
                self.hold(peripheral, central)
            }
        }
    }

    // MARK: Private

    private func adoptConnected(_ central: CBCentralManager) {
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.metaService])
        for peripheral in connected where peripherals[peripheral.identifier] == nil {
            peripherals[peripheral.identifier] = peripheral
            if active { hold(peripheral, central) }
        }
        defaults.set(peripherals.keys.map(\.uuidString), forKey: Self.knownKey)
        logCounts(connected: connected.count)
    }

    /// Always logged, so a field log shows whether anything can wake the
    /// app (an empty anchor used to fail silently).
    private func logCounts(connected: Int?) {
        let seen = connected.map { "\($0) connected FD5F peripheral(s), " } ?? ""
        onLog?("glasses wake: \(seen)\(peripherals.count) anchored\(active ? "" : " (inactive)")")
    }

    private func hold(_ peripheral: CBPeripheral, _ central: CBCentralManager) {
        // Already linked or a request pending: a second connect() only
        // duplicates didConnect.
        guard peripheral.state != .connecting, peripheral.state != .connected else { return }
        central.connect(peripheral, options: nil)
    }

    private func release(_ central: CBCentralManager) {
        for task in retries.values { task.cancel() }
        retries.removeAll()
        for peripheral in peripherals.values where peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
    }
}
