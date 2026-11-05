import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import CoreText
import simd
import SlimeKit

/// Scripted offline rendering of a stage: PNG frames, a contact sheet and a numeric trace so motion
/// can be reviewed as images and numbers. Shared by `slimekit-tools render-filmstrip` and the Emote Lab.
public struct FilmstripOptions: Sendable {
    public var frames = 48
    public var fps = 24.0
    public var radius: CGFloat = 64
    public var seed: UInt64 = 7
    public var theme = SlimeTheme.rimuru
    public var columns = 8
    public var preroll = 0.6
    /// Canvas size in R and the horizontal position of the main contact point (fraction of width).
    public var widthR = 4.4
    public var heightR = 3.0
    public var originX = 0.42
    /// Render a standalone mini-profile engine instead of a stage.
    public var mini = false
    public var reduceMotion = false
    /// "t:action,t:action,…" (see `Filmstrip.applyAction`).
    public var script = ""
    public var pointer: SIMD2<Double>? = nil

    public init() {}
}

public struct FilmstripTrace: Codable, Sendable {
    public var frame: Int
    public var t: Double
    public var state: String
    public var emote: String?
    public var rootX: Double
    public var rootY: Double
    public var areaRatio: Double
    public var sx: Double
    public var sy: Double
    public var rotation: Double
    public var topY: Double
    public var contactWidth: Double
    public var eyeOpenL: Double
    public var eyeOpenR: Double
    public var eyeL: String
    public var eyeR: String
    public var mouth: String
    public var gazeYaw: Double
    public var gazePitch: Double
    public var airborne: Bool
    public var particles: Int
    public var blobs: Int
    public var minis: Int
    public var accessories: [String]
    public var frameInterval: Double?
}

public struct FilmstripResult {
    public var images: [CGImage]
    public var labels: [String]
    public var contact: CGImage?
    public var trace: [FilmstripTrace]
    public var cues: [String]
}

public enum Filmstrip {
    /// `--state` shortcuts expand to a script.
    public static func scriptForState(_ s: String) -> String {
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
        case "split": return "0:split:1"
        case "hover": return "0:pointer:0.3,-1.0"
        case "click": return "0:click"
        case "drop": return "0:dragin:1,0.6:drop,2.2:chewdone"
        case "pinch": return "0:pinch:a,1.4:miniagent:a:working,2.6:miniagent:a:finished,4.4:endsession:a"
        case "sessions": return "0:pinch:a,0.9:pinch:b,1.8:pinch:c,2.6:miniagent:a:waiting,3.2:miniagent:b:error,4.6:endsession:a"
        case "ghost": return "0:ghost:0.3,-1,0.05:ghostto:4,-3,0.9:ghostto:5.5,-2,1.6:ghostback"
        case "ghostdrop": return "0:ghost:0.3,-1,0.05:ghostto:4.5,-3,1.2:ghostdrop"
        default:
            if SlimeEmote(rawValue: s) != nil { return "0:emote:\(s)" }
            return ""
        }
    }

    public static let actionHelp = """
    greet click press release emote:<name> agent:<idle|thinking|working|waiting|finished|error> listen stoplisten[:silent]
    record[:off] chew chewdone[:fail] question dizzy sleep wake audio:<0-1> dragin:<±1> dragout drop
    jump:<v0> slap:<side> puff:<scale> shake pointer:<x,y> lean:<rad>
    stage: split[:extra] pinch:<id> endsession:<id> miniagent:<id>:<state> ghost:<x,y> ghostto:<x,y> ghostdrop ghostback
    """

    /// Applies one engine action.
    @MainActor
    public static func applyAction(_ action: String, to engine: SlimeEngine) -> Bool {
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
        case "sleep": engine.sleepNow()
        case "wake": engine.wake()
        case "audio": engine.setAudioLevel(Double(arg) ?? 0.5)
        case "dragin": engine.dragEntered(fromDirection: Double(arg) ?? 1)
        case "dragout": engine.dragExited()
        case "drop": engine.drop()
        case "jump": engine.impulse(.jump(v0: Double(arg) ?? 2.6))
        case "slap": engine.impulse(.slap(side: Double(arg) ?? 1, strength: 0.8))
        case "puff": engine.impulse(.puff(scale: Double(arg) ?? 0.1))
        case "shake": engine.impulse(.shake(direction: SIMD2(Double(arg) ?? 3, 0)))
        case "lean": engine.setLean(Double(arg) ?? 0.15, duration: 0.3)
        case "pointer":
            let xy = arg.split(separator: ",").compactMap { Double($0) }
            engine.pointer(xy.count == 2 ? SIMD2(xy[0], xy[1]) : nil)
        default:
            return false
        }
        return true
    }

    /// Applies a stage action, falling back to the main engine.
    @MainActor
    public static func applyAction(_ action: String, to stage: SlimeStage) -> Bool {
        let parts = action.split(separator: ":").map(String.init)
        let name = parts[0]
        func xy(_ s: String) -> SIMD2<Double>? {
            let v = s.split(separator: ",").compactMap { Double($0) }
            return v.count == 2 ? SIMD2(v[0], v[1]) : nil
        }
        switch name {
        case "split": stage.split(extra: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        case "pinch": if parts.count > 1 { stage.spawnMini(id: parts[1]) }
        case "endsession": if parts.count > 1 { stage.removeMini(parts[1]) }
        case "miniagent": if parts.count > 2, let s = AgentState(rawValue: parts[2]) { stage.setMiniState(parts[1], s) }
        case "ghost": if parts.count > 1, let p = xy(parts[1]) { stage.beginDragOut(at: p) }
        case "ghostto": if parts.count > 1, let p = xy(parts[1]) { stage.updateDragOut(target: p) }
        case "ghostdrop": stage.endDragOut(dropped: true)
        case "ghostback": stage.endDragOut(dropped: false)
        default: return applyAction(action, to: stage.main)
        }
        return true
    }

    /// "t:action,t:action,…". An item without ':' continues the previous one, so coordinates
    /// such as `ghost:0.3,-1` survive the comma split.
    public static func parseScript(_ script: String) -> [(Double, String)] {
        var items: [String] = []
        for raw in script.split(separator: ",") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            if s.contains(":") || items.isEmpty {
                items.append(s)
            } else {
                items[items.count - 1] += "," + s
            }
        }
        var actions: [(Double, String)] = items.compactMap { s in
            let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let t = Double(parts[0]) else { return nil }
            return (t, parts[1])
        }
        actions.sort { $0.0 < $1.0 }
        return actions
    }

    @MainActor
    public static func render(_ o: FilmstripOptions) throws -> FilmstripResult {
        let stage = SlimeStage(seed: o.seed, theme: o.theme, reduceMotion: o.reduceMotion)
        let miniEngine: SlimeEngine? = o.mini ? SlimeEngine(profile: .mini, seed: o.seed) : nil
        miniEngine?.theme = o.theme
        if let p = o.pointer {
            stage.pointer(p)
            miniEngine?.pointer(p)
        }
        var actions = parseScript(o.script)
        if let m = miniEngine { m.simulate(o.preroll) } else { stage.simulate(o.preroll) }
        let R = o.radius
        let size = CGSize(width: R * o.widthR, height: R * o.heightR)
        let origin = CGPoint(x: size.width * o.originX, y: size.height - R * 0.25)
        var images: [CGImage] = []
        var labels: [String] = []
        var trace: [FilmstripTrace] = []
        var cues: [String] = []
        let dt = 1.0 / o.fps
        var t = 0.0
        for i in 0..<o.frames {
            while let next = actions.first, next.0 <= t + 1e-9 {
                if let m = miniEngine { _ = applyAction(next.1, to: m) } else { _ = applyAction(next.1, to: stage) }
                actions.removeFirst()
            }
            if i > 0 {
                if let m = miniEngine { m.simulate(dt) } else { stage.simulate(dt) }
            }
            let drained = miniEngine?.drainCues() ?? stage.drainCues()
            for c in drained { cues.append(String(format: "%.3f %@", t, c.sound.rawValue)) }
            let placed: [PlacedSlime] = miniEngine.map { [PlacedSlime(id: nil, frame: $0.frame(), scale: 1, offset: .zero)] } ?? stage.frames()
            let frame = placed[0].frame
            let engine = miniEngine ?? stage.main
            let view = StageFrameView(placed: placed, theme: o.theme, radius: R, size: size, origin: origin)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            renderer.proposedSize = ProposedViewSize(size)
            guard let cg = renderer.cgImage else {
                throw NSError(domain: "SlimeKitUI.Filmstrip", code: 3, userInfo: [NSLocalizedDescriptionKey: "render failed at frame \(i)"])
            }
            images.append(cg)
            labels.append(String(format: "%03d %.2fs %@%@", i, t, frame.state.rawValue, frame.emote.map { " +\($0.rawValue)" } ?? ""))
            trace.append(FilmstripTrace(
                frame: i, t: t, state: frame.state.rawValue, emote: frame.emote?.rawValue,
                rootX: frame.root.x, rootY: frame.root.y, areaRatio: engine.body.areaRatio,
                sx: frame.body.scaleX, sy: frame.body.scaleY, rotation: frame.body.rotation,
                topY: frame.topY, contactWidth: frame.contactWidth,
                eyeOpenL: frame.eyes.first?.openness ?? 1, eyeOpenR: frame.eyes.last?.openness ?? 1,
                eyeL: frame.eyes.first?.shape.rawValue ?? "", eyeR: frame.eyes.last?.shape.rawValue ?? "",
                mouth: frame.mouth.shape.rawValue, gazeYaw: frame.gaze.x, gazePitch: frame.gaze.y,
                airborne: frame.airborne, particles: frame.particles.count, blobs: frame.blobs.count,
                minis: placed.count - 1,
                accessories: frame.accessories.map(\.kind.rawValue), frameInterval: miniEngine?.frameInterval ?? stage.frameInterval))
            t += dt
        }
        let sheet = contactSheet(images, labels: labels, columns: o.columns)
        return FilmstripResult(images: images, labels: labels, contact: sheet, trace: trace, cues: cues)
    }

    public static func write(_ r: FilmstripResult, to outDir: URL) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for (i, cg) in r.images.enumerated() {
            try writePNG(cg, to: outDir.appendingPathComponent(String(format: "frame-%03d.png", i)))
        }
        if let sheet = r.contact {
            try writePNG(sheet, to: outDir.appendingPathComponent("contact.png"))
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(r.trace).write(to: outDir.appendingPathComponent("trace.json"))
        try r.cues.joined(separator: "\n").write(to: outDir.appendingPathComponent("cues.txt"), atomically: true, encoding: .utf8)
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "SlimeKitUI.Filmstrip", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.path)"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "SlimeKitUI.Filmstrip", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
        }
    }

    public static func contactSheet(_ images: [CGImage], labels: [String], columns: Int) -> CGImage? {
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
}

/// Static drawing of a set of placed slimes (filmstrips, previews).
public struct StageFrameView: View {
    public var placed: [PlacedSlime]
    public var theme: SlimeTheme
    public var radius: CGFloat
    public var size: CGSize
    public var origin: CGPoint
    public var background: Color

    public init(placed: [PlacedSlime], theme: SlimeTheme, radius: CGFloat, size: CGSize, origin: CGPoint, background: Color = .black) {
        self.placed = placed
        self.theme = theme
        self.radius = radius
        self.size = size
        self.origin = origin
        self.background = background
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, _ in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
            SlimeStageView.draw(placed, theme: theme, in: &ctx, origin: origin, radius: radius)
        }
        .frame(width: size.width, height: size.height)
    }
}
