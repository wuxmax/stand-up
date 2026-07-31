import XCTest
@testable import StandUp

final class PostureTimerTests: XCTestCase {
    func testInitialState() {
        let t = PostureTimer(settings: TimerSettings(sitInterval: 1800, standInterval: 300, warningLeadTime: 0))
        XCTAssertEqual(t.posture, .sitting)
        XCTAssertEqual(t.runState, .idle)
        XCTAssertEqual(t.remaining, 1800)
    }

    func testStartPauseResume() {
        let t = PostureTimer(settings: TimerSettings(sitInterval: 60, standInterval: 30, warningLeadTime: 0))
        t.start()
        XCTAssertEqual(t.runState, .running)
        t.pause()
        XCTAssertEqual(t.runState, .paused)
        t.start()
        XCTAssertEqual(t.runState, .running)
        t.pause()
    }

    func testResetRestoresInitialState() {
        let t = PostureTimer(settings: TimerSettings(sitInterval: 60, standInterval: 30, warningLeadTime: 0))
        t.start()
        t.switchMode()
        t.reset()
        XCTAssertEqual(t.runState, .idle)
        XCTAssertEqual(t.posture, .sitting)
        XCTAssertEqual(t.remaining, 60)
    }

    func testSwitchModeFlipsPostureAndReseedsRemaining() {
        let t = PostureTimer(settings: TimerSettings(sitInterval: 60, standInterval: 30, warningLeadTime: 0))
        t.switchMode()
        XCTAssertEqual(t.posture, .standing)
        XCTAssertEqual(t.remaining, 30)
        t.switchMode()
        XCTAssertEqual(t.posture, .sitting)
        XCTAssertEqual(t.remaining, 60)
    }

    func testUpdateSettingsReseedsRemainingWhenNotRunning() {
        let t = PostureTimer(settings: TimerSettings(sitInterval: 60, standInterval: 30, warningLeadTime: 0))
        t.updateSettings(TimerSettings(sitInterval: 120, standInterval: 45, warningLeadTime: 0))
        XCTAssertEqual(t.remaining, 120)
    }

    func testCompletionFlipsPostureAndPostsNotification() {
        let t = PostureTimer(settings: TimerSettings(sitInterval: 1, standInterval: 5, warningLeadTime: 0))
        let exp = expectation(forNotification: PostureTimer.Static.tickCompleteNotification, object: nil)
        t.start()
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(t.posture, .standing)
        XCTAssertEqual(t.remaining, 5)
        XCTAssertEqual(t.runState, .running)
        t.pause()
    }

    func testWarningFiresOnceBeforeCompletion() {
        let t = PostureTimer(settings: TimerSettings(sitInterval: 3, standInterval: 60, warningLeadTime: 2))
        let exp = expectation(forNotification: PostureTimer.Static.warningNotification, object: nil)
        exp.assertForOverFulfill = true
        t.start()
        wait(for: [exp], timeout: 2.5)
        XCTAssertEqual(t.posture, .sitting)
        XCTAssertEqual(t.runState, .running)
        t.pause()
    }

    func testPausedTimerDoesNotComplete() {
        let t = PostureTimer(settings: TimerSettings(sitInterval: 1, standInterval: 5, warningLeadTime: 0))
        let exp = expectation(forNotification: PostureTimer.Static.tickCompleteNotification, object: nil)
        exp.isInverted = true
        t.start()
        t.pause()
        wait(for: [exp], timeout: 1.5)
        XCTAssertEqual(t.posture, .sitting)
        XCTAssertEqual(t.runState, .paused)
    }
}
