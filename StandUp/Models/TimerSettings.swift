import Foundation

struct TimerSettings: Codable, Equatable, Sendable {
    var sitInterval: TimeInterval
    var standInterval: TimeInterval
    /// Seconds before the interval end at which to warn that the desk is about
    /// to auto-move. 0 disables the warning.
    var warningLeadTime: TimeInterval

    static let `default` = TimerSettings(
        sitInterval: 30 * 60,
        standInterval: 5 * 60,
        warningLeadTime: 30
    )

    func interval(for posture: Posture) -> TimeInterval {
        switch posture {
        case .sitting:  return sitInterval
        case .standing: return standInterval
        }
    }

    init(sitInterval: TimeInterval, standInterval: TimeInterval, warningLeadTime: TimeInterval) {
        self.sitInterval = sitInterval
        self.standInterval = standInterval
        self.warningLeadTime = warningLeadTime
    }

    private enum CodingKeys: String, CodingKey {
        case sitInterval, standInterval, warningLeadTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sitInterval = try c.decode(TimeInterval.self, forKey: .sitInterval)
        standInterval = try c.decode(TimeInterval.self, forKey: .standInterval)
        // Older persisted settings predate this field; default it.
        warningLeadTime = try c.decodeIfPresent(TimeInterval.self, forKey: .warningLeadTime) ?? 30
    }
}