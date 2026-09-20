import Foundation

struct ProcessOutput: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    var text: String { String(decoding: stdout, as: UTF8.self) }
    var errorText: String {
        String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs executables with an argument array. Nothing here goes through a shell.
enum ProcessRunner {
    private final class Box: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var flag = false
        var timedOut: Bool {
            get { lock.withLock { flag } }
            set { lock.withLock { flag = newValue } }
        }
    }

    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    static func run(_ executable: URL, _ arguments: [String], cwd: URL? = nil, stdin: Data? = nil,
                    environment: [String: String]? = nil, timeout: TimeInterval = 60) async throws -> ProcessOutput {
        _ = ignoreSIGPIPE
        let box = Box()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = box.process
                    process.executableURL = executable
                    process.arguments = arguments
                    process.currentDirectoryURL = cwd
                    if let environment { process.environment = environment }
                    let out = Pipe(), err = Pipe(), input = Pipe()
                    process.standardOutput = out
                    process.standardError = err
                    process.standardInput = stdin == nil ? FileHandle.nullDevice : input
                    do { try process.run() } catch {
                        continuation.resume(throwing: HunkError("Couldn’t launch \(executable.lastPathComponent): \(error.localizedDescription)"))
                        return
                    }
                    let timer = DispatchWorkItem {
                        guard process.isRunning else { return }
                        box.timedOut = true; process.terminate()
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                    let group = DispatchGroup()
                    if let stdin {
                        DispatchQueue.global().async(group: group) {
                            try? input.fileHandleForWriting.write(contentsOf: stdin)
                            try? input.fileHandleForWriting.close()
                        }
                    }
                    nonisolated(unsafe) var errData = Data()
                    DispatchQueue.global().async(group: group) {
                        errData = err.fileHandleForReading.readDataToEndOfFile()
                    }
                    let outData = out.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    timer.cancel()
                    if box.timedOut {
                        continuation.resume(throwing: HunkError("\(executable.lastPathComponent) timed out after \(Int(timeout)) seconds."))
                    } else if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: ProcessOutput(status: process.terminationStatus, stdout: outData, stderr: errData))
                    }
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }
}
