import Foundation

enum DeskConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
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
}

extension DeskController {
    func notify(_ event: DeskEvent) {
        eventHandler?(event)
    }
}

enum DeskFactory {
    static func make(mode: DeskControlMode, settings: DeskSettings) -> DeskController {
        switch mode {
        case .mock:
            return MockDeskController()
        case .linak:
            return LinakDeskController(settings: settings)
        }
    }
}

enum DeskControlMode: String, Codable, CaseIterable {
    case mock
    case linak
}

struct DeskSettings: Codable, Equatable, Sendable {
    var controlMode: DeskControlMode
    var deskAddress: String
    var baseHeightMm: Int?
    var sitHeightMm: Int
    var standHeightMm: Int
    var moveCommandPeriod: TimeInterval

    static let `default` = DeskSettings(
        controlMode: .mock,
        deskAddress: "",
        baseHeightMm: nil,
        sitHeightMm: 700,
        standHeightMm: 1100,
        moveCommandPeriod: 0.4
    )

    func targetHeightMm(for target: DeskTarget) -> Int {
        switch target {
        case .sit:           return sitHeightMm
        case .stand:          return standHeightMm
        case .heightMm(let h): return h
        }
    }
}