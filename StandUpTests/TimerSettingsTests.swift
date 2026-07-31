import XCTest
@testable import StandUp

final class TimerSettingsTests: XCTestCase {
    func testIntervalForPosture() {
        let s = TimerSettings(sitInterval: 1800, standInterval: 300, warningLeadTime: 30)
        XCTAssertEqual(s.interval(for: .sitting), 1800)
        XCTAssertEqual(s.interval(for: .standing), 300)
    }

    func testLegacyPayloadWithoutWarningLeadTimeDecodesWithDefault() throws {
        let json = #"{"sitInterval":1800,"standInterval":300}"#
        let s = try JSONDecoder().decode(TimerSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.sitInterval, 1800)
        XCTAssertEqual(s.standInterval, 300)
        XCTAssertEqual(s.warningLeadTime, 30)
    }

    func testCodableRoundTrip() throws {
        let s = TimerSettings(sitInterval: 600, standInterval: 120, warningLeadTime: 15)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(TimerSettings.self, from: data), s)
    }
}
