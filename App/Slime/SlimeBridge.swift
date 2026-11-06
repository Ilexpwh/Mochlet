import AppKit
import SwiftUI
import simd
import SlimeKit
import SlimeKitUI
import SlimeKitAudio
import MochletCore

/// The only owner of SlimeKit in the app: the stage, the sound engine, the live radius and
/// the pointer feed. Everything else talks to the slime through here.
@MainActor
final class SlimeBridge {
    let stage: SlimeStage
    let sound: SoundEngine
    let probe = PerfProbe()
    /// Pointer in island coordinates (y down from the island's top-left), nil when away.
    var pointer: CGPoint?
    /// Current slime radius in points (the window controller springs it toward `targetRadius`).
    var radius: CGFloat = 15
    private(set) var targetRadius: CGFloat = 15
    var onEvent: ((SlimeEvent) -> Void)?
    var onMiniEvent: ((String, SlimeEvent) -> Void)?

    init(seed: UInt64 = UInt64(Date().timeIntervalSince1970) & 0xFFFF) {
        stage = SlimeStage(seed: seed)
        sound = SoundEngine()
        stage.onEvent = { [weak self] e in self?.onEvent?(e) }
        stage.onMiniEvent = { [weak self] id, e in self?.onMiniEvent?(id, e) }
    }

    func apply(settings: SettingsStore) {
        stage.appearance = settings.character.appearance
        stage.maxVisibleMinis = settings.maxVisibleMinis
        stage.reduceMotion = settings.reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        sound.isEnabled = settings.soundEnabled
        sound.masterVolume = settings.soundVolume
    }

    /// Called when the island changes mode: the slime grows in the expanded island and the mini
    /// row skips over the physical notch while compact.
    func apply(mode: NotchMode, layout: NotchLayout) {
        targetRadius = CGFloat(layout.slimeRadius(mode: mode))
        let offsetPoints = layout.miniSlotOffset(mode: mode)
        stage.slotOffset = offsetPoints / Double(targetRadius)
        let m = layout.miniLayout(mode: mode)
        stage.miniLayout = SlimeStage.MiniLayout(scale: m.scale, firstSlot: m.firstSlot, pitch: m.pitch, perRow: m.perRow)
    }

    /// Island-local point (points, y down) → main R units relative to the main contact point.
    func toStage(_ p: CGPoint, origin: CGPoint) -> SIMD2<Double> {
        SIMD2(Double((p.x - origin.x) / radius), Double((p.y - origin.y) / radius))
    }
}
