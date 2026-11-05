import Foundation
import Darwin

/// One JSON line received from the relay. `reply` is non-nil when the relay said it will wait
/// (`"mochlet_wait": true`): the connection stays open until `send` or `close`, and
/// `onHangup` fires if the agent gives up first (the user answered in the terminal).
struct HookLine: Sendable {
    let data: Data
    let receivedAt: Date
    let reply: HookReply?
}

/// Reply handle for a blocking hook: writes one JSON line and closes the socket.
final class HookReply: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var hangupSource: DispatchSourceRead?
    var onHangup: (@Sendable () -> Void)?

    init(fd: Int32) {
        self.fd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .utility))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var byte: UInt8 = 0
            let n = recv(self.fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                self.hangupSource?.cancel()
                self.hangupSource = nil
                let hangup = self.closeIfNeeded()
                if hangup { self.onHangup?() }
            }
        }
        src.resume()
        hangupSource = src
    }

    /// Writes the reply (one line) and closes. Returns false if the agent had already hung up.
    @discardableResult
    func send(_ object: [String: Any]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        closed = true
        hangupSource?.cancel()
        hangupSource = nil
        if var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            data.append(0x0A)
            data.withUnsafeBytes { buf in
                var off = 0
                while off < buf.count {
                    let n = Darwin.send(fd, buf.baseAddress! + off, buf.count - off, 0)
                    if n <= 0 { break }
                    off += n
                }
            }
        }
        Darwin.close(fd)
        return true
    }

    /// Closes without a reply (the agent then falls back to its own prompt).
    func close() {
        _ = closeIfNeeded()
    }

    private func closeIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        closed = true
        hangupSource?.cancel()
        hangupSource = nil
        Darwin.close(fd)
        return true
    }

    deinit { close() }
}

/// Unix-domain socket the `mochlet-hook` relay connects to. One JSON line per connection;
/// the peer must be our own uid; 32 pending connections; 5 s receive timeout; 1 MB line cap.
final class HookSocketServer: @unchecked Sendable {
    static let socketPath: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mochlet/mochlet.sock").path
    }()
    static let maxLineBytes = 1_000_000
    static let backlog: Int32 = 32
    static let receiveTimeout: TimeInterval = 5

    private let onLine: @Sendable (HookLine) -> Void
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "com.ilexpwh.Mochlet.hooks.accept")
    private let connectionQueue = DispatchQueue(label: "com.ilexpwh.Mochlet.hooks.connections", attributes: .concurrent)
    private let state = NSLock()
    private var running = false
    private(set) var acceptedCount = 0
    private(set) var rejectedCount = 0

    init(onLine: @escaping @Sendable (HookLine) -> Void) {
        self.onLine = onLine
        signal(SIGPIPE, SIG_IGN)
    }

    var isRunning: Bool { state.withLock { running } }

    func start() throws {
        try state.withLock {
            guard !running else { return }
            let path = Self.socketPath
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ServerError.socket(errno) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw ServerError.pathTooLong }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                for (i, b) in bytes.enumerated() { raw[i] = b }
                raw[bytes.count] = 0
            }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
            }
            guard bound == 0 else { Darwin.close(fd); throw ServerError.bind(errno) }
            chmod(path, 0o600)
            guard listen(fd, Self.backlog) == 0 else { Darwin.close(fd); throw ServerError.listen(errno) }
            listenFD = fd
            running = true
            acceptQueue.async { [self] in acceptLoop(fd) }
        }
    }

    func stop() {
        state.withLock {
            guard running else { return }
            running = false
            if listenFD >= 0 { Darwin.close(listenFD) }
            listenFD = -1
            unlink(Self.socketPath)
        }
    }

    private func acceptLoop(_ listenFD: Int32) {
        while true {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let fd = accept(listenFD, &addr, &len)
            if fd < 0 {
                if errno == EINTR { continue }
                return  // closed
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            if getpeereid(fd, &uid, &gid) != 0 || uid != getuid() {
                state.withLock { rejectedCount += 1 }
                Darwin.close(fd)
                continue
            }
            var tv = timeval(tv_sec: Int(Self.receiveTimeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            state.withLock { acceptedCount += 1 }
            connectionQueue.async { [self] in handle(fd) }
        }
    }

    private func handle(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        var complete = false
        while !complete {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > Self.maxLineBytes { Darwin.close(fd); return }
            if let nl = buffer.firstIndex(of: 0x0A) {
                buffer = buffer.prefix(upTo: nl)
                complete = true
            }
        }
        guard complete || !buffer.isEmpty else { Darwin.close(fd); return }
        let waits = Self.wantsReply(buffer)
        let reply = waits ? HookReply(fd: fd) : nil
        if !waits { Darwin.close(fd) }
        onLine(HookLine(data: buffer, receivedAt: Date(), reply: reply))
    }

    /// Cheap check for `"mochlet_wait": true` without a full parse of a possibly large line.
    static func wantsReply(_ data: Data) -> Bool {
        guard let range = data.range(of: Data("\"mochlet_wait\"".utf8)) else { return false }
        let tail = data[range.upperBound..<min(data.endIndex, range.upperBound + 12)]
        return String(decoding: tail, as: UTF8.self).contains("true")
    }

    enum ServerError: Error { case socket(Int32), bind(Int32), listen(Int32), pathTooLong }
}
