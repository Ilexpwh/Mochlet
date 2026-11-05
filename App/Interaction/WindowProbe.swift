import AppKit

/// Which other app's window is under a screen point (for attaching window context).
enum WindowProbe {
    struct TargetWindow: Equatable {
        var pid: pid_t
        var owner: String
        var title: String
        /// AppKit screen coordinates.
        var bounds: CGRect
    }

    static func windowUnder(_ p: NSPoint) -> TargetWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: p.x, y: mainHeight - p.y)
        let me = ProcessInfo.processInfo.processIdentifier
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 40, height > 40 else { continue }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            guard rect.contains(cgPoint) else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? "window"
            let title = w[kCGWindowName as String] as? String ?? ""
            let appKitRect = CGRect(x: x, y: mainHeight - y - height, width: width, height: height)
            return TargetWindow(pid: pid, owner: owner, title: title, bounds: appKitRect)
        }
        return nil
    }

    /// The screen whose frame contains `p`, else the one with the menu bar.
    static func screen(containing p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
