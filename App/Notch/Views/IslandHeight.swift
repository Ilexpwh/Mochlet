import SwiftUI
import MochletCore

/// A card that grows with its content reports its natural height; the island follows within
/// `NotchLayout.heightRange`. One reporter per card, read by `ExpandedContent`.
struct IslandHeightKey: PreferenceKey {
    static let defaultValue: [NotchView: Double] = [:]
    static func reduce(value: inout [NotchView: Double], nextValue: () -> [NotchView: Double]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func reportsIslandHeight(for view: NotchView) -> some View {
        modifier(IslandHeightReporter(view: view))
    }
}

private struct IslandHeightReporter: ViewModifier {
    let view: NotchView
    @State private var height: Double = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { h in
                if abs(height - h) > 0.5 { height = h }
            }
            .preference(key: IslandHeightKey.self, value: height > 0 ? [view: height] : [:])
    }
}
