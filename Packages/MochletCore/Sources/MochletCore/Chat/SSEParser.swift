import Foundation

public struct SSEEvent: Equatable, Sendable {
    public var event: String?
    public var data: String
    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental Server-Sent Events parser: feed chunks, get complete events.
public struct SSEParser: Sendable {
    private var buffer = ""
    private var event: String?
    private var dataLines: [String] = []

    public init() {}

    public mutating func feed(_ chunk: String) -> [SSEEvent] {
        // "\r\n" is one Character in Swift, so normalise before searching for line ends.
        buffer = (buffer + chunk).replacingOccurrences(of: "\r\n", with: "\n")
        var out: [SSEEvent] = []
        while let nl = buffer.firstIndex(of: "\n") {
            var line = String(buffer[..<nl])
            buffer = String(buffer[buffer.index(after: nl)...])
            if line.hasSuffix("\r") { line.removeLast() }
            if let e = consume(line: line) { out.append(e) }
        }
        return out
    }

    /// Call when the stream ends: a last event without a trailing blank line.
    public mutating func finish() -> [SSEEvent] {
        var out: [SSEEvent] = []
        if !buffer.isEmpty, let e = consume(line: buffer) { out.append(e) }
        buffer = ""
        if let e = flush() { out.append(e) }
        return out
    }

    private mutating func consume(line: String) -> SSEEvent? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }
        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }
        switch field {
        case "event": event = value
        case "data": dataLines.append(value)
        default: break
        }
        return nil
    }

    private mutating func flush() -> SSEEvent? {
        guard !dataLines.isEmpty || event != nil else { return nil }
        let e = SSEEvent(event: event, data: dataLines.joined(separator: "\n"))
        event = nil
        dataLines = []
        return dataLines.isEmpty && e.data.isEmpty && e.event == nil ? nil : e
    }
}
