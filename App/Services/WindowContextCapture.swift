import AppKit
import ApplicationServices
import ScreenCaptureKit
import MochletCore

/// Turns another app's window into chat context: title (Accessibility when granted, else the
/// window list), the browser URL (AppleScript for the big browsers) and, when enabled and
/// permitted, a downscaled screenshot.
enum WindowContextCapture {
    static let browserScripts: [String: String] = [
        "com.apple.Safari": "tell application \"Safari\" to return URL of current tab of front window",
        "com.google.Chrome": "tell application \"Google Chrome\" to return URL of active tab of front window",
        "company.thebrowser.Browser": "tell application \"Arc\" to return URL of active tab of front window",
        "org.mozilla.firefox": "tell application \"Firefox\" to return URL of active tab of front window",
        "com.microsoft.edgemac": "tell application \"Microsoft Edge\" to return URL of active tab of front window",
        "com.brave.Browser": "tell application \"Brave Browser\" to return URL of active tab of front window",
    ]

    /// The frontmost other app's main window.
    @MainActor
    /// The window the user is looking at: the frontmost regular app's first window, or, when
    /// Mochlet itself was just activated (a URL, the menu bar), the topmost window of any other app.
    static func frontmostWindow() -> WindowProbe.TargetWindow? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me, front.activationPolicy == .regular,
           let w = WindowProbe.firstWindow(ofPID: front.processIdentifier) {
            return w
        }
        return WindowProbe.topmostWindow(excludingPID: me)
    }

    @MainActor
    static func capture(_ target: WindowProbe.TargetWindow, screenshot: Bool) async -> ChatAttachment {
        let running = NSRunningApplication(processIdentifier: target.pid)
        let bundleID = running?.bundleIdentifier ?? ""
        var title = target.title
        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(target.pid)
            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success, let windowRef {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(windowRef as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success, let t = titleRef as? String, !t.isEmpty {
                    title = t
                }
            }
        }
        var url: String?
        if let script = browserScripts[bundleID] {
            var error: NSDictionary?
            if let result = NSAppleScript(source: script)?.executeAndReturnError(&error), let s = result.stringValue, !s.isEmpty { url = s }
        }
        var lines = ["App: \(target.owner)"]
        if !title.isEmpty { lines.append("Window: \(title)") }
        if let url { lines.append("URL: \(url)") }
        var image: String?
        if screenshot, CGPreflightScreenCaptureAccess() {
            image = await screenshotBase64(windowID: target.windowID)
            if image != nil { lines.append("(A screenshot of the window is attached.)") }
        }
        let name = title.isEmpty ? target.owner : "\(target.owner) · \(OneLine.collapse(title, limit: 40))"
        return ChatAttachment(kind: .window, title: name, text: lines.joined(separator: "\n"), imageBase64: image)
    }

    private static func screenshotBase64(windowID: CGWindowID) async -> String? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = min(1.0, 1568.0 / max(window.frame.width, window.frame.height))
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
            return png.base64EncodedString()
        } catch {
            NSLog("window capture: \(error.localizedDescription)")
            return nil
        }
    }
}
