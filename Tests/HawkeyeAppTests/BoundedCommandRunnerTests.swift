import XCTest
@testable import Hawkeye2

final class BoundedCommandRunnerTests: XCTestCase {
    func testReturnsOutputAndReportsCommandFailure() async throws {
        let runner = BoundedCommandRunner()
        let output = try await runner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "hello\n")
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
            XCTFail("A failed process must throw.")
        } catch { XCTAssertEqual(error as? CommandFailure, .failed) }
    }

    func testTimeoutTerminatesAnUnresponsiveCommand() async throws {
        let runner = BoundedCommandRunner(timeout: 0.05)
        let started = Date()
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
            XCTFail("A command past its deadline must throw.")
        } catch { XCTAssertEqual(error as? CommandFailure, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testCancellationTerminatesTheProcess() async throws {
        let task = Task {
            try await BoundedCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        }
        try await Task.sleep(for: .milliseconds(30))
        let stopped = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled commands must throw.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(stopped), 2)
    }

    func testOutputIsBounded() async throws {
        do {
            _ = try await BoundedCommandRunner(maximumOutputBytes: 1024).run(
                executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: ["output"])
            XCTFail("Excessive output must stop the command.")
        } catch { XCTAssertEqual(error as? CommandFailure, .outputTooLarge) }
    }
}
