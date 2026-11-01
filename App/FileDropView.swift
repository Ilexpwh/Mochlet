// Adapted from Coucou FileDropNSView, b6a85f2.
// Copyright (c) 2026 Louis Raillé. MIT; see LICENSES/Coucou-MIT.txt.
import AppKit
import SwiftUI

final class FileDropNSView: NSView {
    var acceptsPoint: ((CGPoint) -> Bool)?
    var hover: ((Bool) -> Void)?
    var receive: (([URL]) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = acceptsPoint?(sender.draggingLocation) ?? true
        hover?(accepted); return accepted ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { hover?(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hover?(false) }
        guard acceptsPoint?(sender.draggingLocation) ?? true,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        receive?(urls); return true
    }
}
struct FileDropSurface: NSViewRepresentable {
    let receive: ([URL]) -> Void
    func makeNSView(context: Context) -> FileDropNSView { let view = FileDropNSView(); view.receive = receive; return view }
    func updateNSView(_ nsView: FileDropNSView, context: Context) { nsView.receive = receive }
}
