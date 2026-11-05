import Foundation

/// Flags a CLI accepts, read from its `--help` so nothing is pinned to a version.
public struct CLICapabilities: Sendable, Equatable, Codable {
    public var flags: Set<String>

    public init(flags: Set<String> = []) { self.flags = flags }

    public static func parse(help: String) -> CLICapabilities {
        var flags = Set<String>()
        guard let re = try? NSRegularExpression(pattern: #"(?<![\w-])(--[a-zA-Z][\w-]*)"#) else { return CLICapabilities() }
        let ns = help as NSString
        for m in re.matches(in: help, range: NSRange(location: 0, length: ns.length)) {
            flags.insert(ns.substring(with: m.range(at: 1)))
        }
        return CLICapabilities(flags: flags)
    }

    public func has(_ flag: String) -> Bool { flags.contains(flag) }
    public var isEmpty: Bool { flags.isEmpty }
}

/// Argument lists for the three subscription CLIs, chosen from what each binary advertises.
public enum CLIArgs {
    public static func claude(resume: String?, sessionID: String?, model: String?, caps: CLICapabilities, permissionMode: String? = nil) -> [String] {
        var a = ["-p", "--output-format", "stream-json", "--verbose"]
        if caps.isEmpty || caps.has("--include-partial-messages") { a.append("--include-partial-messages") }
        if let resume, !resume.isEmpty { a += ["--resume", resume] }
        else if let sessionID, !sessionID.isEmpty, caps.isEmpty || caps.has("--session-id") { a += ["--session-id", sessionID] }
        if let model, !model.isEmpty { a += ["--model", model] }
        if let permissionMode, !permissionMode.isEmpty, caps.isEmpty || caps.has("--permission-mode") { a += ["--permission-mode", permissionMode] }
        return a
    }

    public static func codex(resume: String?, model: String?, cwd: String?, sandbox: String, caps: CLICapabilities) -> [String] {
        var a = ["exec"]
        if let resume, !resume.isEmpty { a += ["resume", resume] }
        a.append("--json")
        if caps.isEmpty || caps.has("--skip-git-repo-check") { a.append("--skip-git-repo-check") }
        if let cwd, !cwd.isEmpty, resume == nil { a += ["-C", cwd] }
        if let model, !model.isEmpty { a += ["-m", model] }
        if !sandbox.isEmpty { a += ["-s", sandbox] }
        a.append("-")
        return a
    }

    public static func gemini(resume: String?, model: String?, approvalMode: String?, caps: CLICapabilities) -> [String] {
        var a = ["-p", "", "-o", "stream-json"]
        if let model, !model.isEmpty { a += ["-m", model] }
        if let resume, !resume.isEmpty { a += ["--resume", resume] }
        if let approvalMode, !approvalMode.isEmpty, caps.isEmpty || caps.has("--approval-mode") { a += ["--approval-mode", approvalMode] }
        return a
    }
}
