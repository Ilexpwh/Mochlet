import AppKit
import SwiftUI
import simd
import SlimeKit
import SlimeKitUI
import SlimeKitAudio

/// Settings → Character: a live slime to poke, then its look, colour, sounds and motion.
struct CharacterSettingsView: View {
    let app: AppCoordinator
    let preview: CharacterPreviewModel

    private static let paletteColumns = [GridItem(.adaptive(minimum: 36), spacing: 8)]
    private static let lookColumns = [GridItem(.adaptive(minimum: 84), spacing: 6)]

    var body: some View {
        @Bindable var s = app.settings
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    CharacterPreview(model: preview)
                        .frame(width: 210, height: 150)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Move over it, poke it, hold it. Changes below apply straight away to the slime in the notch and its minis.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        FlowLayout(spacing: 4) {
                            ForEach(SlimeEmote.allCases, id: \.self) { e in
                                Button(e.rawValue) { preview.stage.main.trigger(e) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                            Button("greet") { preview.stage.main.greet() }.buttonStyle(.bordered).controlSize(.small)
                            Button("chew") { preview.chew() }.buttonStyle(.bordered).controlSize(.small)
                            Button("sleep") { preview.stage.main.sleepNow() }.buttonStyle(.bordered).controlSize(.small)
                            Button("mini") { preview.toggleMini() }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
            Section("Look") {
                LazyVGrid(columns: Self.lookColumns, alignment: .leading, spacing: 6) {
                    ForEach(SlimeLook.names, id: \.self) { name in
                        LookChip(name: name, palette: s.character.palette, selected: s.character.lookName == name) {
                            s.character.selectLook(name)
                        }
                    }
                }
            }
            Section("Outfit") {
                LazyVGrid(columns: Self.lookColumns, alignment: .leading, spacing: 6) {
                    ForEach(SlimeOutfit.sets) { set in
                        OutfitChip(set: set, look: s.character.resolvedLook, palette: s.character.palette, selected: s.character.outfit == set.outfit) {
                            s.character.outfit = set.outfit
                        }
                    }
                }
                Picker("Headwear", selection: $s.character.outfit.headwear) {
                    ForEach(SlimeOutfit.Headwear.allCases, id: \.self) { Text(Wardrobe.label($0.rawValue)).tag($0) }
                }
                Picker("Eyewear", selection: $s.character.outfit.eyewear) {
                    ForEach(SlimeOutfit.Eyewear.allCases, id: \.self) { Text(Wardrobe.label($0.rawValue)).tag($0) }
                }
                Picker("Wrap", selection: $s.character.outfit.wrap) {
                    ForEach(SlimeOutfit.Wrap.allCases, id: \.self) { Text(Wardrobe.label($0.rawValue)).tag($0) }
                }
                Picker("Charm", selection: $s.character.outfit.charm) {
                    ForEach(SlimeOutfit.Charm.allCases, id: \.self) { Text(Wardrobe.label($0.rawValue)).tag($0) }
                }
                Toggle("Dress for the occasion", isOn: $s.character.dressForOccasion)
                Text("Reading glasses while it eats a file, a nightcap when it sleeps; never saved to the outfit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Colour") {
                LazyVGrid(columns: Self.paletteColumns, alignment: .leading, spacing: 8) {
                    ForEach(SlimeTheme.all, id: \.name) { t in
                        PaletteSwatch(theme: t, selected: s.character.paletteName == t.name)
                            .onTapGesture { s.character.selectPalette(t.name) }
                            .help(t.name.capitalized)
                    }
                    PaletteSwatch(theme: s.character.palette, selected: s.character.paletteName == "custom", custom: true)
                        .onTapGesture { s.character.setCustom() }
                        .help("Custom")
                }
                labelledSlider("Hue", value: Binding(get: { s.character.hue }, set: { s.character.setCustom(hue: $0) }), in: 0...360, text: "\(Int(s.character.hue))°")
                labelledSlider("Saturation", value: Binding(get: { s.character.saturation }, set: { s.character.setCustom(saturation: $0) }), in: 0...1, text: "\(Int(s.character.saturation * 100)) %")
                labelledSlider("Lightness", value: Binding(get: { s.character.lightness }, set: { s.character.setCustom(lightness: $0) }), in: 0.12...0.9, text: "\(Int(s.character.lightness * 100)) %")
                Toggle("Minis a shade lighter", isOn: $s.character.lighterMinis)
            }
            Section("Sounds") {
                Toggle("Sounds", isOn: $s.soundEnabled).onChange(of: s.soundEnabled) { _, _ in app.applySettings() }
                HStack {
                    Slider(value: $s.soundVolume, in: 0...1) { Text("Volume") }
                        .onChange(of: s.soundVolume) { _, _ in app.applySettings() }
                    Button("Test") { app.slime.sound.play(SoundCue(.greet)) }
                }
            }
            Section("Motion") {
                Picker("Motion", selection: Binding(get: { s.reduceMotionOverride.map { $0 ? "on" : "off" } ?? "system" },
                                                    set: { s.reduceMotionOverride = $0 == "system" ? nil : ($0 == "on"); app.applySettings() })) {
                    Text("Follow system Reduce Motion").tag("system")
                    Text("Full motion").tag("off")
                    Text("Reduced motion").tag("on")
                }
                Stepper("Visible mini slimes: \(s.maxVisibleMinis)", value: $s.maxVisibleMinis, in: 2...6)
                    .onChange(of: s.maxVisibleMinis) { _, _ in app.applySettings() }
            }
        }
        .formStyle(.grouped)
        .onChange(of: s.character) { _, c in
            preview.apply(c)
            app.applySettings()
        }
        .onAppear {
            preview.apply(s.character)
            preview.stage.reduceMotion = app.slime.stage.reduceMotion
        }
    }

    private func labelledSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, text: String) -> some View {
        HStack {
            Slider(value: value, in: range) { Text(title) }
            Text(text).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
    }
}

/// One palette as a gradient disc.
struct PaletteSwatch: View {
    let theme: SlimeTheme
    let selected: Bool
    var custom = false

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(theme.core), Color(theme.mid), Color(theme.rim)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if custom {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(theme.ink))
            }
            Circle().strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
        }
        .frame(width: 34, height: 34)
        .contentShape(Circle())
        .accessibilityLabel(custom ? "Custom colour" : theme.name.capitalized)
    }
}

/// A look preset as a selectable chip.
/// A look preset as a live thumbnail in the current colour, with its name underneath.
struct LookChip: View {
    let name: String
    let palette: SlimeTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Group {
                    if let image = LookThumbnails.shared.image(for: name, palette: palette) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 46)
                Text(SlimeLook.label(name))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(SlimeLook.label(name))
    }
}

/// An outfit set as a thumbnail of the current look wearing it.
struct OutfitChip: View {
    let set: SlimeOutfit.Set
    let look: SlimeLook
    let palette: SlimeTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Group {
                    if let image = LookThumbnails.shared.image(for: look, palette: palette, outfit: set.outfit) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 46)
                Text(set.label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(set.label)
    }
}

enum Wardrobe {
    /// "royalCape" → "Royal cape".
    static func label(_ raw: String) -> String {
        if raw == "none" { return "None" }
        var out = ""
        for ch in raw {
            if ch.isUppercase { out += " " + ch.lowercased() } else { out.append(ch) }
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}

/// Look thumbnails rendered once per look and palette (a settled slime at R 16, 2× backing).
@MainActor
final class LookThumbnails {
    static let shared = LookThumbnails()
    private var images: [String: NSImage] = [:]

    func image(for name: String, palette: SlimeTheme) -> NSImage? {
        image(for: SlimeLook.named(name), palette: palette, outfit: SlimeOutfit())
    }

    func image(for look: SlimeLook, palette: SlimeTheme, outfit: SlimeOutfit) -> NSImage? {
        let key = "\(look.name)|\(look.presetName ?? "custom")|\(palette.mid.hex)|\(palette.core.hex)|\(palette.ink.hex)|\(outfit.headwear)|\(outfit.eyewear)|\(outfit.wrap)|\(outfit.charm)"
        if let cached = images[key] { return cached }
        guard let cg = Catalog.thumbnail(look: look, palette: palette, outfit: outfit, radius: 16, scale: 2) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        if images.count > 150 { images.removeAll() }
        images[key] = image
        return image
    }
}

// MARK: - Live preview

/// Owns the stage behind the Character tab's preview: its own slime, independent of the notch,
/// drawn with the configuration being edited.
@MainActor
final class CharacterPreviewModel {
    let stage: SlimeStage
    private var miniID: String?

    init() {
        stage = SlimeStage(seed: 11)
        stage.main.greet()
    }

    func apply(_ c: CharacterConfig) {
        stage.appearance = c.appearance
    }

    func chew() {
        stage.main.drop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated { self?.stage.main.ingestionFinished(success: true) }
        }
    }

    func toggleMini() {
        if let id = miniID {
            stage.removeMini(id)
            miniID = nil
        } else if stage.spawnMini(id: "preview") != nil {
            miniID = "preview"
            stage.setMiniState("preview", .working)
        }
    }
}

struct CharacterPreview: NSViewRepresentable {
    let model: CharacterPreviewModel

    func makeNSView(context: Context) -> CharacterPreviewHostView {
        CharacterPreviewHostView(stage: model.stage)
    }

    func updateNSView(_ view: CharacterPreviewHostView, context: Context) {}
}

/// A dark rounded card with the preview stage, hover tracking and press handling (the notch
/// island's hit view in miniature).
final class CharacterPreviewHostView: NSView {
    private let stage: SlimeStage
    private let slimeView: SlimeStageLayerView
    private var pointer: CGPoint?
    private var pressing = false
    private static let radius: CGFloat = 46

    init(stage: SlimeStage) {
        self.stage = stage
        slimeView = SlimeStageLayerView(stage: stage, radius: Self.radius, origin: { size in
            CGPoint(x: size.width / 2, y: size.height - 16)
        })
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1).cgColor
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        slimeView.pointer = { [weak self] in self?.pointer }
        slimeView.idleInterval = 1.0 / 30.0
        slimeView.include = { $0.id != "ghost" }
        slimeView.autoresizingMask = [.width, .height]
        addSubview(slimeView)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        slimeView.frame = bounds
        slimeView.invalidate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        slimeView.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func local(_ event: NSEvent) -> SIMD2<Double> {
        let p = convert(event.locationInWindow, from: nil)
        let o = slimeView.origin(bounds.size)
        return SIMD2(Double((p.x - o.x) / Self.radius), Double((p.y - o.y) / Self.radius))
    }

    override func mouseMoved(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil) }
    override func mouseEntered(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil) }
    override func mouseExited(with event: NSEvent) { pointer = nil }

    override func mouseDown(with event: NSEvent) {
        let l = local(event)
        switch stage.hitTest(l) {
        case .main:
            pressing = true
            stage.main.pressBegan(at: l)
        case .mini(let id):
            stage.mini(id)?.engine.pressBegan(at: SIMD2(0, -0.9))
        case .none:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        guard pressing else { return }
        stage.main.pressMoved(to: local(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard pressing else { return }
        pressing = false
        stage.main.pressEnded()
    }
}
