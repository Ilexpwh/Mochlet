import Foundation

/// What changed, shown once per version in the notch after the greeting (and from Settings → General).
enum WhatsNew {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    struct Note {
        var version: String
        var title: String
        var lines: [String]
    }

    static let notes: [Note] = [
        Note(version: "2.0.0", title: "Mochlet 2.0, rebuilt from scratch", lines: [
            "A soft-body slime in the notch: hold it to talk, drop files on it to chew, drag it to any corner.",
            "One mini slime per coding-agent session: Claude Code, Codex, Gemini and seven more, approvals and questions in the island.",
            "A wiki-style knowledge base under ~/Mochlet/Knowledge with cited answers and an MCP server for your agents.",
            "Meeting notes with on-device transcription and speaker turns; AI signals with a daily digest.",
        ]),
    ]

    static var current: Note? { notes.first { $0.version == version } ?? notes.first }
}
