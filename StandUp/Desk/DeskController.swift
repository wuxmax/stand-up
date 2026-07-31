import Foundation

enum DeskConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case scanning
    case connected
    case error(String)
}

enum DeskTarget: Equatable, Sendable {
    case sit
    case stand
    case heightMm(Int)
}

struct DeskSnapshot: Equatable, Sendable {
    let heightMm: Int?
    let speedMmPerSec: Int?
    let target: DeskTarget?
    let isMoving: Bool
    let connection: DeskConnectionState

    static let idle = DeskSnapshot(
        heightMm: nil, speedMmPerSec: nil, target: nil,
        isMoving: false, connection: .disconnected
    )
}

enum DeskEvent {
    case snapshot(DeskSnapshot)
    case log(String)
}

protocol DeskController: AnyObject {
    var snapshot: DeskSnapshot { get }
    var eventHandler: ((DeskEvent) -> Void)? { get set }

    func connect() async
    func disconnect()
    func moveTo(_ target: DeskTarget) async
    func jogUp()
    func jogDown()
    func stop()
    func updateSettings(_ settings: DeskSettings)
}

extension DeskController {
    func notify(_ event: DeskEvent) {
        eventHandler?(event)
    }
    func updateSettings(_ settings: DeskSettings) {}
}

struct DeskSettings: Codable, Equatable, Sendable {
    var deskAddress: String
    var baseHeightMm: Int?
    var sitHeightMm: Int
    var standHeightMm: Int
    var moveCommandPeriod: TimeInterval

    static let minHeightMm = 0
    static let maxHeightMm = 1300

    static let `default` = DeskSettings(
        deskAddress: "",
        baseHeightMm: nil,
        sitHeightMm: 100,
        standHeightMm: 600,
        moveCommandPeriod: 0.4
    )

    func targetHeightMm(for target: DeskTarget) -> Int {
        switch target {
        case .sit:           return sitHeightMm
        case .stand:          return standHeightMm
        case .heightMm(let h): return h
        }
    }

    static func clamp(_ mm: Int) -> Int {
        min(maxHeightMm, max(minHeightMm, mm))
    }
}