import Foundation
import CoreBluetooth
import Combine
import Dispatch

/// Main queue / main run-loop owned; one fresh manager and one run at a time.
/// Only the two research apps instantiate this class.
final class LabRadio: NSObject, ObservableObject, CBCentralManagerDelegate,
                      CBPeripheralDelegate, CBPeripheralManagerDelegate, StreamDelegate {
    private enum Stage {
        case idle, centralInit, scanning, confirmFixture, connecting, service, marker, markerRead, opening
        case serverInit, publishing, adding, advertising, listening, confirmIncoming
        case transfer, draining, finished
    }

    @Published private(set) var busy = false
    @Published private(set) var retiring = false
    @Published private(set) var canConnect = false
    @Published private(set) var canAccept = false
    @Published private(set) var localInvitation: String?
    @Published private(set) var status = "Idle"
    @Published private(set) var report = "not-run"

    private var stage: Stage = .idle
    private var token: UUID?
    private var deadline: UInt64?
    private var timer: DispatchSourceTimer?
    private var pendingPump: UUID?
    private var session: LabSession?
    private var invite: LabInvitation?
    private var central: CBCentralManager?
    private var server: CBPeripheralManager?
    private var retiredServer: CBPeripheralManager?
    private var serviceID: UUID?
    private var fixtureSize: LabSize = .small
    private var publishedPSM: CBL2CAPPSM?
    private var ownedService: CBMutableService?
    private var peer: CBPeripheral?
    private var remoteService: CBService?
    private var remoteMarker: CBCharacteristic?
    private var channel: CBL2CAPChannel?
    private var input: InputStream?
    private var output: OutputStream?
    private var port: FoundationStreamPort?
    private var listenerStarted: UInt64?
    private var listenerElapsed: UInt64?

    private var now: UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
    private var markerID: CBUUID { CBUUID(string: LabInvitation.markerUUID) }
    private var filter: CBUUID? { serviceID.map { CBUUID(string: $0.uuidString) } }

    private func begin(_ initial: Stage, size: LabSize) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !busy, !retiring else { return false }
        let fresh = UUID()
        token = fresh
        busy = true
        stage = initial
        fixtureSize = size
        session = nil
        report = "in-progress"
        listenerElapsed = nil
        listenerStarted = nil
        deadline = now + 15_000
        let clock = DispatchSource.makeTimerSource(queue: .main)
        clock.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        clock.setEventHandler { [weak self] in
            guard let self, self.token == fresh else { return }
            if self.checkClock(), self.stage == .transfer { self.pump() }
        }
        timer = clock
        clock.resume()
        return true
    }

    func startCentral(text: String, consent: Bool) {
        guard consent, let parsed = LabInvitation(text), begin(.centralInit, size: parsed.size) else { return }
        invite = parsed
        serviceID = parsed.serviceID
        status = "Initializing central"
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func startServer(size: LabSize, consent: Bool) {
        guard consent, begin(.serverInit, size: size) else { return }
        serviceID = LabInvitation.newServiceID()
        status = "Initializing peripheral"
        server = CBPeripheralManager(delegate: self, queue: .main,
                                     options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
    }

    func connectConfirmed(consent: Bool) {
        guard consent, checkClock(), stage == .confirmFixture,
              let token, let central, central.state == .poweredOn, let peer else { return }
        canConnect = false
        stage = .connecting
        deadline = nil
        session = LabSession(generation: token, role: .initiator, size: fixtureSize, nowMS: now)
        status = "Connecting to confirmed fixture"
        peer.delegate = self
        central.connect(peer, options: nil)
    }

    func acceptIncoming(consent: Bool) {
        guard consent, checkClock(), stage == .confirmIncoming, let channel else { return }
        canAccept = false
        stage = .transfer
        status = "Synthetic exchange"
        attach(channel)
    }

    func stop() {
        guard busy, let token else { return }
        session?.cancel(generation: token, nowMS: now)
        cleanup("cancelled")
    }

    private func checkClock() -> Bool {
        guard busy, let token else { return false }
        let instant = now
        session?.tick(generation: token, nowMS: instant)
        if stage != .draining, session?.outcome != nil {
            finishPolicy()
            return false
        }
        if let limit = deadline, instant >= limit {
            switch stage {
            case .scanning:
                central?.stopScan()
                guard peer != nil else { cleanup("no-fixture"); return false }
                stage = .confirmFixture
                canConnect = true
                deadline = instant + 30_000
                status = "One candidate; independently confirm your fixture"
            case .draining:
                cleanup("responder-drain-deadline")
                return false
            default:
                fail("setup-timeout")
                return false
            }
        }
        return busy
    }

    private func fail(_ reason: String) {
        guard let token else { return }
        session?.failIO(generation: token, nowMS: now)
        cleanup(reason)
    }

    private func disconnected() {
        guard let token else { return }
        if stage == .draining { cleanup("peer-closed-after-local-complete"); return }
        session?.disconnect(generation: token, nowMS: now)
        cleanup("disconnected")
    }

    private func finishPolicy() {
        guard let token, let outcome = session?.outcome,
              session?.takeCleanupRequest(generation: token) == true else { return }
        if outcome == .success, session?.role == .responder, stage == .transfer {
            // A local output write is not a remote acknowledgement. Leave streams
            // open briefly for peer completion; no additional I/O or retries.
            stage = .draining
            deadline = now + 2_000
            status = "Local fixture complete; bounded drain"
            return
        }
        cleanup(outcome == .success ? "completed" : outcome.rawValue)
    }

    private func cleanup(_ code: String) {
        guard let old = token else { return }
        _ = session?.takeCleanupRequest(generation: old)
        token = nil
        pendingPump = nil
        deadline = nil
        timer?.cancel()
        timer = nil
        stage = .finished
        canConnect = false
        canAccept = false
        localInvitation = nil

        if let input { input.delegate = nil; input.remove(from: .main, forMode: .common) }
        if let output { output.delegate = nil; output.remove(from: .main, forMode: .common) }
        if let port { port.close() } else { closeUnowned(channel) }
        port = nil; input = nil; output = nil; channel = nil

        let oldCentral = central
        let oldPeer = peer
        central = nil; peer = nil; remoteService = nil; remoteMarker = nil
        if let oldCentral {
            if oldCentral.state == .poweredOn {
                oldCentral.stopScan()
                if let oldPeer, oldPeer.state != .disconnected {
                    oldCentral.cancelPeripheralConnection(oldPeer)
                }
            }
            oldPeer?.delegate = nil
            oldCentral.delegate = nil
        }

        let oldServer = server
        server = nil
        if let oldServer {
            if oldServer.state == .poweredOn {
                oldServer.stopAdvertising()
                if let ownedService { oldServer.remove(ownedService) }
                if let publishedPSM { oldServer.unpublishL2CAPChannel(publishedPSM) }
            }
            // Retain one retiring manager briefly to handle a late publish/add
            // callback. Do not admit a fresh run during this bounded grace.
            retiredServer = oldServer
            retiring = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3)) { [weak self, weak oldServer] in
                guard let self, let oldServer, self.retiredServer === oldServer else { return }
                oldServer.delegate = nil
                self.retiredServer = nil
                self.retiring = false
            }
        }
        publishedPSM = nil; ownedService = nil; serviceID = nil; invite = nil
        listenerStarted = nil
        let policy = session?.report ?? "scope=synthetic-lab-only\noutcome=not-tested\nmeta-transport=not-tested\nwake-and-power=not-tested"
        report = policy + "\ndriver-terminal=" + code
            + "\nlistener-to-open-ms=" + (listenerElapsed.map { String($0) } ?? "not-observed")
            + "\ncleanup=requested-not-physically-verified"
        status = "Finished: " + code
        busy = false
    }

    private func closeUnowned(_ channel: CBL2CAPChannel?) {
        guard let channel else { return }
        channel.inputStream?.close()
        channel.outputStream?.close()
    }

    private func attach(_ opened: CBL2CAPChannel) {
        guard let i = opened.inputStream, let o = opened.outputStream else { fail("missing-streams"); return }
        input = i; output = o
        port = FoundationStreamPort(input: i, output: o)
        i.delegate = self; o.delegate = self
        i.schedule(in: .main, forMode: .common)
        o.schedule(in: .main, forMode: .common)
        i.open(); o.open()
        queuePump()
    }

    private func queuePump() {
        guard stage == .transfer, let token, pendingPump == nil else { return }
        pendingPump = token
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingPump == token, self.token == token else { return }
            self.pendingPump = nil
            self.pump()
        }
    }

    private func pump() {
        guard checkClock(), stage == .transfer, let token, let port, let before = session else { return }
        session?.pump(generation: token, nowMS: now, port: port)
        if session?.outcome != nil { finishPolicy(); return }
        // Yield between operations, and never spin on zero progress.
        if session?.sent != before.sent || session?.received != before.received { queuePump() }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard busy, aStream === input || aStream === output else { return }
        if eventCode.contains(.errorOccurred) { fail("stream-error"); return }
        if eventCode.contains(.endEncountered) {
            if stage == .transfer { pump() }
            if busy { disconnected() }
            return
        }
        if eventCode.contains(.hasBytesAvailable) || eventCode.contains(.hasSpaceAvailable)
            || eventCode.contains(.openCompleted) { queuePump() }
    }

    // MARK: Central — exact run invitation, explicit second consent

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        guard central === manager, checkClock() else { return }
        switch manager.state {
        case .poweredOn:
            guard stage == .centralInit, let filter else { return }
            stage = .scanning
            deadline = min(deadline ?? now, now + 5_000)
            status = "Scanning for exact lab invitation"
            manager.scanForPeripherals(withServices: [filter],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .unknown:
            if stage != .centralInit { fail("radio-state-lost") }
        default: fail("radio-unavailable")
        }
    }

    func centralManager(_ manager: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard central === manager, checkClock(), stage == .scanning, let filter else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        guard services.contains(filter) || overflow.contains(filter) else { return }
        if let peer, peer.identifier != peripheral.identifier { fail("ambiguous-fixture"); return }
        peer = peripheral
    }

    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === manager, checkClock(), peer === peripheral,
              stage == .connecting, let token, let filter else { return }
        session?.linkConnected(generation: token, nowMS: now)
        guard session?.phase == .awaitingChannel else { finishPolicy(); return }
        stage = .service
        status = "Verifying lab service and marker"
        peripheral.discoverServices([filter])
    }

    func centralManager(_ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === manager, peer === peripheral, busy else { return }
        fail("connect-failed")
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === manager, peer === peripheral, busy else { return }
        disconnected()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peer === peripheral, checkClock(), stage == .service, let filter else { return }
        let matches = (peripheral.services ?? []).filter { $0.uuid == filter }
        guard error == nil, matches.count == 1, let service = matches.first else { fail("lab-service-mismatch"); return }
        remoteService = service
        stage = .marker
        peripheral.discoverCharacteristics([markerID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peer === peripheral, checkClock(), stage == .marker, remoteService === service else { return }
        let matches = (service.characteristics ?? []).filter { $0.uuid == markerID }
        guard error == nil, matches.count == 1, let marker = matches.first, marker.properties.contains(.read) else {
            fail("lab-marker-missing"); return
        }
        remoteMarker = marker
        stage = .markerRead
        peripheral.readValue(for: marker)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peer === peripheral, checkClock(), stage == .markerRead, remoteMarker === characteristic,
              let invite else { return }
        guard error == nil, invite.matchesMarker(characteristic.value) else { fail("lab-marker-mismatch"); return }
        stage = .opening
        status = "Opening verified lab PSM"
        peripheral.openL2CAPChannel(invite.psm)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen opened: CBL2CAPChannel?, error: Error?) {
        if let opened, channel === opened { return }
        guard peer === peripheral, checkClock(), stage == .opening, let token, let invite else {
            closeUnowned(opened); return
        }
        guard error == nil, let opened, opened.psm == invite.psm else {
            closeUnowned(opened); fail("channel-open-failed"); return
        }
        session?.channelOpened(generation: token, nowMS: now)
        guard session?.phase == .transferring else { closeUnowned(opened); finishPolicy(); return }
        channel = opened
        stage = .transfer
        status = "Synthetic exchange"
        attach(opened)
    }

    // MARK: Peripheral — fresh lab service and dynamically assigned encrypted PSM

    func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager) {
        guard server === manager, checkClock() else { return }
        switch manager.state {
        case .poweredOn:
            guard stage == .serverInit else { return }
            stage = .publishing
            status = "Publishing encrypted listener"
            manager.publishL2CAPChannel(withEncryption: true)
        case .unknown:
            if stage != .serverInit { fail("radio-state-lost") }
        default: fail("radio-unavailable")
        }
    }

    func peripheralManager(_ manager: CBPeripheralManager, didPublishL2CAPChannel psm: CBL2CAPPSM, error: Error?) {
        guard server === manager, checkClock(), stage == .publishing, let serviceID else {
            if retiredServer === manager, error == nil, psm != 0, manager.state == .poweredOn {
                manager.unpublishL2CAPChannel(psm)
            }
            return
        }
        guard error == nil, let local = LabInvitation(serviceID: serviceID, psm: psm, size: fixtureSize) else {
            if error == nil, psm != 0, manager.state == .poweredOn { manager.unpublishL2CAPChannel(psm) }
            fail("publish-failed"); return
        }
        invite = local
        publishedPSM = psm
        let service = CBMutableService(type: CBUUID(string: serviceID.uuidString), primary: true)
        service.characteristics = [CBMutableCharacteristic(type: markerID, properties: [.read],
                                                            value: local.marker, permissions: [.readable])]
        ownedService = service
        stage = .adding
        manager.add(service)
    }

    func peripheralManager(_ manager: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard server === manager, checkClock(), stage == .adding, ownedService === service,
              let filter else {
            if retiredServer === manager, error == nil, manager.state == .poweredOn,
               let owned = service as? CBMutableService { manager.remove(owned) }
            return
        }
        guard error == nil else { fail("service-add-failed"); return }
        stage = .advertising
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [filter]])
    }

    func peripheralManagerDidStartAdvertising(_ manager: CBPeripheralManager, error: Error?) {
        guard server === manager, checkClock(), stage == .advertising, let invite else {
            if retiredServer === manager, manager.state == .poweredOn { manager.stopAdvertising() }
            return
        }
        guard error == nil else { fail("advertising-failed"); return }
        stage = .listening
        listenerStarted = now
        deadline = now + 90_000
        localInvitation = invite.localText
        status = "Listening for one owned iPhone"
    }

    func peripheralManager(_ manager: CBPeripheralManager, didOpen opened: CBL2CAPChannel?, error: Error?) {
        if let opened, channel === opened { return }
        guard server === manager, checkClock() else { closeUnowned(opened); return }
        guard stage == .listening, error == nil, let opened, let token,
              opened.psm == publishedPSM else {
            closeUnowned(opened); fail("unexpected-incoming-channel"); return
        }
        manager.stopAdvertising()
        channel = opened
        let instant = now
        if let started = listenerStarted, instant >= started { listenerElapsed = instant - started }
        session = LabSession(generation: token, role: .responder, size: fixtureSize, nowMS: instant)
        session?.responderChannelOpened(generation: token, nowMS: instant)
        stage = .confirmIncoming
        deadline = nil
        localInvitation = nil
        canAccept = true
        status = "Confirm the owned iPhone just connected; no I/O yet"
    }
}
