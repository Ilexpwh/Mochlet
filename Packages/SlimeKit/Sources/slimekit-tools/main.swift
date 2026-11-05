import Foundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import CoreText
import simd
import SlimeKit
import SlimeKitUI

// slimekit-tools render-filmstrip --state finished --frames 48 --fps 24 --radius 64 --seed 7 --out ./out/finished
//                                 [--script "0:greet,1.6:click,2.2:emote:happy"] [--theme rimuru] [--pointer x,y] [--mini]
// slimekit-tools gen-sounds --out <dir>

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
func applyAction(_ action: String, to engine: SlimeEngine) {
    let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
    let name = parts[0]
    let arg = parts.count > 1 ? parts[1] : ""
    switch name {
    case "greet": engine.greet()
    case "click":
        engine.pressBegan(at: SIMD2(0.2, -0.9))
        engine.pressEnded()
    case "press": engine.pressBegan(at: SIMD2(0.2, -0.9))
    case "release": engine.pressEnded()
    case "emote": if let e = SlimeEmote(rawValue: arg) { engine.trigger(e) }
    case "agent": if let s = AgentState(rawValue: arg) { engine.agent(s) }
    case "listen": engine.startListening()
    case "stoplisten": engine.stopListening(hadSpeech: arg != "silent")
    case "record": engine.setRecording(arg != "off")
    case "chew": engine.startChewing()
    case "chewdone": engine.ingestionFinished(success: arg != "fail")
    case "question": engine.startQuestion()
    case "dizzy": engine.startDizzy()
    case "split": engine.beginSplit()
    case "endsplit": engine.endSplit()
    case "sleep": engine.sleepNow()
    case "wake": engine.wake()
    case "audio": engine.setAudioLevel(Double(arg) ?? 0.5)
    case "dragin": engine.dragEntered(fromDirection: Double(arg) ?? 1)
    case "dragout": engine.dragExited()
    case "drop": engine.drop()
    case "jump": engine.impulse(.jump(v0: Double(arg) ?? 2.6))
    case "slap": engine.impulse(.slap(side: Double(arg) ?? 1, strength: 0.8))
    case "puff": engine.impulse(.puff(scale: Double(arg) ?? 0.1))
    case "pointer":
        let xy = arg.split(separator: ",").compactMap { Double($0) }
        engine.pointer(xy.count == 2 ? SIMD2(xy[0], xy[1]) : nil)
    default:
        FileHandle.standardError.write("unknown action \(action)\n".data(using: .utf8)!)
    }
}

/// `--state` shortcuts expand to a script.
func scriptForState(_ s: String) -> String {
    switch s {
    case "idle": return ""
    case "greeting": return "0:greet"
    case "thinking", "working", "waiting", "finished", "error": return "0:agent:\(s)"
    case "listening": return "0:listen,0.3:audio:0.4,0.6:audio:0.8,0.9:audio:0.3,1.3:audio:0.9,1.8:stoplisten"
    case "recording": return "0:record"
    case "chewing": return "0:chew,1.6:chewdone"
    case "question": return "0:question"
    case "dizzy": return "0:dizzy"
    case "sleeping": return "0:sleep,2.4:wake"
    case "split": return "0:split,1.5:endsplit"
    case "hover": return "0:pointer:0.3,-1.0"
    case "click": return "0:click"
    case "drop": return "0:dragin:1,0.6:drop,2.2:chewdone"
    default:
        if SlimeEmote(rawValue: s) != nil { return "0:emote:\(s)" }
        return ""
    }
}

struct TraceRecord: Codable {
    var frame: Int
    var t: Double
    var state: String
    var emote: String?
    var rootX: Double
    var rootY: Double
    var areaRatio: Double
    var sx: Double
    var sy: Double
    var rotation: Double
    var topY: Double
    var contactWidth: Double
    var eyeOpenL: Double
    var eyeOpenR: Double
    var eyeL: String
    var eyeR: String
    var mouth: String
    var gazeYaw: Double
    var gazePitch: Double
    var airborne: Bool
    var particles: Int
    var accessories: [String]
    var frameInterval: Double?
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "slimekit-tools", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "slimekit-tools", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
}

func contactSheet(_ images: [CGImage], labels: [String], columns: Int) -> CGImage? {
    guard let first = images.first else { return nil }
    let cw = first.width
    let ch = first.height + 18
    let rows = (images.count + columns - 1) / columns
    let width = cw * columns
    let height = ch * rows
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (i, img) in images.enumerated() {
        let col = i % columns
        let row = i / columns
        let x = col * cw
        let yTop = row * ch
        let y = height - yTop - ch
        ctx.draw(img, in: CGRect(x: x, y: y + 18, width: cw, height: first.height))
        let label = i < labels.count ? labels[i] : "\(i)"
        let font = CTFontCreateWithName("Menlo" as CFString, 10, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0.85, alpha: 1)]
        let str = CFAttributedStringCreate(nil, label as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(str)
        ctx.textPosition = CGPoint(x: CGFloat(x) + 4, y: CGFloat(y) + 5)
        CTLineDraw(line, ctx)
    }
    return ctx.makeImage()
}

@MainActor
func renderFilmstrip(_ args: Args) throws {
    let frames = args.int("frames", 48)
    let fps = args.double("fps", 24)
    let radius = CGFloat(args.double("radius", 64))
    let seed = UInt64(args.int("seed", 7))
    let outDir = URL(fileURLWithPath: args.string("out", "./out/filmstrip"))
    let theme = SlimeTheme.named(args.string("theme", "rimuru"))
    let columns = args.int("columns", 8)
    let preroll = args.double("preroll", 0.6)
    let profile: SlimeProfile = args.flags.contains("mini") ? .mini : .main
    var script = args.values["script"] ?? scriptForState(args.string("state", "idle"))
    if let extra = args.values["also"] { script += (script.isEmpty ? "" : ",") + extra }

    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let engine = SlimeEngine(profile: profile, seed: seed)
    engine.theme = theme
    if let p = args.values["pointer"] {
        let xy = p.split(separator: ",").compactMap { Double($0) }
        if xy.count == 2 { engine.pointer(SIMD2(xy[0], xy[1])) }
    }
    var actions: [(Double, String)] = script.split(separator: ",").compactMap { item in
        let s = item.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let t = Double(parts[0]) else { return nil }
        return (t, parts[1])
    }
    actions.sort { $0.0 < $1.0 }

    engine.simulate(preroll)
    let size = CGSize(width: radius * 4.4, height: radius * 3.0)
    let origin = CGPoint(x: size.width * 0.42, y: size.height - radius * 0.25)
    var images: [CGImage] = []
    var labels: [String] = []
    var trace: [TraceRecord] = []
    let dt = 1.0 / fps
    var t = 0.0
    var cues: [String] = []
    for i in 0..<frames {
        while let next = actions.first, next.0 <= t + 1e-9 {
            applyAction(next.1, to: engine)
            actions.removeFirst()
        }
        if i > 0 { engine.simulate(dt) }
        for c in engine.drainCues() { cues.append(String(format: "%.3f %@", t, c.sound.rawValue)) }
        let frame = engine.frame()
        let view = SlimeFrameView(frame: frame, theme: theme, radius: radius, size: size, origin: origin)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(size)
        guard let cg = renderer.cgImage else {
            throw NSError(domain: "slimekit-tools", code: 3, userInfo: [NSLocalizedDescriptionKey: "render failed at frame \(i)"])
        }
        try writePNG(cg, to: outDir.appendingPathComponent(String(format: "frame-%03d.png", i)))
        images.append(cg)
        labels.append(String(format: "%03d %.2fs %@%@", i, t, frame.state.rawValue, frame.emote.map { " +\($0.rawValue)" } ?? ""))
        trace.append(TraceRecord(
            frame: i, t: t, state: frame.state.rawValue, emote: frame.emote?.rawValue,
            rootX: frame.root.x, rootY: frame.root.y, areaRatio: engine.body.areaRatio,
            sx: frame.body.scaleX, sy: frame.body.scaleY, rotation: frame.body.rotation,
            topY: frame.topY, contactWidth: frame.contactWidth,
            eyeOpenL: frame.eyes.first?.openness ?? 1, eyeOpenR: frame.eyes.last?.openness ?? 1,
            eyeL: frame.eyes.first?.shape.rawValue ?? "", eyeR: frame.eyes.last?.shape.rawValue ?? "",
            mouth: frame.mouth.shape.rawValue, gazeYaw: frame.gaze.x, gazePitch: frame.gaze.y,
            airborne: frame.airborne, particles: frame.particles.count,
            accessories: frame.accessories.map(\.kind.rawValue), frameInterval: engine.frameInterval))
        t += dt
    }
    if let sheet = contactSheet(images, labels: labels, columns: columns) {
        try writePNG(sheet, to: outDir.appendingPathComponent("contact.png"))
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(trace).write(to: outDir.appendingPathComponent("trace.json"))
    try cues.joined(separator: "\n").write(to: outDir.appendingPathComponent("cues.txt"), atomically: true, encoding: .utf8)
    print("wrote \(frames) frames to \(outDir.path) (contact.png, trace.json, cues.txt)")
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
    default:
        print("""
        slimekit-tools render-filmstrip --state <state|emote> | --script "t:action,…" [--frames 48] [--fps 24] [--radius 64] [--seed 7] [--out dir] [--theme name] [--pointer x,y] [--mini]
        slimekit-tools gen-sounds --out <dir>
        actions: greet click press release emote:<name> agent:<idle|thinking|working|waiting|finished|error> listen stoplisten[:silent]
                 record[:off] chew chewdone[:fail] question dizzy split endsplit sleep wake audio:<0-1> dragin:<±1> dragout drop
                 jump:<v0> slap:<side> puff:<scale> pointer:<x,y>
        """)
    }
} catch {
    FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
