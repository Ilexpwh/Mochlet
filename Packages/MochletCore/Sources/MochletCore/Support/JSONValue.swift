import Foundation

/// A Sendable JSON tree, so hook payloads can cross actors and sit in stores.
public enum JSONValue: Sendable, Equatable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        // NSNumber first: a Swift `as Bool` would also match the numbers 0 and 1.
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .number(Double(i))
        case let d as Double: self = .number(d)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    public static func parse(_ text: String) -> JSONValue? { parse(Data(text.utf8)) }

    public static func parse(_ data: Data) -> JSONValue? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: obj)
    }

    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) as Any : n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    public func data(pretty: Bool = false, sortedKeys: Bool = true) -> Data {
        var opts: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        if sortedKeys { opts.insert(.sortedKeys) }
        return (try? JSONSerialization.data(withJSONObject: any, options: opts)) ?? Data()
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? { number.map { Int($0) } }
    public var double: Double? { number }
    public var bool: Bool? { if case .bool(let b) = self { return b }; if case .number(let n) = self { return n != 0 }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }
    public var isEmptyish: Bool {
        switch self {
        case .null: return true
        case .string(let s): return s.isEmpty
        case .array(let a): return a.isEmpty
        case .object(let o): return o.isEmpty
        default: return false
        }
    }

    public subscript(key: String) -> JSONValue {
        get { object?[key] ?? .null }
        set {
            var o = object ?? [:]
            o[key] = newValue
            self = .object(o)
        }
    }

    public subscript(index: Int) -> JSONValue {
        guard let a = array, index >= 0, index < a.count else { return .null }
        return a[index]
    }

    /// Dotted path lookup: `rate_limits.five_hour.used_percentage`.
    public func path(_ p: String) -> JSONValue {
        p.split(separator: ".").reduce(self) { $0[String($1)] }
    }

    /// First non-empty string among the keys.
    public func firstString(_ keys: [String]) -> String? {
        for k in keys { if let s = self[k].string, !s.isEmpty { return s } }
        return nil
    }
}
