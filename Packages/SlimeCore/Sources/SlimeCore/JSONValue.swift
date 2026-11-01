import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String:JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String:JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c=encoder.singleValueContainer()
        switch self { case .object(let v): try c.encode(v);case .array(let v):try c.encode(v);case .string(let v):try c.encode(v);case .number(let v):try c.encode(v);case .bool(let v):try c.encode(v);case .null:try c.encodeNil() }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let v)=self {return v[key] ?? .null};return .null }
    public var string: String? { if case .string(let v)=self{return v};return nil }
    public var array: [JSONValue] { if case .array(let v)=self{return v};return [] }
    public var object: [String:JSONValue] { if case .object(let v)=self{return v};return [:] }
    public var number: Double? { if case .number(let v)=self{return v};return nil }
    public var formatted: String { guard let d=try? JSONEncoder.pretty.encode(self) else{return ""};return String(decoding:d,as:UTF8.self) }
}
extension JSONEncoder { static var pretty: JSONEncoder { let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];return e } }

public struct JSONLineFramer: Sendable {
    private var buffer=Data()
    public let limit: Int
    public init(limit: Int = 8 * 1024 * 1024) { self.limit=limit }
    public mutating func append(_ data: Data) throws -> [JSONValue] {
        buffer.append(data);var frames:[JSONValue]=[]
        while let index=buffer.firstIndex(of:10) {
            guard buffer.distance(from:buffer.startIndex,to:index) <= limit else { throw MochletError.message("Agent frame exceeded the buffer limit.") }
            let frame=buffer.prefix(upTo:index);buffer.removeSubrange(...index)
            if !frame.isEmpty { frames.append(try JSONDecoder().decode(JSONValue.self,from:frame)) }
        }
        guard buffer.count <= limit else { throw MochletError.message("Agent frame exceeded the buffer limit.") }
        return frames
    }
    public var hasPartialFrame: Bool { !buffer.isEmpty }
}
