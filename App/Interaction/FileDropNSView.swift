import AppKit

/// Drag destination for files, URLs and text, below the gesture view. `hitTest` returns nil so it
/// never steals mouse events; AppKit routes drags to it regardless. Port of Coucou (MIT).
final class FileDropNSView: NSView {
    var onDragEntered: ((CGPoint) -> Void)?
    var onDragUpdated: ((CGPoint) -> Void)?
    var onDragExited: (() -> Void)?
    var onDropped: (([URL], String?) -> Void)?
    /// Returns true when the point (window coordinates) is on the island.
    var accepts: ((CGPoint) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts?(sender.draggingLocation) ?? true else { return [] }
        onDragEntered?(sender.draggingLocation)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts?(sender.draggingLocation) ?? true else { return [] }
        onDragUpdated?(sender.draggingLocation)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            onDropped?(files, nil)
            return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            onDropped?(urls, nil)
            return true
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            onDropped?([], text)
            return true
        }
        return false
    }
}
