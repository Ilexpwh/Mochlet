import AppKit
import SwiftUI

/// Render the app's own character into every traditional macOS icon size.
/// Build with SlimeView.swift so the application and icon share one silhouette.
@main @MainActor struct MakeIcon {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Supply the AppIcon.appiconset directory") }
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var entries: [[String: String]] = []
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let icon = ZStack {
                    RoundedRectangle(cornerRadius: 196, style: .continuous)
                        .fill(Color(red: 0.10, green: 0.14, blue: 0.13))
                        .overlay { RoundedRectangle(cornerRadius: 196, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 3) }
                        .frame(width: 896, height: 896)
                    SlimeView(animated: false).frame(width: 790, height: 790).offset(y: -8)
                }.frame(width: 1024, height: 1024)
                let renderer = ImageRenderer(content: icon); renderer.scale = CGFloat(pixels) / 1024
                guard let image = renderer.cgImage else { fatalError("Icon rendering failed") }
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
                let file = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                try data.write(to: folder.appendingPathComponent(file))
                entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": file])
            }
        }
        let json: [String: Any] = ["images": entries, "info": ["version": 1, "author": "Mochlet"]]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("Contents.json"))
    }
}
