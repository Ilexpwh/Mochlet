import Foundation

/// Which hosts an agent-initiated fetch may reach. A coding agent talking to Mochlet over MCP can ask
/// for a link to be chewed; it must not be able to use Mochlet to read loopback, link-local or private
/// services (a classic SSRF path), so every such URL and every redirect is checked here. Drops and
/// pasted links from the user are not gated: reading your own `localhost:3000` docs is fine.
enum HostPolicy {
    static func allows(_ url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return false }
        guard isPublicName(host) else { return false }
        return await resolvesPublic(host)
    }

    /// Name-level checks that need no lookup.
    static func isPublicName(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".home.arpa") || h.hasSuffix(".lan") { return false }
        if !h.contains(".") && !h.contains(":") { return false }      // bare intranet names
        if let v4 = IPv4(h) { return isPublic(v4) }
        if h.contains(":") { return isPublicV6(h) }
        return true
    }

    /// Every address the name resolves to must be public (DNS pointing a public name at 127.0.0.1 is the usual trick).
    static func resolvesPublic(_ host: String) async -> Bool {
        if IPv4(host) != nil || host.contains(":") { return isPublicName(host) }
        return await Task.detached(priority: .utility) { () -> Bool in
            var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return false }
            defer { freeaddrinfo(first) }
            var p: UnsafeMutablePointer<addrinfo>? = first
            var any = false
            while let a = p {
                defer { p = a.pointee.ai_next }
                guard let sa = a.pointee.ai_addr else { continue }
                any = true
                if sa.pointee.sa_family == sa_family_t(AF_INET) {
                    let v4 = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                    if !isPublic(v4) { return false }
                } else if sa.pointee.sa_family == sa_family_t(AF_INET6) {
                    let bytes = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
                    if !isPublicV6(bytes: bytes) { return false }
                }
            }
            return any
        }.value
    }

    static func IPv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let n = UInt8(p) else { return nil }
            v = v << 8 | UInt32(n)
        }
        return v
    }

    static func isPublic(_ v4: UInt32) -> Bool {
        func inRange(_ net: UInt32, _ bits: Int) -> Bool { (v4 >> (32 - bits)) == (net >> (32 - bits)) }
        if inRange(0x0A00_0000, 8) { return false }        // 10/8
        if inRange(0x7F00_0000, 8) { return false }        // 127/8
        if inRange(0xA9FE_0000, 16) { return false }       // 169.254/16
        if inRange(0xAC10_0000, 12) { return false }       // 172.16/12
        if inRange(0xC0A8_0000, 16) { return false }       // 192.168/16
        if inRange(0x6440_0000, 10) { return false }       // 100.64/10 (CGNAT)
        if inRange(0x0000_0000, 8) { return false }        // 0/8
        if inRange(0xC000_0000, 29) { return false }       // 192.0.0/29
        if v4 >= 0xE000_0000 { return false }              // multicast and reserved
        return true
    }

    static func isPublicV6(_ literal: String) -> Bool {
        let h = literal.lowercased()
        if h == "::1" || h == "::" { return false }
        if h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb") { return false }   // fe80::/10
        if h.hasPrefix("fc") || h.hasPrefix("fd") { return false }                                                  // fc00::/7
        if h.hasPrefix("::ffff:"), let v4 = IPv4(String(h.dropFirst(7))) { return isPublic(v4) }                   // mapped v4
        return true
    }

    static func isPublicV6(bytes b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b[0..<15].allSatisfy({ $0 == 0 }) { return false }                       // :: and ::1
        if b[0] == 0xfe, (b[1] & 0xc0) == 0x80 { return false }                      // fe80::/10
        if (b[0] & 0xfe) == 0xfc { return false }                                    // fc00::/7
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {         // ::ffff:a.b.c.d
            return isPublic(UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
        }
        return true
    }
}

/// Refuses redirects that leave the public internet when a fetch was requested by an agent.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectGuard()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url else { completionHandler(nil); return }
        Task { completionHandler(await HostPolicy.allows(url) ? request : nil) }
    }
}
