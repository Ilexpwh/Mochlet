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
    o.theme = SlimeTheme.named(args.string("theme", "rimuru"))
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
func playSound(_ name: String) {
    guard let s = SlimeSound(rawValue: name) else {
        print("unknown sound \(name); one of: \(SlimeSound.allCases.map(\.rawValue).joined(separator: " "))")
        return
    }
    let engine = SoundEngine(overrideFolder: nil)
    engine.masterVolume = 0.6
    engine.play(SoundCue(s))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: SoundRecipe.recipe(for: s).duration + 0.3))
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
            let view = StageFrameView(placed: stage.frames(), theme: stage.theme, radius: R, size: size, origin: origin)
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
}

let argv = Array(CommandLine.arguments.dropFirst())
let args = Args(argv)
let command = args.positional.first ?? "help"
do {
    switch command {
    case "render-filmstrip":
        try renderFilmstrip(args)
    case "gen-sounds":
        try SoundGenerator.run(outDir: URL(fileURLWithPath: args.string("out", "./out/sounds")))
    case "lab":
        runLab()
    case "play":
        playSound(args.positional.count > 1 ? args.positional[1] : "greet")
    case "bench":
        bench(args)
    default:
        print("""
        slimekit-tools render-filmstrip --state <state|emote|pinch|sessions|ghost|ghostdrop> | --script "t:action,…"
                       [--frames 48] [--fps 24] [--radius 64] [--seed 7] [--out dir] [--theme name] [--pointer x,y] [--mini]
                       [--width 4.4 --height 3.0 --originx 0.42] [--reduce-motion]
        slimekit-tools gen-sounds --out <dir>
        slimekit-tools lab
        slimekit-tools play <sound>
        slimekit-tools bench [--seconds 20]
        actions:
        \(Filmstrip.actionHelp)
        """)
    }
} catch {
    FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
