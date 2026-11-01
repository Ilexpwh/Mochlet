import Foundation

public struct CommandOutput: Sendable { public let status: Int32; public let data: Data }

/// One bounded command, without a shell. Drains both pipes independently so a
/// full stderr pipe cannot deadlock stdout. Cancellation and timeout stop it.
public actor CommandProcess {
    private var process: Process?
    private var continuation: CheckedContinuation<CommandOutput, Error>?
    private var output = Data()
    private var exitStatus: Int32?
    private var endedPipes = 0
    private var closed = false
    private var timeoutTask: Task<Void, Never>?
    public init() {}
    public func run(executable: String, arguments: [String], cwd: String? = nil, timeout: Double = 45, environment: [String: String] = [:]) async throws -> CommandOutput {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard process == nil, !closed else { continuation.resume(throwing: MochletError.message("Command already used or cancelled.")); return }
                self.continuation = continuation
                let p = Process(); let stdout = Pipe(); let stderr = Pipe()
                p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
                p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                p.standardInput = FileHandle.nullDevice; p.standardOutput = stdout; p.standardError = stderr
                p.terminationHandler = { [weak self] process in Task { await self?.exited(process.terminationStatus) } }
                do { try p.run(); process = p }
                catch { finish(.failure(error)); return }
                Task.detached { [weak self] in
                    while true {
                        let bytes = stdout.fileHandleForReading.availableData
                        if bytes.isEmpty { break }; await self?.receive(bytes)
                    }
                    await self?.pipeEnded()
                }
                Task.detached { [weak self] in
                    // Error output can contain credentials or private repository text.
                    // Drain without retaining it; callers show command/status context.
                    while !stderr.fileHandleForReading.availableData.isEmpty {}
                    await self?.pipeEnded()
                }
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)); await self?.abort("Command timed out.") } catch { }
                }
            }
        } onCancel: { Task { await self.abort("Command cancelled.") } }
    }
    private func receive(_ data: Data) {
        guard !closed else { return }
        guard output.count + data.count <= 8_000_000 else { abort("Command output exceeded the 8 MB limit."); return }
        output.append(data)
    }
    private func exited(_ status: Int32) { exitStatus = status; completeIfReady() }
    private func pipeEnded() { endedPipes += 1; completeIfReady() }
    private func completeIfReady() {
        guard let exitStatus, endedPipes == 2 else { return }
        finish(.success(CommandOutput(status: exitStatus, data: output)))
    }
    private func finish(_ result: Result<CommandOutput, Error>) {
        guard !closed else { return }; closed = true; timeoutTask?.cancel(); timeoutTask = nil
        continuation?.resume(with: result); continuation = nil
    }
    private func abort(_ reason: String) {
        guard !closed else { return }
        if let process, process.isRunning {
            process.terminate()
            Task.detached {
                try? await Task.sleep(for: .seconds(2))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        finish(.failure(MochletError.message(reason)))
    }
}
