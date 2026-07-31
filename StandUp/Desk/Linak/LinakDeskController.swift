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
    private var jogTask: Task<Void, Never>?
    private var lastHeightInternal: Int = 0
    private var lastSpeedInternal: Int = 0

    private var dpgSubscribed = false
    private var dpgContinuation: CheckedContinuation<Data, Error>?
    private var scanTimeoutTask: Task<Void, Never>?
    private var baseOffsetMm: Int?
    private var didStartHandshake = false

    init(settings: DeskSettings) {
        self.settings = settings
        self.central = CBCentralManager(delegate: nil, queue: .main)
        super.init()
        self.central.delegate = self
    }

    func connect() async {
        guard central.state == .poweredOn else {
            update(connection: .error("Bluetooth not powered on"))
            return
        }
        startConnection()
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
        moveTask?.cancel()
        moveTask = nil
        jogTask?.cancel()
        jogTask = nil
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        dpgContinuation?.resume(throwing: CancellationError())
        dpgContinuation = nil
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
        moveTask?.cancel()

        let targetMm = settings.targetHeightMm(for: target)
        let baseMm = resolvedBaseMm()
        let internalTarget = (targetMm - baseMm) * 10

        snapshot = DeskSnapshot(
            heightMm: lastHumanHeightMm(),
            speedMmPerSec: lastSpeedMmPerSec(),
            target: target, isMoving: true, connection: snapshot.connection
        )
        notify(.snapshot(snapshot))
        log("Moving to \(targetMm)mm (internal \(internalTarget))")

        if abs(lastHeightInternal - internalTarget) <= 5 {
            finishMove(target: target)
            return
        }

        writeCommand(.wakeup)
        writeCommand(.stop)

        let periodNs = UInt64(max(50_000_000, Int(settings.moveCommandPeriod * 1_000_000_000)))
        let maxIters = Int(60.0 / max(0.1, settings.moveCommandPeriod)) + 2
        moveTask = Task { [weak self] in
            guard let self else { return }
            var hasStartedMoving = false
            var zeroCount = 0
            var iters = 0
            while !Task.isCancelled {
                self.writeReferenceInput(internalTarget)
                try? await Task.sleep(nanoseconds: periodNs)
                let speed = self.lastSpeedInternal
                if speed != 0 {
                    hasStartedMoving = true
                    zeroCount = 0
                } else if hasStartedMoving {
                    zeroCount += 1
                }
                if hasStartedMoving && zeroCount >= 2 { break }
                if !hasStartedMoving && iters >= 3 { break }
                iters += 1
                if iters >= maxIters { break }
            }
            if Task.isCancelled { return }
            self.finishMove(target: target)
        }
        await moveTask?.value
    }

    func jogUp() {
        guard peripheral != nil, controlCommandChar != nil else { return }
        moveTask?.cancel()
        moveTask = nil
        jogTask?.cancel()
        writeCommand(.wakeup)
        log("Jog up")
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

    private func writeCommand(_ cmd: LinakGATT.Command) {
        guard let p = peripheral, let c = controlCommandChar else { return }
        p.writeValue(LinakGATT.commandBytes(cmd), for: c, type: .withResponse)
    }

    private func writeReferenceInput(_ internalHeight: Int) {
        guard let p = peripheral, let c = referenceInputChar else { return }
        p.writeValue(LinakGATT.encodeHeight(internalHeight), for: c, type: .withResponse)
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
        let raw = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            dpgContinuation = cont
            let bytes = (payload == nil)
                ? LinakGATT.dpgReadRequestBytes(cmd)
                : LinakGATT.dpgWriteRequestBytes(cmd, payload: payload!)
            p.writeValue(bytes, for: c, type: .withResponse)
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let pending = self.dpgContinuation {
                        self.dpgContinuation = nil
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
            if peripheral == nil && !isScanning { startConnection() }
        case .poweredOff:
            update(connection: .error("Bluetooth is powered off"))
        case .unauthorized:
            update(connection: .error("Bluetooth permission denied"))
        case .unsupported:
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
        log("Disconnected: \(error?.localizedDescription ?? "no error")")
        update(connection: .disconnected)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        update(connection: .error("Failed to connect: \(error?.localizedDescription ?? "unknown")"))
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
                peripheral.setNotifyValue(true, for: c)
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
                if let c = self.referenceOutputChar { self.peripheral?.readValue(for: c) }
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
            if let cont = dpgContinuation {
                dpgContinuation = nil
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