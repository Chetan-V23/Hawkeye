import Foundation

enum CommandFailure: Error, Equatable {
    case timedOut, failed, outputTooLarge
}

struct BoundedCommandRunner: Sendable {
    let timeout: TimeInterval
    let maximumOutputBytes: Int

    init(timeout: TimeInterval = 4, maximumOutputBytes: Int = 2 * 1024 * 1024) {
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }

    func run(executable: URL, arguments: [String]) async throws -> Data {
        let invocation = CommandInvocation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    invocation.run(executable: executable, arguments: arguments, timeout: timeout,
                                   maximumOutputBytes: maximumOutputBytes, continuation: continuation)
                }
            }
        } onCancel: {
            invocation.cancel(with: CancellationError())
        }
    }
}

private final class CommandInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var failure: Error?

    func cancel(with error: Error) {
        lock.lock()
        guard failure == nil else { lock.unlock(); return }
        failure = error
        let running = process
        if running?.isRunning == true { running?.terminate() }
        lock.unlock()
        guard let running else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
            if running.isRunning { kill(running.processIdentifier, SIGKILL) }
        }
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval, maximumOutputBytes: Int,
             continuation: CheckedContinuation<Data, Error>) {
        let command = Process()
        let output = Pipe()
        command.executableURL = executable
        command.arguments = arguments
        command.standardOutput = output
        command.standardError = FileHandle.nullDevice
        command.standardInput = FileHandle.nullDevice
        lock.lock()
        if let failure { lock.unlock(); continuation.resume(throwing: failure); return }
        process = command
        do { try command.run() }
        catch { process = nil; lock.unlock(); continuation.resume(throwing: CommandFailure.failed); return }
        lock.unlock()
        let expiration = DispatchWorkItem { [weak self] in self?.cancel(with: CommandFailure.timedOut) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: expiration)
        var data = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if data.count + chunk.count > maximumOutputBytes { cancel(with: CommandFailure.outputTooLarge) }
            else { data.append(chunk) }
        }
        command.waitUntilExit()
        expiration.cancel()
        try? output.fileHandleForReading.close()
        lock.lock()
        let failure = failure
        process = nil
        lock.unlock()
        if let failure { continuation.resume(throwing: failure) }
        else if command.terminationStatus != 0 { continuation.resume(throwing: CommandFailure.failed) }
        else { continuation.resume(returning: data) }
    }
}
