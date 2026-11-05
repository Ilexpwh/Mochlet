// mochlet-hook: the relay every coding agent's hook runs.
//
//   mochlet-hook [--agent <name>] [--ask] [--statusline] [<EventName>]
//
// Reads the hook payload from stdin, adds the agent tag, a terminal identity block and the
// session name from the transcript, and writes one JSON line to Mochlet's Unix socket.
// Non-blocking events return at once (connect budget 300 ms). PermissionRequest and
// --ask hold the socket until Mochlet answers and print the agent's decision format.
// Always exits 0; the agent must never be blocked by a missing or busy Mochlet.
import Foundation
import Darwin

let version = "1"
let debug = ProcessInfo.processInfo.environment["MOCHLET_HOOK_DEBUG"] == "1"

func log(_ s: @autoclosure () -> String) {
    guard debug else { return }
    FileHandle.standardError.write(Data(("mochlet-hook: " + s() + "\n").utf8))
}

func emit(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

// MARK: - Arguments

var agentTag: String?
var askMode = false
var statusMode = false
var eventArg: String?
var argv = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < argv.count {
    let a = argv[i]
    switch a {
    case "--agent":
        if i + 1 < argv.count { agentTag = argv[i + 1]; i += 1 }
    case "--ask": askMode = true
    case "--statusline": statusMode = true
    case "--version":
        print(version)
        exit(0)
    case "--help", "-h":
        print("mochlet-hook [--agent <name>] [--ask] [--statusline] [<EventName>]")
        exit(0)
    default:
        if !a.hasPrefix("--"), eventArg == nil { eventArg = a }
    }
    i += 1
}

// MARK: - Paths

let env = ProcessInfo.processInfo.environment
let home = env["HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
let supportDir = home.appendingPathComponent("Library/Application Support/Mochlet", isDirectory: true)
let socketPath = env["MOCHLET_SOCKET"] ?? supportDir.appendingPathComponent("mochlet.sock").path
let previousStatusline = supportDir.appendingPathComponent("statusline-previous.json")

// MARK: - stdin

let maxStdin = 1_000_000
var stdinData = Data()
while let chunk = try? FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
    stdinData.append(chunk)
    if stdinData.count > maxStdin { break }
}
var payload: [String: Any] = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any] ?? [:]
let stdinValid = !stdinData.isEmpty && (try? JSONSerialization.jsonObject(with: stdinData)) is [String: Any]

// MARK: - Socket

/// Connects, sends one line and (when `wait`) reads one line back. `timeout` applies to the
/// reply; the connect itself is instant on a Unix socket (ENOENT/ECONNREFUSED without a server).
func exchange(_ object: [String: Any], wait: Bool, timeout: TimeInterval) -> [String: Any]? {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
    data.append(0x0A)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (k, b) in pathBytes.enumerated() { buf[k] = b }
        buf[pathBytes.count] = 0
    }
    var connectTimeout = timeval(tv_sec: 0, tv_usec: 300_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &connectTimeout, socklen_t(MemoryLayout<timeval>.size))
    let len = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
    let rc = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard rc == 0 else {
        log("connect failed: \(String(cString: strerror(errno)))")
        return nil
    }
    var sent = 0
    let ok = data.withUnsafeBytes { buf -> Bool in
        while sent < buf.count {
            let n = send(fd, buf.baseAddress! + sent, buf.count - sent, 0)
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
    guard ok else { return nil }
    guard wait else { return [:] }
    var replyTimeout = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &replyTimeout, socklen_t(MemoryLayout<timeval>.size))
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n <= 0 { break }
        reply.append(contentsOf: buffer[0..<n])
        if reply.contains(0x0A) { break }
    }
    guard !reply.isEmpty, let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
        log("no reply")
        return nil
    }
    return obj
}

// MARK: - Terminal identity

/// Controlling tty of the nearest ancestor that has one (the agent process), via sysctl.
func controllingTTY() -> (tty: String, pid: Int32)? {
    var pid = getppid()
    for _ in 0..<8 where pid > 1 {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = info.kp_eproc.e_tdev
        if dev != UInt32.max, dev != 0, let name = devname(dev, S_IFCHR) {
            return (String(cString: name), pid)
        }
        pid = info.kp_eproc.e_ppid
    }
    return nil
}

func addTerminalIdentity(_ p: inout [String: Any]) {
    func set(_ key: String, _ value: Any?) {
        guard p[key] == nil, let value else { return }
        if let s = value as? String, s.isEmpty { return }
        p[key] = value
    }
    set("term_program", env["TERM_PROGRAM"])
    set("term_session_id", env["TERM_SESSION_ID"])
    set("iterm_session_id", env["ITERM_SESSION_ID"])
    set("wezterm_pane", env["WEZTERM_PANE"])
    set("kitty_window_id", env["KITTY_WINDOW_ID"])
    if env["GHOSTTY_RESOURCES_DIR"] != nil || env["GHOSTTY_BIN_DIR"] != nil || env["TERM_PROGRAM"] == "ghostty" { set("ghostty", true) }
    set("tmux_pane", env["TMUX_PANE"])
    if let tmux = env["TMUX"], let sock = tmux.split(separator: ",").first { set("tmux_socket", String(sock)) }
    set("bundle_id", env["__CFBundleIdentifier"])
    set("claude_entrypoint", env["CLAUDE_CODE_ENTRYPOINT"])
    if env["VSCODE_IPC_HOOK_CLI"] != nil || env["VSCODE_PID"] != nil { set("vscode_ipc", true) }
    if let t = controllingTTY() {
        set("tty", t.tty)
        set("shell_pid", Int(t.pid))
    }
}

// MARK: - Session name from the transcript

func addSessionName(_ p: inout [String: Any]) {
    guard let path = p["transcript_path"] as? String, !path.isEmpty, let fh = FileHandle(forReadingAtPath: path) else { return }
    defer { try? fh.close() }
    if p["session_root"] == nil, let head = try? fh.read(upToCount: 16384) {
        for line in head.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            p["session_root"] = cwd
            break
        }
    }
    if p["session_title"] == nil, let size = try? fh.seekToEnd() {
        let start = size > 65536 ? size - 65536 : 0
        try? fh.seek(toOffset: start)
        if let tail = try? fh.readToEnd() {
            var lines = tail.split(separator: 0x0A)
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            let needle = Data("\"custom-title\"".utf8)
            for line in lines.reversed() where line.range(of: needle) != nil {
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let t = obj["customTitle"] as? String, !t.isEmpty {
                    p["session_title"] = t
                }
                break
            }
        }
    }
}

// MARK: - Normalisation

func normalizeEvent(_ raw: String) -> String {
    switch raw {
    case "BeforeTool", "BeforeToolSelection", "pre_tool_use", "preToolUse": return "PreToolUse"
    case "AfterTool", "AfterModel", "PostInvocation", "post_tool_use", "postToolUse": return "PostToolUse"
    case "BeforeAgent", "PreInvocation", "user_prompt_submit", "userPromptSubmitted", "beforeSubmitPrompt": return "UserPromptSubmit"
    case "AfterAgent", "stop", "agentStop": return "Stop"
    case "startup", "session_start", "sessionStart": return "SessionStart"
    case "exit", "session_end", "sessionEnd": return "SessionEnd"
    case "notification": return "Notification"
    case "permissionRequest": return "PermissionRequest"
    default: return raw
    }
}

func normalizeToolFields(_ p: inout [String: Any]) {
    if p["tool_name"] == nil {
        var name: String?
        if let n = p["toolName"] as? String, !n.isEmpty { name = n }
        else if let call = p["toolCall"] as? [String: Any], let n = call["name"] as? String, !n.isEmpty { name = n }
        else if let n = p["tool"] as? String, !n.isEmpty { name = n }
        if let name { p["tool_name"] = name }
    }
    if p["tool_input"] == nil {
        if let args = p["toolArgs"] as? [String: Any] {
            p["tool_input"] = args
        } else if let call = p["toolCall"] as? [String: Any], var args = call["args"] as? [String: Any] {
            for (from, to) in [("CommandLine", "command"), ("FilePath", "file_path"), ("Path", "path"), ("Url", "url"), ("Query", "query"), ("Pattern", "pattern")] {
                if let v = args[from], args[to] == nil { args[to] = v }
            }
            p["tool_input"] = args
        }
    }
    if (p["session_id"] as? String ?? "").isEmpty {
        for k in ["conversationId", "conversation_id", "sessionId", "GEMINI_SESSION_ID"] {
            if let v = p[k] as? String, !v.isEmpty { p["session_id"] = v; break }
        }
        if (p["session_id"] as? String ?? "").isEmpty, let v = env["GEMINI_SESSION_ID"], !v.isEmpty { p["session_id"] = v }
    }
    if (p["cwd"] as? String ?? "").isEmpty {
        for k in ["workspacePaths", "workspace_roots"] {
            if let list = p[k] as? [Any], let first = list.first as? String, !first.isEmpty { p["cwd"] = first; break }
        }
    }
    if (p["cwd"] as? String ?? "").isEmpty, let w = p["workdir"] as? String, !w.isEmpty { p["cwd"] = w }
    if (p["cwd"] as? String ?? "").isEmpty { p["cwd"] = FileManager.default.currentDirectoryPath }
}

// MARK: - Modes

if statusMode {
    var line: [String: Any] = ["mochlet_kind": "statusline", "session_id": payload["session_id"] ?? "", "rate_limits": payload["rate_limits"] ?? [:]]
    if let m = payload["model"] { line["model"] = m }
    if let w = payload["workspace"] { line["workspace"] = w }
    if let c = payload["cost"] { line["cost"] = c }
    _ = exchange(line, wait: false, timeout: 0.3)
    if let data = try? Data(contentsOf: previousStatusline), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let cmd = obj["command"] as? String, !cmd.isEmpty {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", cmd]
        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            inPipe.fileHandleForWriting.write(stdinData)
            try? inPipe.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(10)
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            while proc.isRunning, Date() < deadline { usleep(20_000) }
            if proc.isRunning { proc.terminate() }
            FileHandle.standardOutput.write(out)
        } catch {
            log("previous statusline failed: \(error)")
        }
    }
    exit(0)
}

guard stdinValid else {
    log("stdin is not a JSON object")
    if agentTag == "copilot" { emit(["permissionDecision": "ask"]) } else if ["gemini", "antigravity", "muse"].contains(agentTag ?? "") { emit([:] as [String: Any]) }
    exit(0)
}

if askMode {
    guard payload["tool_name"] as? String == "AskUserQuestion" else { exit(0) }
    payload["mochlet_kind"] = "ask_user_question"
    payload["mochlet_wait"] = true
    if let agentTag { payload["mochlet_agent"] = payload["mochlet_agent"] ?? agentTag }
    if payload["hook_event_name"] == nil { payload["hook_event_name"] = "PreToolUse" }
    addTerminalIdentity(&payload)
    normalizeToolFields(&payload)
    addSessionName(&payload)
    if let reply = exchange(payload, wait: true, timeout: 125), reply["permissionDecision"] as? String == "answer" {
        let questions = (payload["tool_input"] as? [String: Any])?["questions"] ?? []
        emit(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow",
                                     "updatedInput": ["questions": questions, "answers": reply["answers"] ?? [:]]]])
    }
    exit(0)
}

if let agentTag, payload["mochlet_agent"] == nil { payload["mochlet_agent"] = agentTag }
if (payload["mochlet_agent"] as? String ?? "").isEmpty, env["CLAUDE_CODE_ENTRYPOINT"] == "claude-desktop" { payload["mochlet_agent"] = "claude-desktop" }
addTerminalIdentity(&payload)
normalizeToolFields(&payload)
addSessionName(&payload)
let rawEvent = (payload["hook_event_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? eventArg ?? ""
let event = normalizeEvent(rawEvent)
payload["hook_event_name"] = event
let agent = agentTag ?? ""

if event == "PermissionRequest", payload["tool_name"] as? String != "AskUserQuestion" {
    payload["mochlet_kind"] = "permission"
    payload["mochlet_wait"] = true
    let reply = exchange(payload, wait: true, timeout: 118)
    let decision = reply?["permissionDecision"] as? String
    let tool = payload["tool_name"] as? String ?? ""
    log("decision \(decision ?? "none") for \(tool)")
    switch agent {
    case "hermes":
        let mapped = decision == "allow" ? "once" : decision
        if let m = mapped, ["once", "always", "deny"].contains(m) { emit(["choice": m]) }
    case "copilot", "muse":
        switch decision {
        case "allow", "always": emit(["permissionDecision": "allow"])
        case "deny": emit(["permissionDecision": "deny"])
        default: if agent == "copilot" { emit(["permissionDecision": "ask"]) }
        }
    default:
        var out: [String: Any]?
        switch decision {
        case "allow", "always":
            var d: [String: Any] = ["behavior": "allow"]
            if decision == "always", agent != "codex" { d["updatedPermissions"] = payload["permission_suggestions"] ?? [] }
            if tool == "ExitPlanMode" {
                d["updatedInput"] = payload["tool_input"] ?? [:]
                if let mode = reply?["mode"] as? String, mode == "auto" || mode == "default" {
                    d["updatedPermissions"] = [["type": "setMode", "mode": mode, "destination": "session"]]
                }
            }
            out = d
        case "deny":
            out = ["behavior": "deny", "message": "Denied from Mochlet"]
        case "change_plan":
            out = ["behavior": "deny", "interrupt": true, "message": "The user wants to change the plan and will type the changes in the terminal."]
        default:
            out = nil
        }
        if let out { emit(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": out]]) }
    }
    exit(0)
}

_ = exchange(payload, wait: false, timeout: 0.3)
if agent == "antigravity", event == "PreToolUse" {
    emit(["decision": "ask"])
} else if ["gemini", "antigravity", "muse", "copilot"].contains(agent) {
    if agent == "copilot", event == "PermissionRequest" { emit(["permissionDecision": "ask"]) } else { emit([:] as [String: Any]) }
}
exit(0)
