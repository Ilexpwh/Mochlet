import Testing
import Foundation
@testable import SlimeCore

@Test func commandPreservesArgumentsAndTerminatesOnTimeout() async throws {
    let result = try await CommandProcess().run(executable: "/usr/bin/printf", arguments: ["%s", "literal $(not-a-command); `test`\nsecond line"])
    #expect(String(decoding: result.data, as: UTF8.self) == "literal $(not-a-command); `test`\nsecond line")
    await #expect(throws: (any Error).self) { try await CommandProcess().run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.05) }
}

@Test func blockedPipesDoNotStarveConcurrentCommandTimeouts() async throws {
    let started = ProcessInfo.processInfo.systemUptime
    let cancelled = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<24 {
            group.addTask {
                do { _ = try await CommandProcess().run(executable: "/bin/sleep", arguments: ["8"], timeout: 0.1); return false }
                catch { return error.localizedDescription.contains("timed out") }
            }
        }
        var results: [Bool] = []
        for await result in group { results.append(result) }
        return results
    }
    #expect(cancelled.count == 24 && cancelled.allSatisfy { $0 })
    #expect(ProcessInfo.processInfo.systemUptime - started < 6)
    await #expect(throws: (any Error).self) { try await CommandProcess().run(executable: "/bin/sleep", arguments: ["1"], timeout: .nan) }
}
