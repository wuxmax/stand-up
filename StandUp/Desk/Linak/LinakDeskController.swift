import AppKit
import Foundation
import CoreBluetooth

final class LinakDeskController: NSObject, DeskController {
    var eventHandler: ((DeskEvent) -> Void)?
    private(set) var snapshot: DeskSnapshot = .idle

    private var settings: DeskSettings
    private let central: CBCentralManager
    private var peripheral: CBPeripheral?
    private var isScanning = false

    private var referenceInputChar: CBCharacteristic?
    private var referenceOutputChar: CBCharacteristic?
    private var controlCommandChar: CBCharacteristic?
    private var dpgChar: CBCharacteristic?
    private var controlErrorChar: CBCharacteristic?

    private var moveTask: Task<Void, Never>?
    private var moveTargetInternal: Int = 0
    private var moveTarget: DeskTarget?
    private var jogTask: Task<Void, Never>?
    private var lastHeightInternal: Int = 0
    private var lastSpeedInternal: Int = 0
    private var lastHeightUpdateAt: Date?
    private var refOutputReadSupported = false

    private var dpgSubscribed = false
    private let dpgBox = DPGContinuationBox()
    private var scanTimeoutTask: Task<Void, Never>?
    private var baseOffsetMm: Int?
    private var didStartHandshake = false

    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var wakeObserver: NSObjectProtocol?
    private var isTearingDown = false

    private let initialReconnectDelay: TimeInterval = 2
    private let maxReconnectDelay: TimeInterval = 30

    init(settings: DeskSettings) {
        self.settings = settings
        self.central = CBCentralManager(delegate: nil, queue: .main)
        super.init()
        self.central.delegate = self
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            assert(Thread.isMainThread)
            self?.handleSystemWake()
        }
    }

    deinit {
        reconnectTask?.cancel()
        reconnectTask = nil
        if let o = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            wakeObserver = nil
        }
    }

    func connect() async {
        guard central.state == .poweredOn else {
            update(connection: .error("Bluetooth not powered on"))
            return
        }
        reconnectIfNeeded()
    }

    private func startConnection() {
        if !settings.deskAddress.isEmpty,
           let uuid = UUID(uuidString: settings.deskAddress) {
            update(connection: .connecting)
            log("Connecting to known desk \(uuid.uuidString)...")
            let peripherals = central.retrievePeripherals(withIdentifiers: [uuid])
            if let p = peripherals.first {
                peripheral = p
                p.delegate = self
                central.connect(p, options: nil)
            } else {
                update(connection: .error("Desk not found. Re-pair in System Settings > Bluetooth."))
            }
        } else {
            update(connection: .scanning)
            let linakServices = [LinakGATT.referenceOutputService, LinakGATT.dpgService]
            let connected = central.retrieveConnectedPeripherals(withServices: linakServices)
            if let p = connected.first {
                peripheral = p
                p.delegate = self
                log("Found already-connected desk: \(p.identifier.uuidString)")
                update(connection: .connecting)
                central.connect(p, options: nil)
                return
            }
            log("Scanning for LINAK desk...")
            isScanning = true
            central.scanForPeripherals(withServices: nil, options: nil)
            scanTimeoutTask?.cancel()
            scanTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                if self.isScanning {
                    self.central.stopScan()
                    self.isScanning = false
                    self.log("Scan timed out")
                    self.update(connection: .error("Desk not found. Ensure it is powered on and nearby."))
                }
            }
        }
    }

    func disconnect() {
        isTearingDown = true
        moveTask?.cancel()
        moveTask = nil
        jogTask?.cancel()
        jogTask = nil
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        dpgBox.continuation?.resume(throwing: CancellationError())
        dpgBox.continuation = nil
        dpgSubscribed = false
        if isScanning { central.stopScan(); isScanning = false }
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        referenceInputChar = nil
        referenceOutputChar = nil
        controlCommandChar = nil
        dpgChar = nil
        controlErrorChar = nil
        baseOffsetMm = nil
        didStartHandshake = false
        lastHeightUpdateAt = nil
        refOutputReadSupported = false
        if let o = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            wakeObserver = nil
        }
        update(connection: .disconnected)
    }

    func updateSettings(_ settings: DeskSettings) {
        self.settings = settings
    }

    func moveTo(_ target: DeskTarget) async {
        guard peripheral != nil, referenceInputChar != nil, controlCommandChar != nil else {
            log("Cannot move: desk not connected/ready")
            return
        }
        jogTask?.cancel()
        jogTask = nil

        let targetMm = settings.targetHeightMm(for: target)
        let internalTarget = (targetMm - resolvedBaseMm()) * 10
        moveTargetInternal = internalTarget
        moveTarget = target

        snapshot = DeskSnapshot(
            heightMm: lastHumanHeightMm(),
            speedMmPerSec: lastSpeedMmPerSec(),
            target: target, isMoving: true, connection: snapshot.connection
        )
        notify(.snapshot(snapshot))

        if abs(lastHeightInternal - internalTarget) <= 5, isHeightDataFresh {
            moveTask?.cancel()
            moveTask = nil
            writeCommand(.stop)
            finishMove(target: target)
            return
        }

        if moveTask != nil {
            log("Retargeting in-flight move to \(targetMm)mm (internal \(internalTarget))")
            return
        }

        log("Moving to \(targetMm)mm (internal \(internalTarget))")
        writeCommand(.wakeup)
        writeCommand(.stop)

        let periodNs = UInt64(max(50_000_000, Int(settings.moveCommandPeriod * 1_000_000_000)))
        let maxDuration: TimeInterval = 60
        let task = Task { [weak self] in
            guard let self else { return }
            var trackedTarget = self.moveTargetInternal
            var lastLoggedHeight = Int.min
            var consecutiveArrived = 0
            var noProgressCount = 0
            var kickAfter = 3
            var silenceCount = 0
            var withholdingForReversal = false
            let startedAt = Date()
            while !Task.isCancelled {
                let currentTarget = self.moveTargetInternal
                if currentTarget != trackedTarget {
                    trackedTarget = currentTarget
                    consecutiveArrived = 0
                    noProgressCount = 0
                    kickAfter = 3
                }
                let reversalPending = (self.lastSpeedInternal > 0 && currentTarget < self.lastHeightInternal)
                    || (self.lastSpeedInternal < 0 && currentTarget > self.lastHeightInternal)
                if reversalPending {
                    if !withholdingForReversal {
                        withholdingForReversal = true
                        self.log("Reversal requested — decelerating before re-targeting")
                    }
                } else {
                    if withholdingForReversal {
                        withholdingForReversal = false
                        self.log("Desk at rest — re-arming for new target")
                        self.writeCommand(.wakeup)
                        self.writeCommand(.stop)
                    }
                    self.writeReferenceInput(currentTarget)
                }
                try? await Task.sleep(nanoseconds: periodNs)
                guard let (height, speed) = self.pollHeightSpeed() else {
                    silenceCount += 1
                    if silenceCount == 3 {
                        self.log("Desk not reporting height — re-arming (wakeup+stop)")
                        self.writeCommand(.wakeup)
                        self.writeCommand(.stop)
                    }
                    if Date().timeIntervalSince(startedAt) > maxDuration { break }
                    continue
                }
                silenceCount = 0
                if height != lastLoggedHeight {
                    lastLoggedHeight = height
                    self.log("Height: \((height / 10) + self.resolvedBaseMm())mm Speed: \(speed / 100)mm/s")
                }
                let atTarget = abs(height - currentTarget) <= 5
                if speed == 0 && atTarget {
                    consecutiveArrived += 1
                    if consecutiveArrived >= 2 { break }
                } else {
                    consecutiveArrived = 0
                }
                if speed == 0 && !atTarget && !withholdingForReversal {
                    noProgressCount += 1
                    if noProgressCount >= kickAfter {
                        noProgressCount = 0
                        kickAfter = min(kickAfter * 2, 12)
                        self.controlKick(toward: currentTarget, from: height)
                    }
                } else {
                    noProgressCount = 0
                    kickAfter = 3
                }
                if Date().timeIntervalSince(startedAt) > maxDuration { break }
            }
            if Task.isCancelled { return }
            self.moveTask = nil
            self.finishMove(target: self.moveTarget ?? target)
        }
        moveTask = task
        await task.value
    }

    func jogUp() {
        guard peripheral != nil, controlCommandChar != nil else { return }
        moveTask?.cancel()
        moveTask = nil
        jogTask?.cancel()
        writeCommand(.wakeup)
        log("Jog up")
        clearMoveTarget()
        jogTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.writeCommand(.moveUp)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    func jogDown() {
        guard peripheral != nil, controlCommandChar != nil else { return }
        moveTask?.cancel()
        moveTask = nil
        jogTask?.cancel()
        writeCommand(.wakeup)
        log("Jog down")
        clearMoveTarget()
        jogTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.writeCommand(.moveDown)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    func stop() {
        guard peripheral != nil else { return }
        jogTask?.cancel()
        jogTask = nil
        moveTask?.cancel()
        moveTask = nil
        writeCommand(.stop)
        log("Stop")
        snapshot = DeskSnapshot(
            heightMm: snapshot.heightMm,
            speedMmPerSec: 0,
            target: nil, isMoving: false, connection: snapshot.connection
        )
        notify(.snapshot(snapshot))
    }

    // MARK: - Helpers

    private func resolvedBaseMm() -> Int {
        if let b = baseOffsetMm { return b }
        return settings.baseHeightMm ?? 0
    }

    private func lastHumanHeightMm() -> Int {
        (lastHeightInternal / 10) + resolvedBaseMm()
    }

    private func lastSpeedMmPerSec() -> Int {
        lastSpeedInternal / 100
    }

    private func finishMove(target: DeskTarget) {
        snapshot = DeskSnapshot(
            heightMm: lastHumanHeightMm(),
            speedMmPerSec: 0,
            target: target, isMoving: false, connection: snapshot.connection
        )
        notify(.snapshot(snapshot))
        log("Reached \(lastHumanHeightMm())mm")
    }

    private func clearMoveTarget() {
        moveTarget = nil
        snapshot = DeskSnapshot(
            heightMm: snapshot.heightMm,
            speedMmPerSec: snapshot.speedMmPerSec,
            target: nil, isMoving: snapshot.isMoving, connection: snapshot.connection
        )
        notify(.snapshot(snapshot))
    }

    private func writeCommand(_ cmd: LinakGATT.Command) {
        guard let p = peripheral, let c = controlCommandChar else { return }
        p.writeValue(LinakGATT.commandBytes(cmd), for: c, type: .withResponse)
    }

    private func writeReferenceInput(_ internalHeight: Int) {
        guard let p = peripheral, let c = referenceInputChar else { return }
        p.writeValue(LinakGATT.encodeHeight(internalHeight), for: c, type: .withResponse)
    }

    private var isHeightDataFresh: Bool {
        guard let t = lastHeightUpdateAt else { return false }
        return Date().timeIntervalSince(t) < 2.0
    }

    private func pollHeightSpeed() -> (height: Int, speed: Int)? {
        if refOutputReadSupported, let c = referenceOutputChar {
            peripheral?.readValue(for: c)
        }
        guard isHeightDataFresh else { return nil }
        return (lastHeightInternal, lastSpeedInternal)
    }

    private func controlKick(toward target: Int, from height: Int) {
        log("Desk stalled \(abs(target - height) / 10)mm from target — control kick")
        writeCommand(.wakeup)
        writeCommand(target > height ? .moveUp : .moveDown)
    }

    // MARK: - DPG handshake (port of linak_controller/dpg.py initialise)

    private func ensureDpgSubscribed() {
        guard let p = peripheral, let c = dpgChar, !dpgSubscribed else { return }
        p.setNotifyValue(true, for: c)
        dpgSubscribed = true
    }

    private func dpgRequest(_ cmd: LinakGATT.DPGCommand, payload: [UInt8]?) async throws -> Data? {
        guard let p = peripheral, let c = dpgChar else { return nil }
        ensureDpgSubscribed()
        let box = dpgBox
        let raw = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            box.continuation = cont
            let bytes = (payload == nil)
                ? LinakGATT.dpgReadRequestBytes(cmd)
                : LinakGATT.dpgWriteRequestBytes(cmd, payload: payload!)
            p.writeValue(bytes, for: c, type: .withResponse)
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                DispatchQueue.main.async {
                    if let pending = box.continuation {
                        box.continuation = nil
                        pending.resume(throwing: NSError(domain: "LinakDeskController", code: -1,
                                                         userInfo: [NSLocalizedDescriptionKey: "DPG response timeout"]))
                    }
                }
            }
        }
        return LinakGATT.dpgParsePayload(raw)
    }

    private func performDPGHandshake() async {
        if let caps = try? await dpgRequest(.getCapabilities, payload: nil) {
            log("DPG capabilities: \(caps.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }
        if let userID = try? await dpgRequest(.userID, payload: nil), !userID.isEmpty {
            log("DPG user-id: \(userID.map { String(format: "%02x", $0) }.joined(separator: " "))")
            if userID[0] != 1 {
                var newID = userID
                newID[0] = 1
                _ = try? await dpgRequest(.userID, payload: Array(newID))
                log("DPG user-id set to 1")
            }
        }
        if baseOffsetMm == nil {
            if let resp = try? await dpgRequest(.baseOffset, payload: nil), resp.count >= 3 {
                let lo = UInt16(resp[1])
                let hi = UInt16(resp[2]) << 8
                let offsetMm = Int((lo | hi) / 10)
                baseOffsetMm = offsetMm
                log("DPG base offset: \(offsetMm)mm")
            }
        }
    }

    private func resetLinkState() {
        moveTask?.cancel()
        moveTask = nil
        jogTask?.cancel()
        jogTask = nil
        dpgBox.continuation?.resume(throwing: CancellationError())
        dpgBox.continuation = nil
        dpgSubscribed = false
        referenceInputChar = nil
        referenceOutputChar = nil
        controlCommandChar = nil
        dpgChar = nil
        controlErrorChar = nil
        didStartHandshake = false
        lastHeightUpdateAt = nil
        refOutputReadSupported = false
    }

    private func reconnectIfNeeded() {
        guard !isTearingDown, central.state == .poweredOn else { return }
        if isScanning { return }
        switch snapshot.connection {
        case .connected, .connecting, .scanning:
            return
        default:
            break
        }
        reconnectAttempts = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        if peripheral != nil {
            update(connection: .connecting)
            central.connect(peripheral!, options: nil)
        } else {
            startConnection()
        }
    }

    private func scheduleReconnect() {
        guard !isTearingDown else { return }
        reconnectTask?.cancel()
        let attempt = reconnectAttempts
        let delay = min(maxReconnectDelay, initialReconnectDelay * pow(2.0, Double(attempt)))
        reconnectAttempts += 1
        log("Reconnecting in \(Int(delay))s (attempt \(attempt + 1))...")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await MainActor.run { self.reconnectIfNeeded() }
        }
    }

    private func handleSystemWake() {
        switch snapshot.connection {
        case .connected, .connecting, .scanning:
            return
        default:
            break
        }
        log("System woke from sleep — re-establishing desk link")
        resetLinkState()
        peripheral = nil
        update(connection: .disconnected)
        reconnectIfNeeded()
    }

    private func update(connection: DeskConnectionState) {
        snapshot = DeskSnapshot(
            heightMm: snapshot.heightMm,
            speedMmPerSec: snapshot.speedMmPerSec,
            target: snapshot.target,
            isMoving: snapshot.isMoving,
            connection: connection
        )
        notify(.snapshot(snapshot))
    }

    private func log(_ message: String) {
        notify(.log("[LINAK] " + message))
    }
}

extension LinakDeskController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("Bluetooth powered on")
            reconnectIfNeeded()
        case .poweredOff:
            resetLinkState()
            update(connection: .error("Bluetooth is powered off"))
        case .unauthorized:
            resetLinkState()
            update(connection: .error("Bluetooth permission denied"))
        case .unsupported:
            resetLinkState()
            update(connection: .error("Bluetooth unsupported on this Mac"))
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (peripheral.name ?? "").lowercased()
        let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let isLinak = name.contains("desk")
            || advertisedServices.contains(LinakGATT.referenceOutputService)
            || advertisedServices.contains(LinakGATT.referenceInputService)
            || advertisedServices.contains(LinakGATT.dpgService)
            || advertisedServices.contains(LinakGATT.controlService)
        guard isLinak else { return }
        central.stopScan()
        isScanning = false
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        self.peripheral = peripheral
        peripheral.delegate = self
        log("Discovered desk: \(peripheral.identifier.uuidString) (\(peripheral.name ?? "?"))")
        update(connection: .connecting)
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected, discovering services...")
        peripheral.discoverServices([
            LinakGATT.referenceInputService,
            LinakGATT.referenceOutputService,
            LinakGATT.controlService,
            LinakGATT.dpgService,
        ])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard !isTearingDown else { return }
        guard peripheral === self.peripheral else { return }
        log("Disconnected: \(error?.localizedDescription ?? "no error")")
        resetLinkState()
        update(connection: .disconnected)
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard !isTearingDown else { return }
        guard peripheral === self.peripheral else { return }
        log("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        resetLinkState()
        update(connection: .error("Failed to connect: \(error?.localizedDescription ?? "unknown")"))
        scheduleReconnect()
    }
}

extension LinakDeskController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("Discover services error: \(error)"); return }
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { log("Discover characteristics error: \(error)"); return }
        guard let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case LinakGATT.referenceInputOneChar:
                referenceInputChar = c
            case LinakGATT.referenceOutputOneChar:
                referenceOutputChar = c
                refOutputReadSupported = c.properties.contains(.read)
                if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: c)
                }
            case LinakGATT.controlCommandChar:
                controlCommandChar = c
            case LinakGATT.dpgChar:
                dpgChar = c
            case LinakGATT.controlErrorChar:
                controlErrorChar = c
                peripheral.setNotifyValue(true, for: c)
            default:
                break
            }
        }
        if !didStartHandshake,
           referenceInputChar != nil && referenceOutputChar != nil && controlCommandChar != nil && dpgChar != nil {
            didStartHandshake = true
            Task { [weak self] in
                guard let self else { return }
                await self.performDPGHandshake()
                if let c = self.referenceOutputChar, self.refOutputReadSupported { self.peripheral?.readValue(for: c) }
                self.reconnectAttempts = 0
                self.update(connection: .connected)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case LinakGATT.referenceOutputOneChar:
            let (h, s) = LinakGATT.decodeHeightSpeed(data)
            lastHeightInternal = h
            lastSpeedInternal = s
            lastHeightUpdateAt = Date()
            let snap = DeskSnapshot(
                heightMm: lastHumanHeightMm(),
                speedMmPerSec: lastSpeedMmPerSec(),
                target: snapshot.target,
                isMoving: lastSpeedInternal != 0,
                connection: snapshot.connection
            )
            snapshot = snap
            notify(.snapshot(snap))
        case LinakGATT.dpgChar:
            if let cont = dpgBox.continuation {
                dpgBox.continuation = nil
                cont.resume(returning: data)
            } else {
                log("DPG notification (unsolicited): \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
            }
        case LinakGATT.controlErrorChar:
            log("Control error: \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
        default:
            break
        }
    }
}

private final class DPGContinuationBox: @unchecked Sendable {
    var continuation: CheckedContinuation<Data, Error>?
}