import Testing
import Foundation
@testable import SlimeCore

@Test func commandPreservesArgumentsAndTerminatesOnTimeout() async throws {
    let result = try await CommandProcess().run(executable: "/usr/bin/printf", arguments: ["%s", "literal $(not-a-command); `test`\nsecond line"])
    #expect(String(decoding: result.data, as: UTF8.self) == "literal $(not-a-command); `test`\nsecond line")
    await #expect(throws: (any Error).self) { try await CommandProcess().run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.05) }
}
