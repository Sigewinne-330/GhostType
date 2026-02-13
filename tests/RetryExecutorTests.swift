import XCTest
@testable import GhostType

final class RetryExecutorTests: XCTestCase {
    private struct FixedRetryPolicy: RetryPolicy {
        let maxAttempts: Int
        let delayNS: UInt64

        func delayNanoseconds(forAttempt _: Int) -> UInt64 {
            delayNS
        }
    }

    private enum RetryTestError: Error, Equatable {
        case transient
        case fatal
    }

    func testRetryExecutorRetriesThenSucceeds() async throws {
        var attempts = 0

        let value = try await RetryExecutor.run(
            policy: FixedRetryPolicy(maxAttempts: 3, delayNS: 0),
            shouldRetry: { ($0 as? RetryTestError) == .transient }
        ) {
            attempts += 1
            if attempts < 3 {
                throw RetryTestError.transient
            }
            return "ok"
        }

        XCTAssertEqual(value, "ok")
        XCTAssertEqual(attempts, 3)
    }

    func testRetryExecutorStopsOnNonRetryableError() async {
        var attempts = 0

        do {
            _ = try await RetryExecutor.run(
                policy: FixedRetryPolicy(maxAttempts: 5, delayNS: 0),
                shouldRetry: { _ in false }
            ) {
                attempts += 1
                throw RetryTestError.fatal
            }
            XCTFail("Expected error to be thrown.")
        } catch let error as RetryTestError {
            XCTAssertEqual(error, .fatal)
            XCTAssertEqual(attempts, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRetryExecutorThrowsAfterMaxAttempts() async {
        var attempts = 0

        do {
            _ = try await RetryExecutor.run(
                policy: FixedRetryPolicy(maxAttempts: 4, delayNS: 0),
                shouldRetry: { ($0 as? RetryTestError) == .transient }
            ) {
                attempts += 1
                throw RetryTestError.transient
            }
            XCTFail("Expected error to be thrown.")
        } catch let error as RetryTestError {
            XCTAssertEqual(error, .transient)
            XCTAssertEqual(attempts, 4)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExponentialBackoffRetryPolicyWithoutJitterIsDeterministic() {
        let policy = ExponentialBackoffRetryPolicy(
            maxAttempts: 5,
            baseDelayMS: 100,
            maxDelayMS: 500,
            jitterRangeMS: 0...0
        )

        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 1), 100_000_000)
        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 2), 200_000_000)
        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 3), 400_000_000)
        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 4), 500_000_000)
        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 5), 500_000_000)
    }

    func testExponentialBackoffRetryPolicyAppliesJitterWithinBounds() {
        let policy = ExponentialBackoffRetryPolicy(
            maxAttempts: 3,
            baseDelayMS: 100,
            maxDelayMS: 500,
            jitterRangeMS: 0...25
        )

        let firstDelay = policy.delayNanoseconds(forAttempt: 1) / 1_000_000
        let secondDelay = policy.delayNanoseconds(forAttempt: 2) / 1_000_000
        let thirdDelay = policy.delayNanoseconds(forAttempt: 3) / 1_000_000

        XCTAssertTrue((100...125).contains(Int(firstDelay)))
        XCTAssertTrue((200...225).contains(Int(secondDelay)))
        XCTAssertTrue((400...425).contains(Int(thirdDelay)))
    }
}
