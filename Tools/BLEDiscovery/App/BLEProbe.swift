import CoreBluetooth
import Foundation
import Combine
import Dispatch

/// The UI and all CoreBluetooth callbacks run on the main queue. A fresh
/// manager belongs to one explicitly started run; identity + token fence
/// late delegate callbacks. No peripheral delegate or local connection.
final class BLEProbe: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var session = ProbeSession()
    private var manager: CBCentralManager?
    private var filter: CBUUID?
    private var timeout: DispatchWorkItem?
    private var deadline: DispatchTime?
    private var startedAt: DispatchTime?

    func start(service: String, ownerConsent: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard ownerConsent, !session.status.isActive,
              let normalized = ServiceFilter.normalized(service) else { return }
        let token = UUID()
        guard session.begin(token: token) else { return }
        filter = CBUUID(string: normalized)
        let start = DispatchTime.now()
        startedAt = start
        let limit = start + .seconds(ProbeSession.durationSeconds)
        deadline = limit
        let task = DispatchWorkItem { [weak self] in self?.expire(token: token) }
        timeout = task
        DispatchQueue.main.asyncAfter(deadline: limit, execute: task)
        // Instantiation (and any permission prompt) is opt-in, never startup.
        manager = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let token = session.token { finish(token: token, outcome: .userStopped) }
    }

    func clear() {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        session.clear()
    }

    func confirm(candidate: Int, independentlyIdentified: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        session.confirm(id: candidate, independentlyIdentified: independentlyIdentified)
    }

    func revokeConfirmation() {
        dispatchPrecondition(condition: .onQueue(.main))
        session.revokeConfirmation()
    }

    private func expire(token: UUID) {
        guard session.token == token else { return }
        let outcome: ProbeStatus = session.didRequestScan ? .completed : .initializationTimedOut
        finish(token: token, outcome: outcome)
    }

    private func currentToken(for central: CBCentralManager) -> UUID? {
        guard manager === central, let token = session.token,
              let deadline else { return nil }
        guard DispatchTime.now() < deadline else {
            expire(token: token)
            return nil
        }
        return token
    }

    private func elapsedMS() -> Int? {
        guard let start = startedAt else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= start.uptimeNanoseconds else { return nil }
        return Int(clamping: (now - start.uptimeNanoseconds) / 1_000_000)
    }

    private func finish(token: UUID, outcome: ProbeStatus) {
        guard session.finish(token: token, status: outcome, elapsedMS: elapsedMS()) else { return }
        // Invalidate the identity before releasing the manager or timer.
        let retired = manager
        manager = nil
        filter = nil
        deadline = nil
        startedAt = nil
        timeout?.cancel()
        timeout = nil
        if let retired {
            if retired.state == .poweredOn && retired.isScanning { retired.stopScan() }
            retired.delegate = nil
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let token = currentToken(for: central), let filter else { return }
        switch central.state {
        case .poweredOn:
            guard session.startScan(token: token) else { return }
            // This is a system-wide snapshot, possibly from another app.
            // It does not imply this app owns a connection or can access GATT.
            for peripheral in central.retrieveConnectedPeripherals(withServices: [filter]) {
                let observation = ProbeObservation(localName: peripheral.name,
                                                   systemConnectedSnapshot: true)
                if session.record(token: token, peripheralID: peripheral.identifier,
                                  observation: observation, elapsedMS: elapsedMS()) == .capacityExceeded {
                    finish(token: token, outcome: .candidateLimit)
                    return
                }
            }
            guard currentToken(for: central) == token else { return }
            // Mark immediately before the request on the same serial queue.
            guard session.markScanRequested(token: token, elapsedMS: elapsedMS()) else { return }
            central.scanForPeripherals(withServices: [filter],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .unknown:
            if session.status == .scanning { finish(token: token, outcome: .unknownState) }
        case .resetting: finish(token: token, outcome: .resetting)
        case .unsupported: finish(token: token, outcome: .unsupported)
        case .unauthorized: finish(token: token, outcome: .unauthorized)
        case .poweredOff: finish(token: token, outcome: .poweredOff)
        @unknown default: finish(token: token, outcome: .unknownState)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let token = currentToken(for: central), let filter,
              session.status == .scanning else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        // Examine only whether the requested service has an entry, not bytes.
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let observation = ProbeObservation(
            localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name,
            advertisement: true,
            serviceAdvertised: services.contains(filter) || overflow.contains(filter),
            serviceDataPresent: serviceData?[filter] != nil,
            connectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        )
        if session.record(token: token, peripheralID: peripheral.identifier,
                          observation: observation) == .capacityExceeded {
            finish(token: token, outcome: .candidateLimit)
        }
    }
}
