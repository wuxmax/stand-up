import XCTest
@testable import StandUp

final class DeskSettingsTests: XCTestCase {
    func testClampBounds() {
        XCTAssertEqual(DeskSettings.clamp(-10), DeskSettings.minHeightMm)
        XCTAssertEqual(DeskSettings.clamp(0), DeskSettings.minHeightMm)
        XCTAssertEqual(DeskSettings.clamp(700), 700)
        XCTAssertEqual(DeskSettings.clamp(2000), DeskSettings.maxHeightMm)
    }

    func testTargetHeightResolution() {
        let s = DeskSettings(
            deskAddress: "", baseHeightMm: nil,
            sitHeightMm: 100, standHeightMm: 600, moveCommandPeriod: 0.4
        )
        XCTAssertEqual(s.targetHeightMm(for: .sit), 100)
        XCTAssertEqual(s.targetHeightMm(for: .stand), 600)
        XCTAssertEqual(s.targetHeightMm(for: .heightMm(450)), 450)
    }

    func testCodableRoundTrip() throws {
        let s = DeskSettings(
            deskAddress: "E2E1F7A0-0000-1111-2222-333344445555", baseHeightMm: 620,
            sitHeightMm: 720, standHeightMm: 1100, moveCommandPeriod: 0.4
        )
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(DeskSettings.self, from: data), s)
    }
}
