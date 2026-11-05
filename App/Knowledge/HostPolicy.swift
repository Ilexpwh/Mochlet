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
        if h.contains(":") { return isPublicV6(h) }
        if let v4 = IPv4(h) { return isPublic(v4) }
        // Other numeric spellings (octal "0177.0.0.1", decimal "2130706433", hex "0x7f000001", short "127.1") go through inet_aton.
        if h.allSatisfy({ $0.isNumber || $0 == "." || $0 == "x" || ("a"..."f").contains($0) }), h.first?.isNumber == true {
            var a = in_addr()
            if inet_aton(h, &a) == 1 { return isPublic(UInt32(bigEndian: a.s_addr)) }
        }
        return true
    }

    /// Every address the name resolves to must be public (DNS pointing a public name at 127.0.0.1 is the usual trick).
    static func resolvesPublic(_ host: String) async -> Bool {
        if host.contains(":") || host.first?.isNumber == true && host.allSatisfy({ $0.isNumber || $0 == "." || $0 == "x" || ("a"..."f").contains($0) }) {
            return isPublicName(host)     // a literal: no lookup to do
        }
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
            // Dotted decimal only: a leading zero ("0177") is octal to inet_aton and is left to it.
            guard !(p.count > 1 && p.first == "0"), let n = UInt8(p) else { return nil }
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

    /// An IPv6 literal (with or without brackets, with or without a zone) goes through inet_pton so
    /// every spelling ("0:0:0:0:0:0:0:1", "::ffff:7f00:1", "::1%lo0") lands in the same byte check.
    static func isPublicV6(_ literal: String) -> Bool {
        var h = literal.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let z = h.firstIndex(of: "%") { h = String(h[..<z]) }
        var addr = in6_addr()
        guard inet_pton(AF_INET6, h, &addr) == 1 else { return false }
        return isPublicV6(bytes: withUnsafeBytes(of: addr) { Array($0) })
    }

    static func isPublicV6(bytes b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        func v4(_ at: Int) -> UInt32 { UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3]) }
        if b[0..<15].allSatisfy({ $0 == 0 }) { return false }                       // :: and ::1
        if b[0] == 0xfe, (b[1] & 0xc0) == 0x80 { return false }                      // fe80::/10 link-local
        if b[0] == 0xfe, (b[1] & 0xc0) == 0xc0 { return false }                      // fec0::/10 site-local (deprecated)
        if (b[0] & 0xfe) == 0xfc { return false }                                    // fc00::/7 unique local
        if b[0] == 0xff { return false }                                             // ff00::/8 multicast
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff { return isPublic(v4(12)) }   // ::ffff:a.b.c.d mapped
        if b[0..<12].allSatisfy({ $0 == 0 }) { return isPublic(v4(12)) }             // ::a.b.c.d IPv4-compatible (deprecated)
        if b[0] == 0, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) { return isPublic(v4(12)) }   // 64:ff9b::/96 NAT64
        if b[0] == 0x20, b[1] == 0x02 { return isPublic(v4(2)) }                     // 2002::/16 6to4 embeds the v4 at bytes 2–5
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0, b[3] == 0 {                        // 2001::/32 Teredo: client v4 is bytes 12–15, inverted
            return isPublic(~v4(12)) && isPublic(v4(4))
        }
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0d, b[3] == 0xb8 { return false }  // 2001:db8::/32 documentation
        return true
    }
}

/// For an agent-requested fetch: refuses redirects that leave the public internet and, after the
/// connection, checks the address actually used (a public name can be re-pointed at 127.0.0.1 between
/// our lookup and the connection — DNS rebinding — so the response is discarded when that happened).
/// One instance per fetch; read `sawPrivateAddress` once the call returns.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var privateSeen = false
    var sawPrivateAddress: Bool { lock.withLock { privateSeen } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url else { completionHandler(nil); return }
        Task { completionHandler(await HostPolicy.allows(url) ? request : nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        for t in metrics.transactionMetrics {
            guard let addr = t.remoteAddress, !addr.isEmpty else { continue }
            let ok: Bool
            if addr.contains(":") { ok = HostPolicy.isPublicV6(addr) }
            else if let v4 = HostPolicy.IPv4(addr) { ok = HostPolicy.isPublic(v4) }
            else { ok = false }
            if !ok { lock.withLock { privateSeen = true } }
        }
    }
}
