import Foundation
import Observation
import MochletCore

/// Settings → Agents: status per agent, previews, installs and removals through the safe-write protocol.
/// JSON-config agents merge into a shared file; plugin agents get a whole file Mochlet generates.
@MainActor
@Observable
final class AgentInstallerController {
    enum Supported: String, CaseIterable, Identifiable {
        case claude, codex, gemini, antigravity, copilot, muse, opencode, amp, hermes
        var id: String { rawValue }
        var kind: AgentKind { AgentKind(tag: rawValue, bundleID: nil, termProgram: nil) }

        /// The file the Agents tab shows (and the one the preview diffs).
        var file: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claude: return home.appendingPathComponent(".claude/settings.json")
            case .codex: return home.appendingPathComponent(".codex/hooks.json")
            case .gemini: return home.appendingPathComponent(".gemini/settings.json")
            case .antigravity: return home.appendingPathComponent(".gemini/config/hooks.json")
            case .copilot: return home.appendingPathComponent(".copilot/hooks/mochlet.json")
            case .muse: return home.appendingPathComponent(".config/muse/settings.json")
            case .opencode: return home.appendingPathComponent(OpenCodePluginSpec.relativePath)
            case .amp: return home.appendingPathComponent(AmpPluginSpec.relativePath)
            case .hermes: return home.appendingPathComponent(HermesPluginSpec.initPath)
            }
        }
        var binaryNames: [String] {
            switch self {
            case .claude: return ["claude"]
            case .codex: return ["codex"]
            case .gemini: return ["gemini"]
            case .antigravity: return ["agy", "antigravity"]
            case .copilot: return ["copilot"]
            case .muse: return ["muse"]
            case .opencode: return ["opencode"]
            case .amp: return ["amp"]
            case .hermes: return ["hermes"]
            }
        }
        /// Plugin agents: Mochlet owns the whole file.
        var isGenerated: Bool { self == .opencode || self == .amp || self == .hermes }
        /// Shown under the row once installed.
        var afterInstallNote: String? {
            switch self {
            case .copilot, .opencode, .amp: return "Restart \(kind.displayName) so it loads the plugin."
            case .hermes: return "Run `hermes plugins enable mochlet` once."
            case .antigravity: return "Antigravity reads hooks on launch."
            default: return nil
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
        /// Companion files written with the main one (Hermes `plugin.yaml`).
        var extraFiles: [(URL, Data)] = []
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
                if a.isGenerated {
                    let existing = try? String(contentsOf: a.file, encoding: .utf8)
                    row.status = GeneratedPluginFile.status(existing: existing, relayPath: relayPath)
                    if let existing, row.status == .notInstalled, !existing.isEmpty {
                        row.note = "A file of yours already exists there; Mochlet will not touch it."
                    }
                } else {
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
                    case .antigravity:
                        row.status = AntigravityHookSpec.status(of: json, relayPath: relayPath)
                    case .copilot:
                        row.status = CopilotHookSpec.status(of: json, relayPath: relayPath)
                    case .muse:
                        row.status = MuseHookSpec.status(of: json, relayPath: relayPath)
                    default:
                        break
                    }
                }
                if row.note == nil, row.status == .installed, let n = a.afterInstallNote { row.note = n }
            } catch {
                row.error = error.localizedDescription
            }
            return row
        }
    }

    static func cliExists(_ names: [String]) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.bun/bin", "\(home)/.cargo/bin", "/usr/bin"]
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
            if a.isGenerated {
                let original = try? Data(contentsOf: a.file)
                if let original, !GeneratedPluginFile.isOurs(String(decoding: original, as: UTF8.self)) {
                    throw ConfigFileError.unexpectedShape(a.file.path, "a file that Mochlet did not generate")
                }
                let contents: String
                var extra: [(URL, Data)] = []
                switch a {
                case .opencode: contents = OpenCodePluginSpec.contents(relayPath: relayPath)
                case .amp: contents = AmpPluginSpec.contents(relayPath: relayPath)
                default:
                    contents = HermesPluginSpec.initPy(relayPath: relayPath)
                    extra = [(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(HermesPluginSpec.yamlPath), Data(HermesPluginSpec.pluginYAML.utf8))]
                }
                let data = Data(contents.utf8)
                preview = Preview(agent: a, path: a.file, before: original.map { String(decoding: $0, as: UTF8.self) } ?? "(no file yet)",
                                  after: contents, data: data, original: original, previousStatusLine: nil, extraFiles: extra)
                return
            }
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
            case .antigravity:
                after = try AntigravityHookSpec.install(into: json, relayPath: relayPath, path: a.file.path)
            case .copilot:
                after = try CopilotHookSpec.install(into: json, relayPath: relayPath, path: a.file.path)
            case .muse:
                after = try MuseHookSpec.install(into: json, relayPath: relayPath, path: a.file.path)
            default:
                return
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
            for (url, data) in p.extraFiles {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            if let prev = p.previousStatusLine {
                try? ConfigFile.serialize(prev).write(to: RelayInstaller.previousStatusLineURL, options: .atomic)
            }
            var msg = "Installed for \(p.agent.kind.displayName)." + (backup.map { " Backup: \($0.lastPathComponent)" } ?? "")
            if let n = p.agent.afterInstallNote { msg += " " + n }
            lastMessage = msg
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
            if a.isGenerated {
                let fm = FileManager.default
                let existing = (try? String(contentsOf: a.file, encoding: .utf8)) ?? ""
                guard GeneratedPluginFile.isOurs(existing) else {
                    lastMessage = "\(a.file.lastPathComponent) was not generated by Mochlet, so it was left alone."
                    refresh()
                    return
                }
                try fm.removeItem(at: a.file)
                if a == .hermes {
                    let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(HermesPluginSpec.directory)
                    try? fm.removeItem(at: fm.homeDirectoryForCurrentUser.appendingPathComponent(HermesPluginSpec.yamlPath))
                    if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
                }
                lastMessage = "Removed \(a.file.lastPathComponent)."
                refresh()
                return
            }
            let (json, original) = try ConfigFile.read(a.file)
            let after: JSONValue?
            switch a {
            case .claude:
                let prev = (try? Data(contentsOf: RelayInstaller.previousStatusLineURL)).flatMap { JSONValue.parse($0) }
                after = try ClaudeHookSpec.uninstall(from: json, previousStatusLine: prev, path: a.file.path)
            case .codex:
                after = CodexHookSpec.uninstall(from: json)
            case .gemini:
                after = GeminiHookSpec.uninstall(from: json)
            case .antigravity:
                after = AntigravityHookSpec.uninstall(from: json)
            case .copilot:
                after = CopilotHookSpec.uninstall(from: json)
            case .muse:
                after = MuseHookSpec.uninstall(from: json)
            default:
                return
            }
            if let after {
                try ConfigFile.write(ConfigFile.serialize(after), to: a.file, expecting: original)
            } else if original != nil {
                // The file held nothing but our hooks (Copilot): remove it rather than leave `{}`.
                try FileManager.default.removeItem(at: a.file)
            }
            if a == .claude { try? FileManager.default.removeItem(at: RelayInstaller.previousStatusLineURL) }
            lastMessage = "Removed Mochlet's hooks from \(a.file.lastPathComponent)."
        } catch {
            lastMessage = error.localizedDescription
        }
        refresh()
    }
}
