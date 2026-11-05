import Foundation
import Observation
import MochletCore

/// Settings → Agents: status per agent, previews, installs and removals through the safe-write protocol.
@MainActor
@Observable
final class AgentInstallerController {
    enum Supported: String, CaseIterable, Identifiable {
        case claude, codex, gemini
        var id: String { rawValue }
        var kind: AgentKind {
            switch self {
            case .claude: return .claude
            case .codex: return .codex
            case .gemini: return .gemini
            }
        }
        var file: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claude: return home.appendingPathComponent(".claude/settings.json")
            case .codex: return home.appendingPathComponent(".codex/hooks.json")
            case .gemini: return home.appendingPathComponent(".gemini/settings.json")
            }
        }
        var binaryNames: [String] {
            switch self {
            case .claude: return ["claude"]
            case .codex: return ["codex"]
            case .gemini: return ["gemini"]
            }
        }
    }

    struct Row: Identifiable {
        var agent: Supported
        var status: HookInstallStatus
        var cliFound: Bool
        var note: String?
        var error: String?
        var id: String { agent.id }
    }

    struct Preview: Identifiable {
        var id = UUID()
        var agent: Supported
        var path: URL
        var before: String
        var after: String
        var data: Data
        var original: Data?
        var previousStatusLine: JSONValue?
    }

    private(set) var rows: [Row] = []
    var preview: Preview?
    private(set) var lastMessage: String?
    @ObservationIgnored private unowned let app: AppCoordinator
    @ObservationIgnored private var codexEventSeen = false

    init(app: AppCoordinator) {
        self.app = app
    }

    var relayPath: String { RelayInstaller.relayURL.path }

    func noteCodexEvent() {
        guard !codexEventSeen else { return }
        codexEventSeen = true
        refresh()
    }

    func refresh() {
        rows = Supported.allCases.map { a in
            var row = Row(agent: a, status: .notInstalled, cliFound: Self.cliExists(a.binaryNames))
            do {
                let (json, _) = try ConfigFile.read(a.file)
                switch a {
                case .claude:
                    row.status = ClaudeHookSpec.status(of: json, relayPath: relayPath)
                case .codex:
                    row.status = CodexHookSpec.status(of: json, relayPath: relayPath)
                    if row.status != .notInstalled {
                        let toml = (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml"), encoding: .utf8)) ?? ""
                        let group = CodexHookSpec.groupIndex(in: json, event: "SessionStart") ?? 0
                        let trusted = codexEventSeen || CodexHookSpec.isTrusted(configTOML: toml, hooksPath: a.file.path, sessionStartGroup: group)
                        row.note = trusted ? "Trusted." : "Run /hooks inside codex and trust Mochlet's hooks; Codex ignores them until then."
                    }
                case .gemini:
                    row.status = GeminiHookSpec.status(of: json, relayPath: relayPath)
                }
            } catch {
                row.error = error.localizedDescription
            }
            return row
        }
    }

    static func cliExists(_ names: [String]) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.bun/bin", "/usr/bin"]
        return names.contains { n in dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(n)") } }
    }

    /// Computes the whole new file for the user to read before anything is written.
    func prepareInstall(_ a: Supported) {
        lastMessage = nil
        guard RelayInstaller.ensureInstalled() != nil else {
            lastMessage = "The relay helper is missing from the app bundle."
            return
        }
        do {
            let (json, original) = try ConfigFile.read(a.file)
            var previous: JSONValue?
            let after: JSONValue
            switch a {
            case .claude:
                let r = try ClaudeHookSpec.install(into: json, relayPath: relayPath, path: a.file.path)
                after = r.json
                previous = r.previousStatusLine
            case .codex:
                after = try CodexHookSpec.install(into: json, relayPath: relayPath, path: a.file.path)
            case .gemini:
                after = try GeminiHookSpec.install(into: json, relayPath: relayPath, path: a.file.path)
            }
            let data = ConfigFile.serialize(after)
            preview = Preview(agent: a, path: a.file, before: original.map { String(decoding: $0, as: UTF8.self) } ?? "(no file yet)",
                              after: String(decoding: data, as: UTF8.self), data: data, original: original, previousStatusLine: previous)
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    func confirmInstall() {
        guard let p = preview else { return }
        do {
            let backup = try ConfigFile.write(p.data, to: p.path, expecting: p.original)
            if let prev = p.previousStatusLine {
                try? ConfigFile.serialize(prev).write(to: RelayInstaller.previousStatusLineURL, options: .atomic)
            }
            lastMessage = "Installed for \(p.agent.kind.displayName)." + (backup.map { " Backup: \($0.lastPathComponent)" } ?? "")
            preview = nil
        } catch {
            lastMessage = error.localizedDescription
            preview = nil
        }
        refresh()
    }

    func cancelPreview() {
        preview = nil
    }

    func uninstall(_ a: Supported) {
        lastMessage = nil
        do {
            let (json, original) = try ConfigFile.read(a.file)
            let after: JSONValue
            switch a {
            case .claude:
                let prev = (try? Data(contentsOf: RelayInstaller.previousStatusLineURL)).flatMap { JSONValue.parse($0) }
                after = try ClaudeHookSpec.uninstall(from: json, previousStatusLine: prev, path: a.file.path)
            case .codex:
                after = CodexHookSpec.uninstall(from: json)
            case .gemini:
                after = GeminiHookSpec.uninstall(from: json)
            }
            try ConfigFile.write(ConfigFile.serialize(after), to: a.file, expecting: original)
            if a == .claude { try? FileManager.default.removeItem(at: RelayInstaller.previousStatusLineURL) }
            lastMessage = "Removed Mochlet's hooks from \(a.file.lastPathComponent)."
        } catch {
            lastMessage = error.localizedDescription
        }
        refresh()
    }
}
