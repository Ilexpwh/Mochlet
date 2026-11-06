import Foundation
import AppKit
import SwiftUI
import simd
import SlimeKit
import SlimeKitUI
import SlimeKitAudio

// slimekit-tools render-filmstrip --state finished --frames 48 --fps 24 --radius 64 --seed 7 --out ./out/finished
//                                 [--script "0:greet,1.6:click,2.2:emote:happy"] [--theme rimuru] [--pointer x,y] [--mini]
//                                 [--width 4.4 --height 3.0 --originx 0.42] [--reduce-motion]
// slimekit-tools gen-sounds --out <dir>
// slimekit-tools lab            (Emote Lab window, debug builds)
// slimekit-tools play <sound>   (plays one generated sound)

struct Args {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    values[key] = argv[i + 1]
                    i += 2
                    continue
                }
                flags.insert(key)
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func string(_ k: String, _ d: String) -> String { values[k] ?? d }
    func double(_ k: String, _ d: Double) -> Double { values[k].flatMap(Double.init) ?? d }
    func int(_ k: String, _ d: Int) -> Int { values[k].flatMap(Int.init) ?? d }
}

@MainActor
func renderFilmstrip(_ args: Args) throws {
    var o = FilmstripOptions()
    o.frames = args.int("frames", 48)
    o.fps = args.double("fps", 24)
    o.radius = CGFloat(args.double("radius", 64))
    o.seed = UInt64(args.int("seed", 7))
    o.theme = SlimeTheme.named(args.string("palette", args.string("theme", "rimuru")))
    o.appearance.look = SlimeLook.named(args.string("look", "rimuru"))
    if let set = args.values["outfit"], let outfit = SlimeOutfit.set(named: set) { o.appearance.outfit = outfit }
    o.columns = args.int("columns", 8)
    o.preroll = args.double("preroll", 0.6)
    o.widthR = args.double("width", 4.4)
    o.heightR = args.double("height", 3.0)
    o.originX = args.double("originx", 0.42)
    o.mini = args.flags.contains("mini")
    o.reduceMotion = args.flags.contains("reduce-motion")
    var script = args.values["script"] ?? Filmstrip.scriptForState(args.string("state", "idle"))
    if let extra = args.values["also"] { script += (script.isEmpty ? "" : ",") + extra }
    o.script = script
    if let p = args.values["pointer"] {
        let xy = p.split(separator: ",").compactMap { Double($0) }
        if xy.count == 2 { o.pointer = SIMD2(xy[0], xy[1]) }
    }
    let outDir = URL(fileURLWithPath: args.string("out", "./out/filmstrip"))
    let result = try Filmstrip.render(o)
    try Filmstrip.write(result, to: outDir)
    print("wrote \(result.images.count) frames to \(outDir.path) (contact.png, trace.json, cues.txt)")
}

@MainActor
func runLab() {
    #if DEBUG
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let sound = SoundEngine()
    sound.preload()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "SlimeKit Emote Lab"
    window.contentView = NSHostingView(rootView: EmoteLabView(sink: sound))
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
    #else
    print("the Emote Lab is only built in debug configurations")
    #endif
}

@MainActor
func playSound(_ name: String, pack: SoundPack) {
    let sounds: [SlimeSound]
    if name == "all" {
        sounds = SlimeSound.allCases
    } else if let s = SlimeSound(rawValue: name) {
        sounds = [s]
    } else {
        print("unknown sound \(name); one of: all \(SlimeSound.allCases.map(\.rawValue).joined(separator: " "))")
        return
    }
    let engine = SoundEngine(overrideFolder: nil, pack: pack)
    engine.masterVolume = 0.6
    engine.maxPlaysPerSecond = 100
    for s in sounds {
        print(s.rawValue)
        engine.play(SoundCue(s))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: SoundRecipe.recipe(for: s, in: pack).duration + 0.35))
    }
}

/// Engine and draw cost: ms of CPU per simulated second (idle stage) and ms per Canvas draw at R 22 / R 96.
@MainActor
func bench(_ args: Args) {
    let seconds = args.double("seconds", 20)
    let stage = SlimeStage(seed: 7)
    stage.simulate(1)
    let t0 = PerfProbe.processCPUSeconds()
    stage.simulate(seconds)
    let engineMs = (PerfProbe.processCPUSeconds() - t0) * 1000 / seconds
    for r in [22.0, 96.0] {
        let R = CGFloat(r)
        let size = CGSize(width: R * 4.4, height: R * 3)
        let origin = CGPoint(x: size.width * 0.42, y: size.height - R * 0.25)
        var frames = 0
        let d0 = PerfProbe.processCPUSeconds()
        let wall0 = Date.timeIntervalSinceReferenceDate
        while frames < 60 {
            stage.simulate(1.0 / 30.0)
            let view = StageFrameView(placed: stage.frames(), radius: R, size: size, origin: origin)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            renderer.proposedSize = ProposedViewSize(size)
            _ = renderer.cgImage
            frames += 1
        }
        let cpuMs = (PerfProbe.processCPUSeconds() - d0) * 1000 / Double(frames)
        let wallMs = (Date.timeIntervalSinceReferenceDate - wall0) * 1000 / Double(frames)
        print(String(format: "draw R %.0f: %.2f ms cpu / %.2f ms wall per frame (ImageRenderer, includes rasterisation)", r, cpuMs, wallMs))
    }
    print(String(format: "engine: %.2f ms cpu per simulated second of idle stage (%.3f%% of a core)", engineMs, engineMs / 10))
    benchScenarios()
}

/// Per-frame cost of the expensive Character 2 situations at the expanded-island size (R 56):
/// engine step + frame, and a direct CoreGraphics draw into a bitmap (no SwiftUI).
@MainActor
func benchScenarios() {
    let R: CGFloat = 56
    let w = Int(R * 4.4)
    let h = Int(R * 3)
    guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    let origin = CGPoint(x: CGFloat(w) * 0.42, y: CGFloat(h) - R * 0.25)
    let scenarios: [(String, (SlimeEngine) -> Void)] = [
        ("idle", { _ in }),
        ("hover (eyes follow)", { $0.pointer(SIMD2(0.8, -1.2)) }),
        ("chewing (arms + file)", { $0.startChewing() }),
        ("question (grown ?)", { $0.startQuestion() }),
        ("melt", { $0.trigger(.melt) }),
        ("cheer (hops + stars)", { $0.trigger(.cheer) }),
        ("tempest look, idle", { $0.appearance = SlimeAppearance(look: .named("tempest")) }),
        ("chewing, arms off", { var a = $0.appearance; a.armsEnabled = false; $0.appearance = a; $0.startChewing() }),
        ("cat look, idle", { $0.appearance = SlimeAppearance(look: .named("cat")) }),
        ("king outfit, idle", { $0.appearance = SlimeAppearance(outfit: SlimeOutfit.set(named: "king") ?? SlimeOutfit()) }),
    ]
    // Contour alone, on a mid-chew frame with both arms and the file out.
    do {
        let engine = SlimeEngine(profile: .main, seed: 7)
        engine.detail = DetailLevel(pixelsPerUnit: Double(R))
        engine.simulate(1)
        engine.startChewing()
        engine.simulate(1.0)
        let frame = engine.frame()
        let blobs = frame.blobs.filter { $0.radius > 1e-4 }
        let opts = Metaball.Options.forScale(pixelsPerUnit: Double(R))
        let c0 = PerfProbe.processCPUSeconds()
        var loops = 0
        for _ in 0..<200 { loops += Metaball.contour(ring: frame.ring, blobs: blobs, options: opts).count }
        let ms = (PerfProbe.processCPUSeconds() - c0) * 1000 / 200
        print(String(format: "R 56 contour only, chewing: %d blobs, %.3f ms per contour (cell %.3f R, %d loops)", blobs.count, ms, opts.cell, loops / 200))
    }
    // Per-stage split of one draw for the heavy scenarios (fresh frames, so caches work as live).
    let staged: [(String, (SlimeEngine) -> Void)] = [
        ("chewing", { $0.startChewing() }),
        ("cheer", { $0.trigger(.cheer) }),
        ("question", { $0.startQuestion() }),
        ("tempest idle", { $0.appearance = SlimeAppearance(look: .named("tempest")) }),
        ("cat idle", { $0.appearance = SlimeAppearance(look: .named("cat")) }),
        ("galaxy idle", { $0.appearance = SlimeAppearance(look: .named("galaxy")) }),
    ]
    for (name, setup) in staged {
        let engine = SlimeEngine(profile: .main, seed: 7)
        engine.detail = DetailLevel(pixelsPerUnit: Double(R))
        engine.simulate(1)
        setup(engine)
        engine.simulate(0.6)
        var sums: [String: Double] = [:]
        var order: [String] = []
        let n = 60
        for _ in 0..<n {
            engine.simulate(1.0 / 60.0)
            let frame = engine.frame()
            cg.saveGState()
            cg.clear(CGRect(x: 0, y: 0, width: w, height: h))
            cg.translateBy(x: 0, y: CGFloat(h))
            cg.scaleBy(x: 1, y: -1)
            for (stage, ms) in SlimeCGRenderer.stageTimings(frame, appearance: engine.appearance, in: cg, origin: origin, radius: R) {
                if sums[stage] == nil { order.append(stage) }
                sums[stage, default: 0] += ms
            }
            cg.restoreGState()
        }
        let parts = order.map { String(format: "%@ %.2f", $0, sums[$0]! / Double(n)) }
        print("R 56 stages " + name.padding(toLength: 13, withPad: " ", startingAt: 0) + parts.joined(separator: " · "))
    }
    for (name, setup) in scenarios {
        let engine = SlimeEngine(profile: .main, seed: 7)
        engine.detail = DetailLevel(pixelsPerUnit: Double(R))
        engine.simulate(1)
        setup(engine)
        let dt = 1.0 / 60.0
        let total = Int(2.0 / dt)
        var engineCPU = 0.0
        var drawCPU = 0.0
        var drawWall = 0.0
        for _ in 0..<total {
            let e0 = PerfProbe.processCPUSeconds()
            engine.simulate(dt)
            let frame = engine.frame()
            let e1 = PerfProbe.processCPUSeconds()
            let w0 = Date.timeIntervalSinceReferenceDate
            cg.saveGState()
            cg.clear(CGRect(x: 0, y: 0, width: w, height: h))
            cg.translateBy(x: 0, y: CGFloat(h))
            cg.scaleBy(x: 1, y: -1)
            SlimeCGRenderer.draw(frame, appearance: engine.appearance, in: cg, origin: origin, radius: R)
            cg.restoreGState()
            let e2 = PerfProbe.processCPUSeconds()
            engineCPU += e1 - e0
            drawCPU += e2 - e1
            drawWall += Date.timeIntervalSinceReferenceDate - w0
        }
        let n = Double(total)
        let label = name.padding(toLength: 24, withPad: " ", startingAt: 0)
        print("R 56 " + label + String(format: " engine %.3f ms  draw %.3f ms cpu / %.3f ms wall per frame (60 Hz, 2 s)", engineCPU * 1000 / n, drawCPU * 1000 / n, drawWall * 1000 / n))
    }
}

/// Renders the app icon set (happy slime on a dark rounded square) into an .appiconset folder.
@MainActor
func renderIcon(_ args: Args) throws {
    let outDir = URL(fileURLWithPath: args.string("out", "./out/AppIcon.appiconset"))
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let engine = SlimeEngine(profile: .main, seed: 7)
    engine.theme = SlimeTheme.named(args.string("theme", "rimuru"))
    engine.simulate(0.8)
    engine.trigger(.happy)
    engine.simulate(0.42)
    engine.pointer(SIMD2(0.6, -1.4))
    engine.simulate(0.3)
    let frame = engine.frame()
    let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
    var entries: [[String: String]] = []
    for (pt, scale) in sizes {
        let px = pt * scale
        let size = CGSize(width: px, height: px)
        let R = CGFloat(px) * 0.30
        let origin = CGPoint(x: size.width * 0.5, y: size.height * 0.80)
        let view = ZStack {
            RoundedRectangle(cornerRadius: CGFloat(px) * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.20), Color(red: 0.03, green: 0.04, blue: 0.08)], startPoint: .top, endPoint: .bottom))
                .padding(CGFloat(px) * 0.02)
            SlimeFrameView(frame: frame, appearance: engine.appearance, radius: R, size: size, origin: origin, background: .clear)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(size)
        guard let cg = renderer.cgImage else { continue }
        let name = "icon_\(pt)x\(pt)@\(scale)x.png"
        try Filmstrip.writePNG(cg, to: outDir.appendingPathComponent(name))
        entries.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)"])
    }
    let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
    let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: outDir.appendingPathComponent("Contents.json"))
    print("wrote \(entries.count) icon images to \(outDir.path)")
}

let argv = Array(CommandLine.arguments.dropFirst())
let args = Args(argv)
let command = args.positional.first ?? "help"
do {
    switch command {
    case "render-filmstrip":
        try renderFilmstrip(args)
    case "gen-sounds":
        let packs = args.string("pack", "all") == "all" ? SoundPack.allCases : [SoundPack(rawValue: args.string("pack", "puni")) ?? .puni]
        try SoundGenerator.run(outDir: URL(fileURLWithPath: args.string("out", "./out/sounds")), packs: packs)
    case "lab":
        runLab()
    case "play":
        playSound(args.positional.count > 1 ? args.positional[1] : "greet", pack: SoundPack(rawValue: args.string("pack", "puni")) ?? .puni)
    case "bench":
        bench(args)
    case "icon":
        try renderIcon(args)
    case "render-catalog":
        let out = URL(fileURLWithPath: args.string("out", "./out/catalog.png"))
        let palettes = args.values["palettes"].map { $0.split(separator: ",").map { SlimeTheme.named(String($0)) } } ?? [.rimuru, .ruby, .obsidian]
        let looks = args.values["looks"].map { $0.split(separator: ",").map { SlimeLook.named(String($0)) } } ?? SlimeLook.all
        let outfit = args.values["outfit"].flatMap { SlimeOutfit.set(named: $0) } ?? SlimeOutfit()
        let sheet: CGImage
        if args.values["sets"] != nil {
            sheet = try Catalog.renderSets(look: looks.first ?? .rimuru, palette: palettes.first ?? .rimuru, radius: CGFloat(args.double("radius", 56)))
        } else {
            sheet = try Catalog.render(palettes: palettes, looks: looks, outfit: outfit, radius: CGFloat(args.double("radius", 56)))
        }
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Filmstrip.writePNG(sheet, to: out)
        print("wrote \(out.path) (\(sheet.width)x\(sheet.height))")
    default:
        print("""
        slimekit-tools render-filmstrip --state <state|emote|pinch|sessions|ghost|ghostdrop> | --script "t:action,…"
                       [--frames 48] [--fps 24] [--radius 64] [--seed 7] [--out dir] [--palette name] [--look name] [--pointer x,y] [--mini]
                       [--width 4.4 --height 3.0 --originx 0.42] [--reduce-motion]
        slimekit-tools gen-sounds --out <dir> [--pack puni|classic|all]
        slimekit-tools lab
        slimekit-tools play <sound|all> [--pack puni|classic]
        slimekit-tools bench [--seconds 20]
        slimekit-tools icon --out <AppIcon.appiconset>
        slimekit-tools render-catalog [--out catalog.png] [--palettes rimuru,ruby,obsidian] [--looks cat,fox] [--outfit king] [--sets 1] [--radius 56]
        actions:
        \(Filmstrip.actionHelp)
        """)
    }
} catch {
    FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
