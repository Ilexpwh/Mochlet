import Foundation
import Observation
import MochletCore

/// Plan usage pills: Claude from the statusline relay, Codex from `codex app-server`.
@MainActor
@Observable
final class PlanStore {
    private(set) var claude: PlanUsage?
    private(set) var codex: PlanUsage?
    private(set) var codexLoading = false
    @ObservationIgnored private var codexLastAttempt: Date?
    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        if let data = defaults.data(forKey: "claudePlanUsage"), let u = try? JSONDecoder().decode(PlanUsage.self, from: data) {
            claude = u
        }
    }

    func receive(statusLine s: StatusLinePayload, now: Date = Date()) {
        guard let u = PlanUsage.fromClaude(rateLimits: s.rateLimits, now: now) else { return }
        if let c = claude, c.fiveHour == u.fiveHour, c.week == u.week, now.timeIntervalSince(c.updatedAt) < 30 { return }
        claude = u
        if let data = try? JSONEncoder().encode(u) { defaults.set(data, forKey: "claudePlanUsage") }
    }

    /// `rate_limit_event` from a `claude -p` run: the same windows in a different shape.
    func receive(claudeRateLimitEvent info: JSONValue, now: Date = Date()) {
        let windows = info["unifiedWindows"]
        var limits: [String: JSONValue] = [:]
        for key in ["five_hour", "seven_day"] {
            let w = windows[key]
            guard let util = w["utilization"].number else { continue }
            var o: [String: JSONValue] = ["used_percentage": .number(util * 100)]
            if let r = w["resetsAt"].number { o["resets_at"] = .number(r) }
            limits[key] = .object(o)
        }
        guard !limits.isEmpty else { return }
        receive(statusLine: StatusLinePayload(sessionID: "", rateLimits: .object(limits)), now: now)
    }

    /// At most once a minute, and never two at once.
    func refreshCodex(force: Bool = false) {
        let now = Date()
        if !force, let c = codex, now.timeIntervalSince(c.updatedAt) < 60 { return }
        if codexLoading { return }
        if !force, let a = codexLastAttempt, now.timeIntervalSince(a) < 60 { return }
        codexLastAttempt = now
        codexLoading = true
        Task.detached(priority: .utility) {
            let result = CodexPlanGauge.fetch()
            await MainActor.run {
                AppCoordinator.shared.plans.codexLoading = false
                if let r = result { AppCoordinator.shared.plans.codex = r }
            }
        }
    }

    static func label(_ name: String, _ u: PlanUsage?, now: Date = Date()) -> String {
        guard let u else { return "\(name) —" }
        return "\(name) \(Int(u.dominantPercent(now: now).rounded()))%"
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        return "\(Int(s / 3600)) h ago"
    }
}

/// Asks the Codex CLI for its rate limits over its JSON-RPC app server (15 s cap).
enum CodexPlanGauge {
    static func binary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = ["~/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.npm-global/bin/codex", "~/.volta/bin/codex", "~/.bun/bin/codex", "~/Library/pnpm/codex"]
            .map { $0.hasPrefix("~") ? home.appendingPathComponent(String($0.dropFirst(2))).path : $0 }
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path) {
            let sorted = versions.sorted { a, b in
                let pa = a.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").compactMap { Int($0) }
                let pb = b.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").compactMap { Int($0) }
                return pa.lexicographicallyPrecedes(pb) == false
            }
            candidates += sorted.map { nvm.appendingPathComponent("\($0)/bin/codex").path }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    nonisolated static func fetch() -> PlanUsage? {
        guard let bin = binary() else { return nil }
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [bin.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        proc.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        defer { if proc.isRunning { proc.terminate() } }
        let requests = """
        {"id":1,"method":"initialize","params":{"clientInfo":{"name":"mochlet","version":"1"}}}
        {"method":"initialized"}
        {"id":2,"method":"account/rateLimits/read"}

        """
        inPipe.fileHandleForWriting.write(Data(requests.utf8))
        let deadline = Date().addingTimeInterval(15)
        let reader = outPipe.fileHandleForReading
        var buffer = Data()
        var result: PlanUsage?
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                var found = false
                for line in buffer.split(separator: 0x0A) {
                    guard let obj = JSONValue.parse(line), obj["id"].int == 2 else { continue }
                    if obj["result"].object != nil { result = PlanUsage.fromCodex(result: obj["result"]) }
                    found = true
                    break
                }
                if found { break }
            }
        }
        if group.wait(timeout: .now() + 15) == .timedOut || Date() > deadline {
            proc.terminate()
        }
        proc.terminate()
        try? inPipe.fileHandleForWriting.close()
        return result
    }
}
