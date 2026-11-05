#if DEBUG
import SwiftUI
import AppKit
import simd
import SlimeKit

/// Debug playground: two live canvases (R 96 and notch-size R 22), every tunable as a slider,
/// buttons for all states, emotes, impulses and stage choreography, slow motion, scripts and filmstrips.
@MainActor
@Observable
public final class EmoteLabModel {
    public private(set) var stage: SlimeStage
    public let probe = PerfProbe()
    public var params: SoftBodyParams
    public var breathAmplitude = 0.02
    public var breathRate = 0.21
    public var rig: EyeRig
    public var yawGain = 0.62
    public var pitchGain = 0.50
    public var gazeTau = 0.17
    public var timeScale = 1.0 { didSet { stage.timeScale = timeScale } }
    public var themeName = "rimuru" { didSet { stage.theme = SlimeTheme.named(themeName) } }
    public var seed = 7
    public var audioLevel = 0.0 { didSet { stage.main.setAudioLevel(audioLevel) } }
    public var reduceMotion = false { didSet { stage.reduceMotion = reduceMotion } }
    public var paused = false
    public var script = "0:greet,2.2:click,3.4:emote:happy"
    public var status = "ready"
    public var pointer: CGPoint?
    public var lastEvent = ""
    private var sessionCounter = 0
    private var holdTask: Task<Void, Never>?

    public init(seed: Int = 7) {
        self.seed = seed
        let s = SlimeStage(seed: UInt64(seed))
        stage = s
        params = s.main.bodyParams
        rig = s.main.eyeRig
        hook()
    }

    private func hook() {
        stage.onEvent = { [weak self] e in self?.lastEvent = "\(e)" }
        stage.onMiniEvent = { [weak self] id, e in self?.lastEvent = "\(id): \(e)" }
    }

    public func applyParams() {
        for e in [stage.main] + stage.minis.map(\.engine) {
            if e.profile.kind == .main {
                e.bodyParams = params
                e.eyeRig = rig
            }
            e.setBreath(amplitude: breathAmplitude, rate: breathRate, duration: 0.2)
            e.gaze.yawGain = yawGain
            e.gaze.pitchGain = pitchGain
            e.gaze.tau = gazeTau
        }
    }

    public func reset() {
        let s = SlimeStage(seed: UInt64(seed), theme: SlimeTheme.named(themeName), reduceMotion: reduceMotion)
        s.timeScale = timeScale
        stage = s
        hook()
        applyParams()
        status = "reset with seed \(seed)"
    }

    public func pinchSession() {
        sessionCounter += 1
        let id = "s\(sessionCounter)"
        stage.spawnMini(id: id)
        status = "pinched \(id)"
    }

    public func endLastSession() {
        guard let m = stage.minis.last(where: { $0.phase != .merging }) else { return }
        stage.removeMini(m.id)
        status = "ended \(m.id)"
    }

    public func holdForOneSecond() {
        holdTask?.cancel()
        stage.main.pressBegan(at: SIMD2(0.1, -0.9))
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.stage.main.pressEnded()
        }
    }

    public func fiveClicks() {
        for _ in 0..<5 {
            stage.main.pressBegan(at: SIMD2(0.1, -0.9))
            stage.main.pressEnded()
        }
    }

    public func dragGhostDemo() {
        stage.beginDragOut(at: SIMD2(0.2, -1))
        let path: [SIMD2<Double>] = [SIMD2(1.5, -2.5), SIMD2(3.5, -3.2), SIMD2(5, -2.4), SIMD2(5.5, -1.2)]
        let base = stage.main.time
        for (i, p) in path.enumerated() {
            stage.main.scheduler.schedule(at: base + 0.25 * Double(i + 1), tag: "lab") { [weak self] in
                self?.stage.updateDragOut(target: p)
            }
        }
        stage.main.scheduler.schedule(at: base + 0.25 * Double(path.count + 1), tag: "lab") { [weak self] in
            self?.stage.endDragOut(dropped: false)
        }
    }

    public func runScript() {
        let actions = Filmstrip.parseScript(script)
        let base = stage.main.time
        stage.main.scheduler.cancel(tag: "lab")
        for (t, a) in actions {
            stage.main.scheduler.schedule(at: base + t, tag: "lab") { [weak self] in
                guard let self else { return }
                _ = Filmstrip.applyAction(a, to: self.stage)
            }
        }
        status = "script: \(actions.count) actions"
    }

    public struct ParamsDump: Codable {
        public var body: SoftBodyParams
        public var breathAmplitude: Double
        public var breathRate: Double
        public var eyeRig: EyeRig
        public var yawGain: Double
        public var pitchGain: Double
        public var gazeTau: Double
        public var theme: String
    }

    public func paramsJSON() -> String {
        let d = ParamsDump(body: params, breathAmplitude: breathAmplitude, breathRate: breathRate, eyeRig: rig,
                           yawGain: yawGain, pitchGain: pitchGain, gazeTau: gazeTau, theme: themeName)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(d)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public func copyParams() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paramsJSON(), forType: .string)
        status = "params copied"
    }

    public func renderFilmstrip() {
        var o = FilmstripOptions()
        o.script = script
        o.seed = UInt64(seed)
        o.theme = SlimeTheme.named(themeName)
        o.reduceMotion = reduceMotion
        o.widthR = 8
        o.originX = 0.25
        o.frames = 48
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slimekit-lab", isDirectory: true)
            .appendingPathComponent(String(Int(Date().timeIntervalSince1970)), isDirectory: true)
        do {
            let r = try Filmstrip.render(o)
            try Filmstrip.write(r, to: dir)
            status = "filmstrip → \(dir.path)"
            NSWorkspace.shared.open(dir.appendingPathComponent("contact.png"))
        } catch {
            status = "filmstrip failed: \(error.localizedDescription)"
        }
    }
}

public struct EmoteLabView: View {
    @State private var model: EmoteLabModel
    private let sink: SoundSink?

    public init(sink: SoundSink? = nil, seed: Int = 7) {
        self.sink = sink
        _model = State(initialValue: EmoteLabModel(seed: seed))
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                bigCanvas
                smallCanvas
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text("\(model.probe.summary) · \(model.stage.main.state.rawValue)\(model.stage.main.emote.map { " +\($0.rawValue)" } ?? "") · minis \(model.stage.minis.count) · \(model.lastEvent)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(model.status).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(width: 600)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    actionsSection
                    stageSection
                    scriptSection
                    tuningSection
                }
                .padding(.trailing, 8)
            }
        }
        .padding(12)
        .frame(minWidth: 1100, minHeight: 680)
    }

    private var bigCanvas: some View {
        SlimeStageView(stage: model.stage, radius: 96, paused: model.paused, sink: sink, probe: model.probe,
                       origin: { size in CGPoint(x: size.width * 0.32, y: size.height - 28) },
                       pointer: { model.pointer })
            .frame(width: 600, height: 380)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): model.pointer = p
                case .ended: model.pointer = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let o = CGPoint(x: 600 * 0.32, y: 380 - 28)
                    let local = SIMD2(Double((v.location.x - o.x) / 96), Double((v.location.y - o.y) / 96))
                    if v.translation == .zero {
                        if case .main = model.stage.hitTest(local) { model.stage.main.pressBegan(at: local) }
                    } else {
                        model.stage.main.pressMoved(to: local)
                    }
                }
                .onEnded { _ in model.stage.main.pressEnded() })
    }

    private var smallCanvas: some View {
        HStack(spacing: 8) {
            SlimeStageView(stage: model.stage, radius: 22, paused: model.paused, sink: nil, probe: nil, updatesPointer: false,
                           origin: { size in CGPoint(x: 70, y: size.height - 6) })
                .frame(width: 420, height: 56)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text("notch size (R 22)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).controlSize(.small)
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("States").font(.headline)
            FlowRow {
                button("greet") { model.stage.main.greet() }
                button("listen") { model.stage.main.startListening() }
                button("stop listen") { model.stage.main.stopListening(hadSpeech: true) }
                button("stop silent") { model.stage.main.stopListening(hadSpeech: false) }
                button("record") { model.stage.main.setRecording(true) }
                button("record off") { model.stage.main.setRecording(false) }
                button("chew") { model.stage.main.startChewing() }
                button("chew done") { model.stage.main.ingestionFinished(success: true) }
                button("chew fail") { model.stage.main.ingestionFinished(success: false) }
                button("question") { model.stage.main.startQuestion() }
                button("dizzy") { model.stage.main.startDizzy() }
                button("sleep") { model.stage.main.sleepNow() }
                button("wake") { model.stage.main.wake() }
                button("drag in") { model.stage.main.dragEntered(fromDirection: 1) }
                button("drop") { model.stage.main.drop() }
                button("hold 1 s") { model.holdForOneSecond() }
            }
            Text("Agent").font(.headline)
            FlowRow {
                ForEach(AgentState.allCases, id: \.self) { s in
                    button(s.rawValue) { model.stage.main.agent(s) }
                }
            }
            Text("Emotes").font(.headline)
            FlowRow {
                ForEach(SlimeEmote.allCases, id: \.self) { e in
                    button(e.rawValue) { model.stage.main.trigger(e) }
                }
            }
            Text("Impulses").font(.headline)
            FlowRow {
                button("jump") { model.stage.main.impulse(.jump(v0: 2.6)) }
                button("hop") { model.stage.main.impulse(.jump(v0: 1.4)) }
                button("slap L") { model.stage.main.impulse(.slap(side: -1, strength: 0.8)) }
                button("slap R") { model.stage.main.impulse(.slap(side: 1, strength: 0.8)) }
                button("puff") { model.stage.main.impulse(.puff(scale: 0.12)) }
                button("wobble") { model.stage.main.impulse(.wobble(angle: -.pi / 2, strength: 0.4)) }
                button("shake") { model.stage.main.impulse(.shake(direction: SIMD2(3, 0))) }
                button("bite") { model.stage.main.impulse(.bite(side: 1, strength: 0.5)) }
                button("nudge") { model.stage.main.impulse(.nudge(direction: SIMD2(1, 0))) }
                button("landing") { model.stage.main.impulse(.landing(speed: 3)) }
            }
        }
    }

    private var stageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stage").font(.headline)
            FlowRow {
                button("5× click") { model.fiveClicks() }
                button("split 6") { model.stage.split(extra: 3) }
                button("pinch session") { model.pinchSession() }
                button("end session") { model.endLastSession() }
                button("mini working") { if let m = model.stage.minis.last { model.stage.setMiniState(m.id, .working) } }
                button("mini waiting") { if let m = model.stage.minis.last { model.stage.setMiniState(m.id, .waiting) } }
                button("mini finished") { if let m = model.stage.minis.last { model.stage.setMiniState(m.id, .finished) } }
                button("mini error") { if let m = model.stage.minis.last { model.stage.setMiniState(m.id, .error) } }
                button("ghost demo") { model.dragGhostDemo() }
                button("reset") { model.reset() }
            }
            HStack {
                Toggle("slow motion ×0.25", isOn: Binding(get: { model.timeScale < 1 }, set: { model.timeScale = $0 ? 0.25 : 1 }))
                Toggle("reduce motion", isOn: $model.reduceMotion)
                Toggle("paused", isOn: $model.paused)
            }
            .controlSize(.small)
            HStack {
                Picker("theme", selection: $model.themeName) {
                    ForEach(SlimeTheme.names, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 160)
                Stepper("seed \(model.seed)", value: $model.seed, in: 1...9999)
                button("copy params JSON") { model.copyParams() }
            }
            .controlSize(.small)
            HStack {
                Text("audio").font(.caption)
                Slider(value: $model.audioLevel, in: 0...1)
                Text(String(format: "%.2f", model.audioLevel)).font(.caption.monospacedDigit())
            }
        }
    }

    private var scriptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Script").font(.headline)
            TextField("t:action,…", text: $model.script).font(.system(size: 11, design: .monospaced))
            HStack {
                button("run") { model.runScript() }
                button("render filmstrip") { model.renderFilmstrip() }
                Text("states: idle greeting pinch sessions ghost · \(Filmstrip.actionHelp.split(separator: "\n").first ?? "")")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var tuningSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Body").font(.headline)
            slider("anchor", $model.params.anchorStiffness, 20...200)
            slider("edge", $model.params.edgeStiffness, 200...2400)
            slider("bend", $model.params.bendStiffness, 0...900)
            slider("pressure", $model.params.pressure, 0...160)
            slider("damping", $model.params.damping, 1...20)
            slider("gravity", $model.params.gravity, 0...10)
            slider("root gravity", $model.params.rootGravity, 2...24)
            slider("floor friction", $model.params.floorFriction, 0...1)
            slider("rest centre y", $model.params.restCenterY, -1.1 ... -0.6)
            Text("Breath").font(.headline)
            slider("amplitude", $model.breathAmplitude, 0...0.06)
            slider("rate", $model.breathRate, 0.05...0.5)
            Text("Eyes").font(.headline)
            slider("separation", $model.rig.separation, 0.2...0.6)
            slider("base pitch", $model.rig.basePitch, -0.2...0.4)
            slider("sphere radius", $model.rig.sphereRadius, 0.6...1.1)
            slider("eye radius", $model.rig.eyeRadius, 0.08...0.3)
            slider("eye aspect", $model.rig.eyeAspect, 0.8...2)
            slider("mouth pitch", $model.rig.mouthPitch, -0.8...0)
            slider("blush yaw", $model.rig.blushYaw, 0.3...1)
            Text("Gaze").font(.headline)
            slider("yaw gain", $model.yawGain, 0...1)
            slider("pitch gain", $model.pitchGain, 0...1)
            slider("tau", $model.gazeTau, 0.05...0.5)
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 90, alignment: .trailing)
            Slider(value: value, in: range) { _ in model.applyParams() }
                .onChange(of: value.wrappedValue) { _, _ in model.applyParams() }
            Text(String(format: "%.3g", value.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 48, alignment: .leading)
        }
    }
}

/// Wraps buttons onto as many rows as needed.
struct FlowRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { subviews in
            FlowLayout(spacing: 6) {
                ForEach(subviews) { $0 }
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
#endif
