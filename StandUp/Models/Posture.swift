import Foundation

enum Posture: String, Codable, CaseIterable, Sendable {
    case sitting
    case standing

    var label: String {
        switch self {
        case .sitting:  return "Sitting"
        case .standing: return "Standing"
        }
    }

    var opposite: Posture {
        switch self {
        case .sitting:  return .standing
        case .standing: return .sitting
        }
    }

    var symbolName: String {
        switch self {
        case .sitting:  return "figure.seated.side"
        case .standing: return "figure.stand"
        }
    }
}

extension Posture {
    var destinationName: String { "StandUp.posture." + rawValue }
}