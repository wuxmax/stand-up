import Foundation
import CoreBluetooth

/// LINAK desk controller using CoreBluetooth.
///
/// This is a native Swift port of the protocol used by rhyst/linak-controller
/// (a Python/bleak CLI). The on-air protocol is a handful of GATT characteristics
/// and is straightforward to implement with CBCentralManager.
///
/// NOTE: This implementation has not yet been validated against real hardware.
/// The GATT layout, byte packing, and the move-loop follow the Python reference,
/// but real desks sometimes need small tweaks (e.g. macOS uses a UUID rather than
/// a MAC address, and some desks require the user-id byte to be set to 1).
final class LinakDeskController: NSObject, DeskController {
    var eventHandler: ((DeskEvent) -> Void)?
    private(set) var snapshot: DeskSnapshot = .idle

    private let settings: DeskSettings
    private let central: CBCentralManager
    private var peripheral: CBPeripheral?
    private var targetPeripheralUUID: UUID?

    // Characteristics discovered during service discovery.
    private var referenceInputChar: CBCharacteristic?
    private var referenceOutputChar: CBCharacteristic?
    private var controlCommandChar: CBCharacteristic?
    private var dpgChar: CBCharacteristic?

    // Pending DPG command response handling.
    private var dpgContinuation: CheckedContinuation<Data, Error>?

    // Move loop bookkeeping.
    private var moveTask: Task<Void, Never>?
    private var lastHeightInternal: Int = 0
    private var lastSpeedInternal: Int = 0

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
        guard let uuid = UUID(uuidString: settings.deskAddress) else {
            update(connection: .error("Invalid desk address (expected a macOS BLE UUID)"))
            return
        }
        targetPeripheralUUID = uuid
        update(connection: .connecting)
        log("Connecting to \(uuid.uuidString)...")
        let peripherals = central.retrievePeripherals(withIdentifiers: [uuid])
        if let p = peripherals.first {
            peripheral = p
            p.delegate = self
            central.connect(p, options: nil)
        } else {
            update(connection: .error("Desk not found for UUID \(uuid.uuidString). Pair it first in System Settings > Bluetooth."))
        }
    }

    func disconnect() {
        moveTask?.cancel()
        moveTask = nil
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        referenceInputChar = nil
        referenceOutputChar = nil
        controlCommandChar = nil
        dpgChar = nil
        update(connection: .disconnected)
    }

    func moveTo(_ target: DeskTarget) async {
        guard peripheral != nil, referenceInputChar != nil, controlCommandChar != nil else {
            log("Cannot move: desk not connected/ready")
            return
        }
        moveTask?.cancel()
        let targetMm = settings.targetHeightMm(for: target)
        let baseMm = settings.baseHeightMm ?? 0
        let internalTarget = (targetMm - baseMm) * 10

        snapshot = DeskSnapshot(
            heightMm: lastHumanHeightMm(),
            speedMmPerSec: lastSpeedMmPerSec(),
            target: target, isMoving: true, connection: snapshot.connection
        )
        notify(.snapshot(snapshot))
        log("Moving to \(targetMm)mm (internal \(internalTarget))")

        // Wakeup + stop, then repeatedly write the target height until speed == 0.
        writeCommand(.wakeup)
        writeCommand(.stop)

        let periodNs = UInt64(max(50_000_000, Int(settings.moveCommandPeriod * 1_000_000_000)))
        moveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.writeReferenceInput(internalTarget)
                try? await Task.sleep(nanoseconds: periodNs)
                if self.lastSpeedInternal == 0 { break }
            }
            if Task.isCancelled { return }
            self.finishMove(target: target)
        }
        await moveTask?.value
    }

    // MARK: - Helpers

    private func lastHumanHeightMm() -> Int {
        let baseMm = settings.baseHeightMm ?? 0
        return (lastHeightInternal / 10) + baseMm
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
            default:
                break
            }
        }
        // Once we have everything we need, mark connected and read current height.
        if referenceInputChar != nil && referenceOutputChar != nil && controlCommandChar != nil {
            update(connection: .connected)
            if let c = referenceOutputChar {
                peripheral.readValue(for: c)
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
                isMoving: snapshot.isMoving,
                connection: snapshot.connection
            )
            snapshot = snap
            notify(.snapshot(snap))
        case LinakGATT.dpgChar:
            if let cont = dpgContinuation {
                dpgContinuation = nil
                cont.resume(returning: data)
            }
        default:
            break
        }
    }
}