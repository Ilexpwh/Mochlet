import AppKit

/// Transparent, non-activating panel parked over the notch. The island is drawn at its top centre.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Let the panel sit in the menu bar area; macOS would otherwise push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
