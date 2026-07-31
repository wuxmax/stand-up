import Foundation
import CoreBluetooth

/// GATT service/characteristic UUIDs and byte layout for LINAK desks.
/// Ported from https://github.com/rhyst/linak-controller (linak_controller/gatt.py).
enum LinakGATT {
    // Generic Access
    static let genericAccessService         = CBUUID(string: "00001800-0000-1000-8000-00805F9B34FB")
    static let deviceNameChar              = CBUUID(string: "00002A00-0000-1000-8000-00805F9B34FB")

    // Reference Input (write target height)
    static let referenceInputService       = CBUUID(string: "99fa0030-338a-1024-8a49-009c0215f78a")
    static let referenceInputOneChar       = CBUUID(string: "99fa0031-338a-1024-8a49-009c0215f78a")

    // Reference Output (read height + speed, notify)
    static let referenceOutputService      = CBUUID(string: "99fa0020-338a-1024-8a49-009c0215f78a")
    static let referenceOutputOneChar      = CBUUID(string: "99fa0021-338a-1024-8a49-009c0215f78a")

    // Control (wakeup / stop / up / down)
    static let controlService              = CBUUID(string: "99fa0001-338a-1024-8a49-009c0215f78a")
    static let controlCommandChar          = CBUUID(string: "99fa0002-338a-1024-8a49-009c0215f78a")
    static let controlErrorChar            = CBUUID(string: "99fa0003-338a-1024-8a49-009c0215f78a")

    // DPG (capabilities / base offset / user id)
    static let dpgService                  = CBUUID(string: "99fa0010-338a-1024-8a49-009c0215f78a")
    static let dpgChar                     = CBUUID(string: "99fa0011-338a-1024-8a49-009c0215f78a")

    enum Command: UInt8 {
        case moveDown = 70
        case moveUp   = 71
        case wakeup   = 254
        case stop     = 255
    }

    enum DPGCommand: UInt8 {
        case getCapabilities = 128
        case baseOffset      = 129
        case userID          = 134
    }

    /// Pack a two-byte little-endian height (in tenths of a mm relative to base).
    static func encodeHeight(_ internalHeight: Int) -> Data {
        let v = UInt16(max(0, min(0xFFFF, internalHeight)))
        return Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    /// Decode the 4-byte Reference Output notification: (UInt16 height, Int16 speed), little-endian.
    /// `height` is in tenths of a mm relative to base. `speed` is in hundredths of a mm/s.
    static func decodeHeightSpeed(_ data: Data) -> (heightInternal: Int, speedInternal: Int) {
        guard data.count >= 4 else { return (0, 0) }
        return data.withUnsafeBytes { raw -> (heightInternal: Int, speedInternal: Int) in
            let base = raw.baseAddress!
            let h = base.loadUnaligned(as: UInt16.self)
            let s = base.advanced(by: 2).loadUnaligned(as: Int16.self)
            return (Int(h), Int(s))
        }
    }

    static func commandBytes(_ cmd: Command) -> Data {
        Data([cmd.rawValue, 0])
    }

    /// Parse a DPG notification response. Valid iff `data[0] == 1`; payload is `data[2...]`.
    static func dpgParsePayload(_ data: Data) -> Data? {
        guard data.count >= 2, data[0] == 1 else { return nil }
        return data.subdata(in: 2..<data.count)
    }

    static func dpgReadRequestBytes(_ cmd: DPGCommand) -> Data {
        Data([127, cmd.rawValue, 0])
    }

    static func dpgWriteRequestBytes(_ cmd: DPGCommand, payload: [UInt8]) -> Data {
        Data([127, cmd.rawValue, 128] + payload)
    }
}