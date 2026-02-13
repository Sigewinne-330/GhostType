import XCTest
@testable import GhostType

final class InferenceCoordinatorTests: XCTestCase {
    func testStartWhileAlreadyRunning() {
        var tracker = InferenceSessionTracker()
        let sessionID = UUID()

        XCTAssertTrue(tracker.registerInferenceStart(sessionID: sessionID))
        XCTAssertFalse(tracker.registerInferenceStart(sessionID: sessionID))
        XCTAssertEqual(tracker.startedInferenceSessionIDs.count, 1)
    }

    func testSessionIDTracking() {
        var tracker = InferenceSessionTracker()
        let sessionID = UUID()

        XCTAssertTrue(tracker.registerPaste(sessionID: sessionID))
        XCTAssertFalse(tracker.registerPaste(sessionID: sessionID))

        XCTAssertTrue(tracker.registerHistoryInsert(sessionID: sessionID))
        XCTAssertFalse(tracker.registerHistoryInsert(sessionID: sessionID))

        tracker.reset()
        XCTAssertTrue(tracker.registerInferenceStart(sessionID: sessionID))
    }

    @MainActor
    func testWatchdogFiresOnTimeout() {
        let watchdog = InferenceWatchdog()
        let sessionID = UUID()
        let fired = expectation(description: "watchdog should fire")

        watchdog.arm(inferenceID: sessionID, timeout: 0.05) { firedID in
            XCTAssertEqual(firedID, sessionID)
            fired.fulfill()
        }

        wait(for: [fired], timeout: 1.0)
        watchdog.cancel()
    }

    @MainActor
    func testWatchdogCancelPreventsCallback() {
        let watchdog = InferenceWatchdog()
        let sessionID = UUID()
        let shouldNotFire = expectation(description: "watchdog should not fire after cancel")
        shouldNotFire.isInverted = true

        watchdog.arm(inferenceID: sessionID, timeout: 0.05) { _ in
            shouldNotFire.fulfill()
        }
        watchdog.cancel()

        wait(for: [shouldNotFire], timeout: 0.2)
    }
}
