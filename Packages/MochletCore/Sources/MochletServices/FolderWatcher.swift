import CoreServices
import Foundation

/// FSEvents on one folder, coalesced: `onChange` gets the changed paths (relative) after a quiet period.
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let root: URL
    private let latency: TimeInterval
    private let coalesce: TimeInterval
    private let onChange: @Sendable ([String]) -> Void
    private var pending: Set<String> = []
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "mochlet.watcher", qos: .utility)

    public init(root: URL, latency: TimeInterval = 1, coalesce: TimeInterval = 2, onChange: @escaping @Sendable ([String]) -> Void) {
        self.root = root.standardizedFileURL
        self.latency = latency
        self.coalesce = coalesce
        self.onChange = onChange
    }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.noticed(Array(list.prefix(count)))
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }

    private func noticed(_ paths: [String]) {
        let prefix = root.path + "/"
        for p in paths {
            let standardized = (p as NSString).standardizingPath
            guard standardized.hasPrefix(prefix) else { continue }
            let rel = String(standardized.dropFirst(prefix.count))
            if rel.isEmpty { continue }
            let parts = rel.split(separator: "/")
            if parts.contains(where: { $0.hasPrefix(".") || $0 == ".obsidian" || $0 == ".git" }) { continue }
            pending.insert(rel)
        }
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + coalesce)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let batch = Array(self.pending).sorted()
            self.pending.removeAll()
            if !batch.isEmpty { self.onChange(batch) }
        }
        t.resume()
        timer = t
    }
}
