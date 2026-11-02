import AppKit
import ColorSync
import SwiftUI

struct CompanionDisplay: Identifiable, Equatable {
    let id: String
    let runtimeID: Int
    let name: String
    let hasNotch: Bool
    let isMain: Bool

    func matches(_ preference: String) -> Bool {
        preference == id || preference == "legacy:\(runtimeID)"
    }
    static func preferred(_ preference: String, in displays: [Self]) -> Self? {
        displays.first { $0.matches(preference) } ?? displays.first { $0.hasNotch }
            ?? displays.first { $0.isMain } ?? displays.first
    }
    @MainActor static func current(_ screens: [NSScreen]) -> [Self] {
        let mainID = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
        let displays = screens.enumerated().compactMap { index, screen -> Self? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let runtimeID = number.intValue
            let key: String
            if let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value) {
                key = "uuid:" + (CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String)
            } else { key = "session:\(runtimeID)" }
            return Self(id: key, runtimeID: runtimeID,
                        name: "\(index + 1) · \(screen.localizedName) · \(Int(screen.frame.width)) × \(Int(screen.frame.height))",
                        hasNotch: screen.safeAreaInsets.top > 0, isMain: runtimeID == mainID)
        }
        // Some virtual/identical displays may not expose a unique persistent UUID.
        let counts = Dictionary(grouping: displays, by: \.id).mapValues(\.count)
        return displays.map { display in
            guard counts[display.id] == 1 else {
                return Self(id: "session:\(display.runtimeID)", runtimeID: display.runtimeID,
                            name: display.name, hasNotch: display.hasNotch, isMain: display.isMain)
            }
            return display
        }
    }
}

struct CompanionDisplaySettings: View {
    @Bindable var model: AppModel
    private var savedDisplayMissing: Bool {
        !model.dockDisplayKey.isEmpty && !model.availableDisplays.contains { $0.matches(model.dockDisplayKey) }
    }
    var body: some View {
        Picker("Companion display", selection: $model.dockDisplayKey) {
            Text("Automatic · notch or main display").tag("")
            ForEach(model.availableDisplays) { display in Text(display.name).tag(display.id) }
            if savedDisplayMissing { Text("Saved display · disconnected").tag(model.dockDisplayKey) }
        }
        if savedDisplayMissing {
            Text("Using an available display for now. Mochlet will return to your saved display when it reconnects.")
                .font(.caption).foregroundStyle(.secondary)
        } else if model.dockDisplayKey.hasPrefix("session:") {
            Text("This display exposes only a temporary identity. Select it again if its identity changes after restart.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
