#if DEBUG
import AppKit
import Security
import simd
import SlimeKit
import MochletCore

/// Command channel for development without a screen recorder: `open "mochlet://debug/<command>?…"`.
/// Results land in ~/Library/Logs/Mochlet/debug (state.json, result.txt, <name>.png).
///
///   state                       dump stores, FSM, layout, engine and perf counters
///   shot?name=x[&full=1]        PNG of the island (or the whole panel); desktop panel as x-desktop.png
///   fsm?input=click|reveal|collapse|hide|pointerEntered|pointerLeft|greetingComplete|launch
///   view?name=ask               open an expanded view
///   voice?text=…               route words as if spoken (start=1/stop=1 · file=/path.wav · cancel=1 · pick=slug)
///   meeting?start=1             stop=1 · mark=text · mic=/a.wav&sys=/b.wav (files as a meeting) · detect=1 · rename=p2:Alice · merge=p3:p2
///   emote?name=happy            trigger an emote on the main slime
///   agent?state=working         set the main slime's agent state
///   mini?id=a&state=working     spawn/update a mini     endmini?id=a      remove it
///   split greet sleep wake drop chew(?seconds=) listen(?seconds=)
///   press?x=&y=  release  click?x=&y=[&count=1]  hold?x=&y=&seconds=
///   click?real=1&x=&y=[&warp=1] synthesised mouse down/up through the panel (AppKit hit-testing, reaches card buttons)
///   arms?pose=<pose>[&seconds=]      one-off arm pose (wave, thumbsUp, cheer, holdSide:phone:-1, hug:heart, hug:self, sip…)
///   chew?[kind=pdf][&seconds=]        eat a pretend file; chew?phase=biting:0.5|digesting|filing drives the timeline
///   look?palette=ruby | hue=&sat=&light= | look=cat | minis=lighter|same | outfit=king | headwear=&eyewear=&wrap=&charm= | dress=1|0 | occasion=reading|call|rest|working | pack=puni|classic | voice=1|0 | reset=1
///   pointer?x=&y= (island coords) | pointer?sx=&sy= (screen) | pointer?away=1
///   desktop?on=1|0 | desktop?sx=&sy=
@MainActor
enum DebugCommands {
    static var dir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mochlet/debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Per-launch secret: every command must carry `token=<contents of debug/token>` so another
    /// local process cannot drive the app just by opening a URL. The file is 0600.
    static let token: String = {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        let url = dir.appendingPathComponent("token")
        try? t.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return t
    }()

    /// File names for screenshots: letters, digits, `-` and `_` only.
    static func safeName(_ raw: String?) -> String {
        let cleaned = (raw ?? "shot").unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        let s = String(String.UnicodeScalarView(cleaned)).prefix(48)
        return s.isEmpty ? "shot" : String(s)
    }

    static func run(_ url: URL, app: AppCoordinator) {
        let cmd = url.pathComponents.dropFirst().first ?? ""
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func arg(_ k: String) -> String? { items.first { $0.name == k }?.value }
        func num(_ k: String) -> Double? { arg(k).flatMap(Double.init) }
        guard arg("token") == token else {
            try? "unauthorised: pass token=$(cat ~/Library/Logs/Mochlet/debug/token)".write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            return
        }
        var result = "ok \(cmd)"
        let stage = app.slime.stage
        switch cmd {
        case "state":
            result = writeState(app)
        case "shot":
            if arg("window") == "settings" {
                // The Settings window (opened first with settings?tab=).
                if let w = app.settingsWindow?.window, let img = capture(w, crop: nil) { result = write(img, name: safeName(arg("name"))) } else { result = "no settings window" }
            } else {
                result = shot(app, name: safeName(arg("name")), full: arg("full") == "1")
            }
        case "settings":
            // settings?tab=general|agents|chat|projects|knowledge|voice|signals | close=1 | scroll=bottom|top|<points>
            if arg("close") != nil { app.settingsWindow?.close() } else { app.openSettings(tab: arg("tab")) }
            if let where_ = arg("scroll"), let content = app.settingsWindow?.window?.contentView {
                func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollViews) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    for sv in scrollViews(content) {
                        guard let doc = sv.documentView else { continue }
                        let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
                        let y = where_ == "bottom" ? maxY : min(maxY, CGFloat(Double(where_) ?? 0))
                        sv.contentView.scroll(to: NSPoint(x: 0, y: sv.documentView?.isFlipped == true ? y : 0))
                        sv.reflectScrolledClipView(sv.contentView)
                    }
                }
            }
        case "menu":
            // menu: the right-click menu's titles, submenus flattened, to prove the Dress up / Look menus build
            result = app.contextMenu().items.map { item in
                item.isSeparatorItem ? "—" : item.title + (item.submenu.map { " ▸ " + $0.items.filter { !$0.isSeparatorItem }.map { ($0.state == .on ? "*" : "") + $0.title }.joined(separator: "/") } ?? "")
            }.joined(separator: " | ")
        case "diag":
            // diag?logs=1 (export, result = path) | clean=1 (housekeeping, result = files/bytes) | perms=1 (result = rows) | whatsnew=1
            if arg("logs") != nil {
                do { result = try Diagnostics.exportLogs().path } catch { result = "export failed: \(error.localizedDescription)" }
            } else if arg("clean") != nil {
                let s = Diagnostics.housekeeping()
                result = "removed \(s.files) files, \(s.bytes) bytes"
            } else if arg("perms") != nil {
                app.permissions.refresh()
                result = app.permissions.rows.map { "\($0.kind.rawValue)=\($0.status.label)" }.joined(separator: " | ")
            } else if arg("whatsnew") != nil {
                app.openWhatsNew()
            }
        case "fsm":
            let input: NotchFSM.Input?
            switch arg("input") ?? "" {
            case "click": input = .click
            case "reveal": input = .reveal
            case "collapse": input = .collapse
            case "hide": input = .hide
            case "pointerEntered": input = .pointerEntered
            case "pointerLeft": input = .pointerLeft
            case "greetingComplete": input = .greetingComplete
            case "launch": input = .launch
            case "userInteracted": input = .userInteracted
            case "acknowledged": input = .acknowledged(delay: num("delay"))
            case "pin": input = nil; app.notch.isPinned.toggle(); result = "ok pin \(app.notch.isPinned)"
            default: input = nil
            }
            if let input { app.window.send(input) } else if !result.hasPrefix("ok pin") { result = "unknown input" }
        case "view":
            // view?name=<view>[&by=user]: a notification by default, the user's own opening with by=user
            if let v = NotchView(rawValue: arg("name") ?? "") { app.window.send(arg("by") == "user" ? .open(v) : .openExternally(v)) } else { result = "unknown view" }
        case "emote":
            if let e = SlimeEmote(rawValue: arg("name") ?? "") { stage.main.trigger(e) } else { result = "unknown emote" }
        case "agent":
            if let s = AgentState(rawValue: arg("state") ?? "") { stage.main.agent(s) } else { result = "unknown state" }
        case "mini":
            let id = arg("id") ?? "a"
            if stage.mini(id) == nil { stage.spawnMini(id: id) }
            if let s = AgentState(rawValue: arg("state") ?? "working") { stage.setMiniState(id, s) }
            app.notch.miniCount = stage.minis.count
        case "endmini":
            stage.removeMini(arg("id") ?? "a")
            app.notch.miniCount = max(0, stage.minis.count - 1)
        case "split": stage.split(extra: Int(num("extra") ?? 0))
        case "greet": stage.main.greet()
        case "sleep": stage.main.sleepNow()
        case "wake": stage.main.wake()
        case "drop": app.dropped(urls: [URL(fileURLWithPath: "/tmp/mochlet-debug.txt")], text: nil)
        case "chew":
            // chew?[kind=pdf][&seconds=1.5] start eating and finish after seconds | phase=biting:0.5|digesting|filing
            if let p = arg("phase") {
                if let phase = ChewPhase.parse(p) { stage.main.setChewPhase(phase) } else { result = "unknown phase" }
            } else {
                stage.main.drop(kind: Prop.FileKind(rawValue: arg("kind") ?? "") ?? .doc)
                DispatchQueue.main.asyncAfter(deadline: .now() + (num("seconds") ?? 1.5)) { MainActor.assumeIsolated { stage.main.ingestionFinished() } }
            }
        case "arms":
            // arms?pose=wave:1|holdSide:phone:-1|thumbsUp|cheer|…[&seconds=2]
            if let p = ArmPose.parse(arg("pose") ?? "") { stage.main.gesture(p, for: num("seconds") ?? 2) } else { result = "unknown pose" }
        case "listen":
            stage.main.startListening()
            DispatchQueue.main.asyncAfter(deadline: .now() + (num("seconds") ?? 1.5)) { MainActor.assumeIsolated { stage.main.stopListening(hadSpeech: true) } }
        case "press":
            app.slimePressed(atIsland: islandPoint(app, num("x"), num("y")))
        case "release":
            app.slimeReleased(screen: NSEvent.mouseLocation)
        case "click" where arg("real") != nil:
            // Real AppKit dispatch: the panel hit-tests its view tree for a synthesised event exactly as
            // it does for one from the window server, so this reaches SwiftUI buttons under the slime view.
            let p = islandPoint(app, num("x"), num("y"))
            let w = app.window!
            let r = w.islandScreenRect()
            let screen = NSPoint(x: r.minX + p.x, y: r.maxY - p.y)
            if arg("warp") != nil { warp(screen) }
            let count = Int(num("count") ?? 1)
            for i in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.18) {
                    MainActor.assumeIsolated { postClick(in: w.window!, screen: screen, clickCount: i + 1) }
                }
            }
            let m = NSEvent.mouseLocation
            result = "ok click real island (\(Int(p.x)), \(Int(p.y))) screen (\(Int(screen.x)), \(Int(screen.y))) cursor (\(Int(m.x)), \(Int(m.y))) ignoresMouse \(w.window!.ignoresMouseEvents)"
        case "look":
            var c = app.settings.character
            if let name = arg("palette") { c.selectPalette(name) }
            if num("hue") != nil || num("sat") != nil || num("light") != nil {
                c.setCustom(hue: num("hue"), saturation: num("sat"), lightness: num("light"))
            }
            if let name = arg("look") { c.selectLook(name) }
            if let m = arg("minis") { c.lighterMinis = m == "lighter" }
            if let set = arg("outfit") { c.outfit = SlimeOutfit.set(named: set) ?? SlimeOutfit() }
            if let h = arg("headwear") { c.outfit.headwear = SlimeOutfit.Headwear(rawValue: h) ?? .none }
            if let e = arg("eyewear") { c.outfit.eyewear = SlimeOutfit.Eyewear(rawValue: e) ?? .none }
            if let w = arg("wrap") { c.outfit.wrap = SlimeOutfit.Wrap(rawValue: w) ?? .none }
            if let ch = arg("charm") { c.outfit.charm = SlimeOutfit.Charm(rawValue: ch) ?? .none }
            if let d = arg("dress") { c.dressForOccasion = d == "1" }
            if let o = arg("occasion") { app.slime.stage.main.occasion = SlimeEngine.Occasion(rawValue: o) }
            if let pk = arg("pack"), SoundPack(rawValue: pk) != nil { c.soundPack = pk }
            if let v = arg("voice") { c.voiceSqueaks = v == "1" }
            if arg("reset") != nil { c = CharacterConfig() }
            app.settings.character = c
            app.applySettings()
            result = "ok look \(c.lookName) outfit \(c.outfit.setName ?? "custom") palette \(c.paletteName) mid #\(String(format: "%06X", c.palette.mid.hex)) ink #\(String(format: "%06X", c.palette.ink.hex)) pack \(app.slime.sound.pack.rawValue) voice \(app.slime.sound.voiceEnabled)"
        case "click":
            let p = islandPoint(app, num("x"), num("y"))
            let count = Int(num("count") ?? 1)
            for i in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.18) {
                    MainActor.assumeIsolated {
                        app.slimePressed(atIsland: p)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { MainActor.assumeIsolated { app.slimeReleased(screen: NSEvent.mouseLocation) } }
                    }
                }
            }
        case "drag":
            // Press the slime, drag it to screen point (sx, sy) over ~0.6 s and drop it there, warping the
            // real cursor along the way so the drag-out session and the desktop panel see the same path.
            let target = NSPoint(x: num("sx") ?? 0, y: num("sy") ?? 0)
            let start: NSPoint
            if app.desktop.isActive, let f = app.desktop.panelFrame {
                start = NSPoint(x: f.midX, y: f.minY + 22 + DesktopSlimeController.radius * 0.8)
            } else {
                let p = islandPoint(app, nil, nil)
                let r = app.window.islandScreenRect()
                start = NSPoint(x: r.minX + p.x, y: r.maxY - p.y)
            }
            warp(start)
            if app.desktop.isActive {
                app.slime.stage.main.pressBegan(at: app.desktop.localPoint(start))
            } else {
                app.slimePressed(atIsland: islandPoint(app, nil, nil))
            }
            let steps = 12
            for i in 1...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(i)) {
                    MainActor.assumeIsolated {
                        let t = Double(i) / Double(steps)
                        let q = NSPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t)
                        warp(q)
                        if app.desktop.isDragging {
                            app.desktop.dragMoved(screen: q)
                        } else if app.desktop.isActive {
                            app.slime.stage.main.pressMoved(to: app.desktop.localPoint(q))
                        } else {
                            let r = app.window.islandScreenRect()
                            app.slimeMoved(toIsland: CGPoint(x: q.x - r.minX, y: r.maxY - q.y), screen: q)
                        }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(steps + 2)) {
                MainActor.assumeIsolated {
                    if app.desktop.isDragging {
                        app.desktop.dragEnded(screen: target)
                    } else if app.desktop.isActive {
                        app.slime.stage.main.pressEnded()
                    } else {
                        app.slimeReleased(screen: target)
                    }
                }
            }
        case "hold":
            app.slimePressed(atIsland: islandPoint(app, num("x"), num("y")))
            DispatchQueue.main.asyncAfter(deadline: .now() + (num("seconds") ?? 1.2)) { MainActor.assumeIsolated { app.slimeReleased(screen: NSEvent.mouseLocation) } }
        case "pointer":
            let screenPoint: NSPoint
            if arg("away") == "1" {
                let f = NSScreen.main?.frame ?? .zero
                screenPoint = NSPoint(x: f.midX, y: f.midY)
            } else if let sx = num("sx"), let sy = num("sy") {
                screenPoint = NSPoint(x: sx, y: sy)
            } else {
                let p = islandPoint(app, num("x"), num("y"))
                let r = app.window.islandScreenRect()
                screenPoint = NSPoint(x: r.minX + p.x, y: r.maxY - p.y)
            }
            warp(screenPoint)
        case "desktop":
            if let sx = num("sx"), let sy = num("sy") {
                if app.desktop.isActive { app.desktop.move(toCenter: NSPoint(x: sx, y: sy)) }
                else { app.desktop.flyOut(to: NSPoint(x: sx, y: sy), from: app.window.mainSlimeScreenRect()) }
            } else if arg("on") == "0" {
                app.desktop.flyHome()
            } else {
                app.desktop.flyOut(to: app.desktop.savedCenter() ?? app.desktop.defaultCenter(), from: app.window.mainSlimeScreenRect())
            }
        case "hook":
            // hook?line=<url-encoded JSON>   inject one relay line (blocking lines get a reply that logs to result.txt)
            if let line = arg("line") {
                let data = Data(line.utf8)
                if HookSocketServer.wantsReply(data) {
                    let reply = LoggingReply(dir: dir)
                    app.hooks.inject(data, reply: reply.handle)
                } else {
                    app.hooks.inject(data)
                }
                result = "ok hook \(app.hooks.lineCount) lines, \(app.sessions.live.count) live"
            }
        case "hookfile":
            // hookfile?path=<jsonl>&delay=0.4   replay a fixture, one line per `delay` seconds
            if let path = arg("path"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let delay = num("delay") ?? 0.4
                let lines = text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                for (i, l) in lines.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay * Double(i)) {
                        MainActor.assumeIsolated { AppCoordinator.shared.hooks.inject(Data(l.utf8)) }
                    }
                }
                result = "ok replaying \(lines.count) lines"
            }
        case "approve":
            if let d = arg("decision").flatMap(ApprovalDecision.init(rawValue:)) { app.approvals.decide(d) }
            result = "ok approvals pending \(app.approvals.count)"
        case "answer":
            // answer?pick=Label | answer?other=text | answer?action=next|back|terminal
            if let pick = arg("pick") { app.questions.toggle(pick) }
            if let other = arg("other") { app.questions.setOther(other); app.questions.submitOther() }
            switch arg("action") {
            case "next": app.questions.advance()
            case "back": app.questions.back()
            case "terminal": app.questions.handBack()
            default: break
            }
            result = "ok question pending \(app.questions.pending != nil)"
        case "session":
            if let id = arg("id") { app.openSession(id) } else { app.openSession(nil) }
        case "jump":
            result = app.terminal.jump(to: app.sessions.card(arg("id")) ?? app.sessions.focused) ? "ok jumped: \(app.terminal.lastResult)" : "no terminal"
        case "chat":
            // chat?text=…[&provider=claude-cli][&model=…]   send a message; chat?new=1 starts a thread
            if let pr = arg("provider").flatMap(ChatProviderKind.init(rawValue:)) { app.chat.setProvider(pr) }
            if let m = arg("model") { app.chat.setModel(m) }
            if arg("new") != nil { app.chat.newThread() }
            if let t = arg("text") { app.openChat(); app.chat.send(t) } else { app.openChat() }
        case "chatstop":
            app.chat.cancel()
        case "attach":
            if let w = WindowContextCapture.frontmostWindow() { app.attachWindow(w) } else { result = "no frontmost window" }
        case "project":
            // project?add=/path[&name=x] | project?remove=slug | project?offer=/path
            if let path = arg("add") { app.projects.add(path: path, name: arg("name")) }
            if let slug = arg("remove") { app.projects.remove(slug) }
            if let path = arg("offer") { app.projects.offer(folder: URL(fileURLWithPath: path)); app.openProjects() }
            if arg("open") != nil { app.openProjects() }
        case "meeting":
            // meeting?start=1 | stop=1 | mark=text | mic=/a.wav&sys=/b.wav[&title=] (process files as a meeting) | detect=1 | rename=p2:Alice | merge=p3:p2 | open=1 | dismiss=1
            let m = app.meetings!
            if arg("start") != nil { m.toggle() }
            else if arg("stop") != nil { m.stop() }
            else if let t = arg("mark") { m.mark(t) }
            else if arg("dismiss") != nil { m.dismiss() }
            else if arg("open") != nil { app.openMeetings() }
            else if arg("detect") != nil {
                let s = m.debugSignal()
                result = "signal: mic=\(s.micApps) front=\(s.frontBundleID ?? "-") title=\(s.windowTitle ?? "-") url=\(s.browserURL ?? "-") → \(MeetingDetectionRules.evaluate(s).map { "\($0.appName): \($0.reason)" } ?? "no call")"
            }
            else if let r = arg("rename"), let c = r.firstIndex(of: ":") { m.rename(String(r[..<c]), to: String(r[r.index(after: c)...])) }
            else if let r = arg("merge"), let c = r.firstIndex(of: ":") { m.merge(String(r[..<c]), into: String(r[r.index(after: c)...])) }
            else if let mic = arg("mic") {
                result = "pending meeting"
                let resultFile = dir.appendingPathComponent("result.txt")
                let sys = arg("sys"), title = arg("title")
                Task { @MainActor in
                    let line = await m.processFiles(mic: URL(fileURLWithPath: mic), system: sys.map { URL(fileURLWithPath: $0) }, title: title)
                    try? line.write(to: resultFile, atomically: true, encoding: .utf8)
                }
            }
        case "signals":
            // signals?run=1 | digest=1 | detect=url | add=feed|list | import=/path.json | newtoken=1 | pushtest=1 | push=1 (inbox file) | status=1 | reload=1
            let s = app.signals!
            if arg("run") != nil { s.runNow() }
            else if arg("digest") != nil { s.composeDigestNow() }
            else if let u = arg("detect") { s.detect(u) }
            else if let a = arg("add") { s.addDetected(asList: a == "list") }
            else if let p = arg("import") { s.importAIHOT(URL(fileURLWithPath: p)) }
            else if arg("newtoken") != nil { s.regeneratePushToken() }
            else if arg("pushtest") != nil {
                // Posts two items to the local endpoint with the stored token; the answer lands in result.txt.
                result = "pending push"
                let resultFile = dir.appendingPathComponent("result.txt")
                Task { @MainActor in
                    let line = await s.debugPushTest()
                    try? line.write(to: resultFile, atomically: true, encoding: .utf8)
                }
            }
            else if arg("push") != nil { s.processInbox() }
            else if arg("reload") != nil { s.reloadRubric() }
            else if arg("recluster") != nil { s.reclusterNow() }
            else { s.refreshStatus() }
        case "voice":
            // voice?text=…  route an utterance as if spoken | start=1 / stop=1 push-to-talk | file=/path.wav plays the microphone | cancel=1 | pick=slug answers "which project"
            if let t = arg("text") {
                result = "pending voice"
                let resultFile = dir.appendingPathComponent("result.txt")
                Task { @MainActor in
                    await app.voice.handle(text: t)
                    let v = app.voice!
                    let line = "voice: \(v.lastAction ?? v.state.description) | \(v.lastIntent.map { "\($0.intent.rawValue) \($0.backend)" } ?? "no intent")"
                    try? line.write(to: resultFile, atomically: true, encoding: .utf8)
                }
            } else if arg("start") != nil { app.voice.begin() }
            else if arg("stop") != nil { app.voice.end() }
            else if arg("cancel") != nil { app.voice.cancel() }
            else if let f = arg("file") { app.voice.beginFromFile(URL(fileURLWithPath: f)) }
            else if let p = arg("pick") { app.voice.answerPending(project: p == "cancel" ? nil : app.projects.match(p)) }
        case "ask":
            // ask?text=…   what the ask bubble would do with this text
            if let t = arg("text") { app.notch.askText = t; app.submitAsk() }
        case "workon":
            // workon?project=&task=[&agent=claude][&headless=1]
            if let name = arg("project"), let p = app.projects.match(name), let task = arg("task") {
                let agent = AgentKind(tag: arg("agent") ?? "claude", bundleID: nil, termProgram: nil)
                if arg("headless") != nil, p.trusted, let cwd = p.primaryPath { app.headless.start(agent: agent, project: p, cwd: cwd, task: task, resume: nil) }
                else if arg("headless") != nil { result = "project is not trusted for background runs" }
                else { app.startWork(project: p, task: task, agent: agent) }
            } else { result = "unknown project" }
        case "settings":
            // settings?tab=agents[&shot=1]   open the Settings window on a tab; shot writes settings.png
            app.openSettings()
            if let tab = arg("tab") { app.settingsWindow?.show(tab: tab) }
            if arg("shot") != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    MainActor.assumeIsolated {
                        if let png = AppCoordinator.shared.settingsWindow?.snapshot() { try? png.write(to: dir.appendingPathComponent("settings.png")) }
                    }
                }
            }
        case "kb":
            // kb?find=…[&k=5] | ask=… | reindex=1 | lint=1 | file=1 | add=/path | text=…[&title=] | url=… | open=1
            // add/text/url take &force=1 (re-chew) and &question=1 (always show the project question); pick=slug|inbox · move=slug|inbox · window=1 · retry=1
            // Async commands write "pending" now and overwrite result.txt when done.
            let resultFile = dir.appendingPathComponent("result.txt")
            let later: @Sendable (String) -> Void = { text in
                try? text.write(to: resultFile, atomically: true, encoding: .utf8)
            }
            if arg("open") != nil { app.openKnowledge() }
            let force = arg("force") != nil
            if arg("question") != nil { app.ingest.askNext = true }
            if let q = arg("find") {
                result = "pending find"
                let k = Int(num("k") ?? 8)
                Task { @MainActor in
                    let hits = await AppCoordinator.shared.knowledge.find(q, k: k)
                    later(hits.isEmpty ? "no hits" : hits.map { "\($0.path):\($0.lineStart) \($0.title) › \($0.headingPath) | \(OneLine.collapse($0.text, limit: 120))" }.joined(separator: "\n"))
                }
            } else if let q = arg("ask") {
                app.openKnowledge(question: q)
                result = "asking"
            } else if arg("reindex") != nil {
                app.knowledge.reindex(force: arg("force") != nil)
            } else if arg("lint") != nil {
                app.knowledge.lint()
                result = "linting"
            } else if arg("file") != nil {
                app.knowledge.fileAnswer()
                result = "filing"
            } else if let path = arg("add") {
                result = "pending add"
                Task { @MainActor in
                    let f = await AppCoordinator.shared.knowledge.add(.file(URL(fileURLWithPath: path)), from: "debug", force: force)
                    later(f.map { "\($0.existing ? "existing" : "filed") \($0.path) | \($0.title)" } ?? "failed: \(AppCoordinator.shared.knowledge.lastError ?? "?")")
                }
            } else if let p = arg("pick") {
                app.ingest.choose(p == "inbox" ? nil : p)
                result = "picked \(p)"
            } else if let p = arg("move") {
                result = "pending move"
                Task { @MainActor in
                    let f = await AppCoordinator.shared.ingest.moveLast(toProject: p == "inbox" ? nil : p)
                    later(f.map { "moved \($0.path)" } ?? "move failed")
                }
            } else if arg("window") != nil {
                app.saveWindowContext()
                result = "saving window"
            } else if arg("retry") != nil {
                app.ingest.retryLast()
                result = "retrying"
            } else if let text = arg("text") {
                result = "pending text"
                let title = arg("title")
                Task { @MainActor in
                    let f = await AppCoordinator.shared.knowledge.add(.text(text, title: title), from: "debug")
                    later(f.map { "\($0.existing ? "existing" : "filed") \($0.path) | \($0.title)" } ?? "failed: \(AppCoordinator.shared.knowledge.lastError ?? "?")")
                }
            } else if let u = arg("url"), let url = URL(string: u) {
                result = "pending url"
                Task { @MainActor in
                    let f = await AppCoordinator.shared.knowledge.add(.link(url), from: "debug", force: force)
                    later(f.map { "\($0.existing ? "existing" : "filed") \($0.path) | \($0.title)" } ?? "failed: \(AppCoordinator.shared.knowledge.lastError ?? "?")")
                }
            }
        case "quit":
            NSApp.terminate(nil)
        default:
            result = "unknown command \(cmd)"
        }
        try? result.write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }

    /// Sends a left mouse down then up at an AppKit screen point through `window`'s own event path.
    private static func postClick(in window: NSWindow, screen: NSPoint, clickCount: Int) {
        let wp = window.convertPoint(fromScreen: screen)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0)
        }
        if let down = event(.leftMouseDown) { window.sendEvent(down) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            MainActor.assumeIsolated { if let up = event(.leftMouseUp) { window.sendEvent(up) } }
        }
    }

    /// Moves the real cursor to an AppKit screen point (no permission needed).
    private static func warp(_ p: NSPoint) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: top - p.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private static func islandPoint(_ app: AppCoordinator, _ x: Double?, _ y: Double?) -> CGPoint {
        let o = app.notch.slimeOrigin
        return CGPoint(x: x ?? (o.x), y: y ?? (o.y - Double(app.slime.radius) * 0.9))
    }

    // MARK: - State dump

    private static func writeState(_ app: AppCoordinator) -> String {
        let n = app.notch
        let stage = app.slime.stage
        let main = stage.main
        let w = app.window!
        var d: [String: Any] = [:]
        d["mode"] = n.mode.rawValue
        d["view"] = n.view.rawValue
        d["fsm"] = "\(w.fsmState)"
        d["geometry"] = ["width": n.geometry.width, "height": n.geometry.height, "hasNotch": n.geometry.hasNotch]
        d["targetSize"] = ["width": n.islandSize.width, "height": n.islandSize.height]
        d["liveSize"] = ["width": n.liveWidth, "height": n.liveHeight, "corner": n.liveCorner]
        d["targetSlimeOrigin"] = ["x": n.targetSlimeOrigin.x, "y": n.targetSlimeOrigin.y]
        d["liveSlimeOrigin"] = ["x": n.liveSlimeOrigin.x, "y": n.liveSlimeOrigin.y]
        d["radius"] = app.slime.radius
        d["targetRadius"] = app.slime.targetRadius
        d["slimeOnDesktop"] = n.slimeOnDesktop
        d["pointer"] = app.slime.pointer.map { ["x": $0.x, "y": $0.y] } ?? "nil"
        d["pointerInside"] = n.pointerInside
        d["isPinned"] = n.isPinned
        d["heldOpen"] = w.heldOpen
        d["holds"] = w.holds.map { "\($0.key):\($0.scope)" }.sorted()
        d["pendingCard"] = w.pendingCard?.rawValue ?? "none"
        d["timers"] = Dictionary(uniqueKeysWithValues: w.timerRemaining.map { ($0.key.rawValue, (($0.value * 10).rounded()) / 10) })
        d["lastInteractionAgo"] = Date().timeIntervalSince(w.lastInteraction)
        d["liveX"] = n.liveX
        d["islandTargetX"] = n.islandTargetX
        d["compactRightWidth"] = n.compactRightWidth
        d["main"] = ["state": main.state.rawValue, "emote": main.emote?.rawValue ?? "none", "root": [main.body.root.x, main.body.root.y],
                     "isAway": main.isAway, "opacity": main.opacity]
        d["arms"] = ["pose": main.armPose.name, "chew": main.chewPhase?.name ?? "none", "bites": main.bites, "occasion": main.occasion?.rawValue ?? "none"]
        let offsets = Dictionary(uniqueKeysWithValues: stage.miniOffsets().map { ($0.id, ($0.x, $0.slotX)) })
        d["minis"] = stage.minis.map { ["id": $0.id, "phase": "\($0.phase)", "slot": $0.slot, "state": $0.engine.state.rawValue,
                                       "x": offsets[$0.id]?.0 ?? 0, "slotX": offsets[$0.id]?.1 ?? 0] }
        let c = app.settings.character
        d["appearance"] = ["look": c.lookName, "palette": c.paletteName, "custom": [c.hue, c.saturation, c.lightness],
                           "mid": String(format: "#%06X", c.palette.mid.hex), "ink": String(format: "#%06X", c.palette.ink.hex),
                           "lighterMinis": c.lighterMinis, "stagePalette": main.appearance.palette.name,
                           "miniPalettes": stage.minis.map { String(format: "#%06X", $0.engine.appearance.palette.mid.hex) }]
        d["sound"] = ["pack": app.slime.sound.pack.rawValue, "voice": app.slime.sound.voiceEnabled, "enabled": app.slime.sound.isEnabled,
                      "volume": app.slime.sound.masterVolume, "plays": app.slime.sound.playCount,
                      "greet": "\(app.slime.sound.source(of: .greet))", "puni": "\(app.slime.sound.source(of: .puni))"]
        d["miniCount"] = n.miniCount
        d["probe"] = ["fps": app.slime.probe.fps, "msPerDraw": app.slime.probe.msPerDraw, "cpuPercent": app.slime.probe.cpuPercent]
        d["islandView"] = ["ticks": w.debugCounters.ticks, "redraws": w.debugCounters.redraws, "paused": w.debugCounters.paused]
        d["panelFrame"] = rect(w.window!.frame)
        d["islandScreenRect"] = rect(w.islandScreenRect())
        d["desktop"] = ["phase": "\(app.desktop.phase)", "frame": app.desktop.panelFrame.map(rect) ?? "nil", "dragging": app.desktop.isDragging]
        d["mouse"] = ["x": NSEvent.mouseLocation.x, "y": NSEvent.mouseLocation.y]
        d["ignoresMouse"] = w.window!.ignoresMouseEvents
        d["toast"] = n.toast?.text ?? ""
        d["ticker"] = n.tickerText
        d["cardNote"] = n.cardNote ?? ""
        d["focusedSession"] = n.focusedSessionID ?? ""
        d["sessions"] = app.sessions.cards.map { c in
            ["id": c.id, "agent": c.agent.id, "project": c.label, "state": c.state.rawValue, "steps": c.steps.map(\.text), "diffs": c.diffs.count,
             "finalLine": c.finalLine ?? "", "cwd": c.cwd, "terminal": c.terminal.terminalName ?? "", "tty": c.terminal.tty ?? ""] as [String: Any]
        }
        d["approvals"] = app.approvals.queue.items.map { ["id": $0.id.uuidString, "tool": $0.tool, "command": $0.command, "session": $0.sessionID] }
        d["question"] = app.questions.pending.map { ["index": $0.index, "questions": $0.question.questions.map(\.text), "selections": $0.selections] as [String: Any] } ?? "nil"
        d["hooks"] = ["lines": app.hooks.lineCount, "invalid": app.hooks.invalidCount, "running": app.hooks.isRunning, "socket": app.hooks.socketPath, "relay": app.hooks.relayPath?.path ?? ""]
        d["plans"] = ["claude": app.plans.claude.map { "\($0.dominantPercent(now: Date()))" } ?? "nil", "codex": app.plans.codex.map { "\($0.dominantPercent(now: Date()))" } ?? "nil"]
        d["chat"] = ["provider": app.chat.providerKind.rawValue, "model": app.chat.model, "input": app.chat.input, "thread": app.chat.current?.id ?? "", "title": app.chat.current?.title ?? "",
                     "streaming": app.chat.isStreaming, "streamingText": String(app.chat.streamingText.suffix(200)), "activity": app.chat.streamingActivity,
                     "messages": app.chat.messages.map { ["role": $0.role.rawValue, "text": String($0.text.prefix(300)), "error": $0.error ?? "", "attachments": $0.attachments.map(\.title)] as [String: Any] },
                     "pending": app.chat.pendingAttachments.map(\.title), "threads": app.chat.threads.count, "error": app.chat.lastError ?? ""] as [String: Any]
        d["projects"] = ["count": app.projects.projects.count, "offer": app.projects.pendingOffer?.path ?? "", "note": app.projects.note ?? "", "clone": app.projects.cloneStatus ?? "",
                         "terminal": app.projects.preferredTerminal.rawValue,
                         "list": app.projects.projects.map { ["slug": $0.slug, "name": $0.name, "path": $0.primaryPath ?? "", "agent": $0.defaultAgent ?? "", "sessions": $0.lastSessions] as [String: Any] }] as [String: Any]
        d["headless"] = app.headless.runs.map { ["session": $0.key, "agent": $0.value.agent.id, "text": String($0.value.text.suffix(120))] }
        let kb = app.knowledge!
        let mt = app.meetings!
        d["meeting"] = ["state": "\(mt.state)", "title": mt.current?.title ?? mt.last?.meta.title ?? "", "elapsed": mt.elapsed, "lines": mt.liveLines.count,
                        "live": mt.liveLines.suffix(3).map { "\($0.speaker): \($0.text)" }, "stage": mt.stage, "progress": mt.progress, "error": mt.error ?? "",
                        "folder": mt.last?.folder.path ?? "", "speakers": mt.last?.meta.speakers.map(\.name) ?? [], "kb": mt.last?.meta.kbPath ?? "",
                        "summary": mt.last?.summary?.overview ?? "", "recent": mt.recent.count, "ask": mt.detection?.appName ?? "", "systemAudio": mt.systemAudioError ?? "ok",
                        "micLevel": mt.micLevel, "systemLevel": mt.systemLevel] as [String: Any]
        d["signals"] = app.signals!.debugState()
        app.permissions.refresh()
        d["permissions"] = Dictionary(uniqueKeysWithValues: app.permissions.rows.map { ($0.kind.rawValue, $0.status.label) })
        let v = app.voice!
        d["voice"] = ["state": v.state.description, "caption": v.caption, "transcript": v.transcript, "heard": v.lastHeard, "action": v.lastAction ?? "", "error": v.error ?? "",
                      "locale": v.localeID, "pending": v.pending?.question ?? "", "assets": v.assetState.map { "\($0)" } ?? "", "download": v.downloadProgress ?? -1,
                      "decisions": Decisions.describe(app: app), "speak": app.settings.voiceSpeakReplies, "setting": app.settings.voiceLocale,
                      "intent": v.lastIntent.map { "\($0.intent.rawValue) project=\($0.project?.slug ?? "") task=\($0.task ?? "") url=\($0.url?.absoluteString ?? "") backend=\($0.backend) conf=\(String(format: "%.2f", $0.confidence))" } ?? ""] as [String: Any]
        d["knowledge"] = ["root": kb.root.path, "ready": kb.ready, "pages": kb.counts.pages, "chunks": kb.counts.chunks, "references": kb.counts.references,
                          "embedded": kb.counts.embedded, "pendingEmbeddings": kb.pendingEmbeddings, "status": kb.status ?? "", "error": kb.lastError ?? "",
                          "question": kb.question, "answering": kb.isAnswering, "answer": String(kb.answerText.suffix(400)),
                          "citations": kb.citations.map { "[\($0.n)] \($0.path):\($0.lineStart)" }, "filed": kb.answerFiled ?? "",
                          "lastFiled": kb.lastFiled.map { "\($0.path)" } ?? "", "lint": kb.lastFindings.map { "\($0.kind.rawValue): \($0.path)" },
                          "mcpPort": kb.mcpPort.map(Int.init) ?? 0, "mcpError": kb.mcpError ?? "", "embeddingNote": kb.embeddingNote ?? "", "chewing": kb.chewing] as [String: Any]
        let ing = app.ingest!
        d["ingest"] = ["jobs": ing.jobs.map { ["label": $0.label, "stage": $0.stage.rawValue, "progress": $0.progress, "project": $0.project ?? "", "path": $0.filed?.path ?? "",
                                              "title": $0.title ?? "", "summary": $0.summary ?? "", "error": $0.error ?? "", "integration": $0.integration ?? "", "routing": $0.routing ?? "",
                                              "detail": $0.detail ?? "", "warnings": $0.warnings] as [String: Any] },
                       "question": ing.question.map { q in ["job": q.jobID, "options": q.question.options.map { "\($0.slug ?? "inbox"):\(String(format: "%.2f", $0.confidence))" }, "suggested": q.question.suggested ?? "inbox"] as [String: Any] } ?? [:],
                       "brain": LLMClient.brain(app)?.label ?? "", "chewProgress": app.notch.chewProgress ?? -1] as [String: Any]
        d["time"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) else { return "state failed" }
        try? data.write(to: dir.appendingPathComponent("state.json"))
        return "state written"
    }

    /// A reply handle over a socket pair: whatever the app writes lands in debug/reply.txt.
    final class LoggingReply {
        let handle: HookReply
        private let reader: DispatchSourceRead
        private let readFD: Int32

        init(dir: URL) {
            var fds: [Int32] = [0, 0]
            _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
            handle = HookReply(fd: fds[0])
            readFD = fds[1]
            let url = dir.appendingPathComponent("reply.txt")
            try? "".write(to: url, atomically: true, encoding: .utf8)
            let fd = fds[1]
            reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
            reader.setEventHandler {
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = read(fd, &buf, buf.count)
                if n > 0, let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile()
                    h.write(Data(buf[0..<n]))
                    try? h.close()
                }
            }
            reader.resume()
            Self.live.append(self)
        }

        nonisolated(unsafe) static var live: [LoggingReply] = []
    }

    private static func rect(_ r: CGRect) -> [String: Double] {
        ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height]
    }

    // MARK: - Screenshots of our own windows (no screen-recording permission needed)

    private static func shot(_ app: AppCoordinator, name: String, full: Bool) -> String {
        guard let panel = app.window.window else { return "no panel" }
        var out: [String] = []
        let island = app.window.islandRect
        let crop = full ? nil : CGRect(x: island.minX - 12, y: island.minY - 12, width: island.width + 24, height: island.height + 24)
        if let img = capture(panel, crop: crop) {
            out.append(write(img, name: name))
        } else {
            out.append("island capture failed")
        }
        if let dp = app.desktop.panel, let img = capture(dp, crop: nil) {
            out.append(write(img, name: name + "-desktop"))
        }
        return out.joined(separator: "; ")
    }

    private static func capture(_ window: NSWindow, crop: CGRect?) -> CGImage? {
        // Our own window only: cacheDisplay needs no screen-recording permission (layer masks are not applied).
        guard let cv = window.contentView, let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else { return nil }
        cv.cacheDisplay(in: cv.bounds, to: rep)
        guard let img = rep.cgImage else { return nil }
        guard let crop else { return img }
        let scale = CGFloat(img.width) / window.frame.width
        // Window image is top-down; `crop` is in AppKit window coords (y up).
        let r = CGRect(x: crop.minX * scale, y: (window.frame.height - crop.maxY) * scale, width: crop.width * scale, height: crop.height * scale)
        return img.cropping(to: r.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))) ?? img
    }

    private static func write(_ img: CGImage, name: String) -> String {
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "png failed" }
        let url = dir.appendingPathComponent("\(name).png")
        do {
            try data.write(to: url)
            return url.path
        } catch {
            return "write failed: \(error)"
        }
    }
}
#endif
