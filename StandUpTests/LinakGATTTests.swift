import XCTest
@testable import StandUp

final class LinakGATTTests: XCTestCase {
    func testEncodeHeightLittleEndianTenthsOfMillimetre() {
        XCTAssertEqual(LinakGATT.encodeHeight(0), Data([0x00, 0x00]))
        XCTAssertEqual(LinakGATT.encodeHeight(1), Data([0x01, 0x00]))
        XCTAssertEqual(LinakGATT.encodeHeight(256), Data([0x00, 0x01]))
        XCTAssertEqual(LinakGATT.encodeHeight(6500), Data([0x64, 0x19]))
    }

    func testEncodeHeightClampsToUInt16Range() {
        XCTAssertEqual(LinakGATT.encodeHeight(-5), Data([0x00, 0x00]))
        XCTAssertEqual(LinakGATT.encodeHeight(0x1_FFFF), Data([0xFF, 0xFF]))
    }

    func testDecodeHeightSpeedRoundTrip() {
        let (h, s) = LinakGATT.decodeHeightSpeed(Data([0x64, 0x19, 0xE8, 0x03]))
        XCTAssertEqual(h, 6500)
        XCTAssertEqual(s, 1000)
    }

    func testDecodeHeightSpeedNegativeSpeed() {
        let (h, s) = LinakGATT.decodeHeightSpeed(Data([0x00, 0x00, 0x9C, 0xFF]))
        XCTAssertEqual(h, 0)
        XCTAssertEqual(s, -100)
    }

    func testDecodeHeightSpeedShortDataReturnsZero() {
        let (h, s) = LinakGATT.decodeHeightSpeed(Data([0x01]))
        XCTAssertEqual(h, 0)
        XCTAssertEqual(s, 0)
    }

    func testCommandBytesAreTwoBytesWithZeroTrailer() {
        XCTAssertEqual(LinakGATT.commandBytes(.moveDown), Data([70, 0]))
        XCTAssertEqual(LinakGATT.commandBytes(.moveUp), Data([71, 0]))
        XCTAssertEqual(LinakGATT.commandBytes(.wakeup), Data([254, 0]))
        XCTAssertEqual(LinakGATT.commandBytes(.stop), Data([255, 0]))
    }

    func testDpgParsePayloadRequiresLeadingOneAndTwoBytes() {
        XCTAssertNil(LinakGATT.dpgParsePayload(Data([0x00, 0xAA])))
        XCTAssertNil(LinakGATT.dpgParsePayload(Data([0x01])))
        XCTAssertEqual(LinakGATT.dpgParsePayload(Data([0x01, 0x00, 0x2A, 0x2B])), Data([0x2A, 0x2B]))
    }

    func testDpgRequestByteLayouts() {
        XCTAssertEqual(LinakGATT.dpgReadRequestBytes(.getCapabilities), Data([127, 128, 0]))
        XCTAssertEqual(LinakGATT.dpgReadRequestBytes(.baseOffset), Data([127, 129, 0]))
        XCTAssertEqual(LinakGATT.dpgWriteRequestBytes(.userID, payload: [1]), Data([127, 134, 128, 1]))
    }
}
