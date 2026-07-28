import Foundation

struct TimerSettings: Codable, Equatable, Sendable {
    var sitInterval: TimeInterval
    var standInterval: TimeInterval

    static let `default` = TimerSettings(
        sitInterval: 30 * 60,
        standInterval: 5 * 60
    )

    func interval(for posture: Posture) -> TimeInterval {
        switch posture {
        case .sitting:  return sitInterval
        case .standing: return standInterval
        }
    }
}