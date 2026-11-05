import Foundation
import Testing
@testable import MochletCore

private func phrase(_ s: Double, _ e: Double, _ t: String) -> TimedPhrase { TimedPhrase(start: s, end: e, text: t) }

@Test func echoTokensAndSharedWordsRemoval() {
    #expect(EchoRemoval.tokens("Hello, World 42") == ["hello", "world", "42"])
    #expect(EchoRemoval.tokens("我们明天开会") == ["我们", "们明", "明天", "天开", "开会"])
    let mine = [phrase(0, 1, "let's ship on friday"), phrase(2, 3, "I agree"), phrase(10, 11, "我们明天开会吧")]
    let others = [phrase(0.2, 1.1, "let's ship on friday then"), phrase(10.1, 11, "我们明天开会")]
    let kept = EchoRemoval.removingShared(mine: mine, others: others)
    #expect(kept.map(\.text) == ["I agree"])
}

@Test func echoLevelsAnalysisFindsLagAndGain() {
    // The Mac plays a pattern; the microphone hears it 60 ms later at a quarter of the level, plus the user talking over frames 300–340.
    var sys = [Float](repeating: 0.001, count: 600)
    for (j, i) in stride(from: 50, to: 550, by: 40).enumerated() {
        for k in i..<(i + 20) { sys[k] = (0.08 + 0.03 * Float(j % 5)) * (1 + 0.5 * sin(Float(k) * 0.7)) }   // bursts of varying loudness
    }
    var mic = [Float](repeating: 0.002, count: 600)
    for i in 0..<600 where i >= 3 { mic[i] = sys[i - 3] * 0.25 + 0.002 }
    for i in 300..<340 { mic[i] = 0.3 }
    let a = EchoRemoval.analyze(mic: mic, sys: sys)
    #expect(a?.lag == 3)
    #expect(a.map { abs($0.gain - 0.25) < 0.08 } == true)
    let phrases = [phrase(1.0, 1.3, "echo of them"), phrase(6.0, 6.8, "me talking")]   // frames 50–65 (echo), 300–340 (mine)
    let r = EchoRemoval.removing(phrases, micLevels: mic, sysLevels: sys)
    #expect(r.removed == 1 && r.kept.first?.text == "me talking")
}

@Test func transcriptBuilderNamesSpeakersInOrderAndMergesLines() {
    let mine = [phrase(0, 1.0, "Hi everyone"), phrase(1.3, 2.0, "let's start"), phrase(30, 31, "ok")]
    let others = [phrase(3, 5, "Thanks"), phrase(5.5, 7, "first item"), phrase(10, 12, "I have a question"), phrase(12.5, 13, "about costs")]
    let turns = [SpeakerTurn(speaker: "s1", start: 3, end: 7), SpeakerTurn(speaker: "s2", start: 10, end: 13)]
    let (speakers, lines) = TranscriptBuilder.build(mine: mine, others: others, turns: turns)
    #expect(speakers.map(\.id) == ["me", "p2", "p3"] && speakers[0].isMe && speakers[1].name == "Person 2")
    #expect(lines.map(\.speaker) == ["me", "p2", "p3", "me"])
    #expect(lines[0].text == "Hi everyone let's start" && lines[2].text == "I have a question about costs")
    let (merged, mergedLines) = TranscriptBuilder.merge(lines, speakers: speakers, id: "p3", into: "p2")
    #expect(merged.map(\.id) == ["me", "p2"] && mergedLines.filter { $0.speaker == "p2" }.count == 2)
    #expect(TranscriptBuilder.rename(lines, speakers: speakers, id: "p2", to: "Alice")[1].name == "Alice")
    #expect(TranscriptBuilder.windows(lines, seconds: 20).count == 2)
    #expect(TranscriptBuilder.lines(from: [("me", phrase(0, 1, "我们")), ("me", phrase(1.2, 2, "明天开会"))])[0].text == "我们明天开会")
}

@Test func fragmentsGoToTheNearestSolidVoice() {
    let turns = [SpeakerTurn(speaker: "a", start: 0, end: 10, embedding: [1, 0]), SpeakerTurn(speaker: "b", start: 12, end: 20, embedding: [0, 1]),
                 SpeakerTurn(speaker: "c", start: 10.5, end: 11, embedding: [0.9, 0.1])]
    let merged = TranscriptBuilder.mergingFragments(turns)
    #expect(merged.map(\.speaker) == ["a", "b", "a"])
}

@Test func larkTranscriptRoundTrips() {
    var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 4; c.hour = 11; c.minute = 3; c.second = 33
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let start = cal.date(from: c)!
    let speakers = [MeetingSpeaker(id: "me", name: "Ilex Poon", isMe: true), MeetingSpeaker(id: "p2", name: "Person 2")]
    let lines = [MeetingLine(speaker: "p2", start: 20.68, end: 33, text: "AWS 这块你扫了一下费用，对吧？"), MeetingLine(speaker: "me", start: 33.18, end: 56.14, text: "其他的就是\n两个账号。")]
    let text = LarkTranscript.format(startedAt: start, duration: 2158, keywords: ["流量", "语音"], lines: lines, speakers: speakers, timeZone: cal.timeZone)
    #expect(text.hasPrefix("2026-11-04 11:03:33 CST|35min 58s\n\nKeywords:\n流量、语音\n\nPerson 2 00:00:20.680\nAWS 这块"))
    let parsed = LarkTranscript.parse(text)
    #expect(parsed.keywords == ["流量", "语音"] && parsed.names == ["Person 2", "Ilex Poon"])
    #expect(parsed.lines.count == 2 && parsed.lines[1].text == "其他的就是\n两个账号。" && abs(parsed.lines[1].start - 33.18) < 0.001 && abs(parsed.lines[0].end - 33.18) < 0.001)
    #expect(MeetingTime.duration(3912) == "1h 05min 12s" && MeetingTime.duration(42) == "42s" && MeetingTime.stamp(3661.5) == "01:01:01.500")
}

@Test func detectionRulesAndPrefs() {
    typealias R = MeetingDetectionRules
    #expect(R.evaluate(R.Signal(micApps: ["us.zoom.xos"], frontBundleID: "com.apple.Safari", windowTitle: "News"))?.appName == "Zoom")
    #expect(R.evaluate(R.Signal(micApps: ["com.google.Chrome"], frontBundleID: "com.google.Chrome", windowTitle: "Weekly sync")) == nil)   // a browser with the mic is not a call by itself
    #expect(R.evaluate(R.Signal(micApps: ["com.google.Chrome"], frontBundleID: "com.google.Chrome", windowTitle: "Meet – abc-defg-hij"))?.appName == "Google Meet")
    let meet = R.evaluate(R.Signal(micApps: ["com.google.Chrome"], frontBundleID: "com.google.Chrome", windowTitle: "Weekly sync", browserURL: "https://meet.google.com/abc-defg-hij"))
    #expect(meet?.appName == "Google Meet" && meet?.title == "Weekly sync")
    #expect(R.evaluate(R.Signal(micApps: ["com.google.Chrome"], frontBundleID: "com.google.Chrome", windowTitle: "YouTube", browserURL: "https://youtube.com")) == nil)
    let lark = R.evaluate(R.Signal(micApps: ["com.larksuite.macos.lark"], frontBundleID: "com.larksuite.macos.lark", windowTitle: "Lark Meeting · Roadmap"))
    #expect(lark?.appName == "Lark")
    #expect(R.evaluate(R.Signal(micApps: ["com.larksuite.macos.lark"], frontBundleID: "com.apple.Safari")) == nil)   // Lark holding the mic in the background is not a call
    #expect(R.evaluate(R.Signal(micApps: ["com.unknown.app"], frontBundleID: "com.unknown.app", windowTitle: "Zoom Meeting"))?.appName == "Zoom")
    #expect(R.evaluate(R.Signal(micApps: [], frontBundleID: "us.zoom.xos", windowTitle: "Zoom Meeting")) == nil)

    var prefs = MeetingPrefs()
    let d = R.Detection(bundleID: "us.zoom.xos", appName: "Zoom", title: "Zoom Meeting", reason: "")
    var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 6; c.hour = 23; c.minute = 30
    let cal = Calendar(identifier: .gregorian)
    let night = cal.date(from: c)!, day = night.addingTimeInterval(-12 * 3600)
    #expect(prefs.verdict(for: d, at: day) == .ask)
    prefs.quietStart = 22 * 60; prefs.quietEnd = 8 * 60
    #expect(prefs.isQuiet(at: night, calendar: cal) && !prefs.isQuiet(at: day, calendar: cal))
    #expect(prefs.verdict(for: d, at: night) == .ignore)
    prefs.apps["us.zoom.xos"] = .always
    #expect(prefs.verdict(for: d, at: day) == .capture)
    prefs.apps["us.zoom.xos"] = .ask
    prefs.snooze(d, at: day)
    #expect(prefs.verdict(for: d, at: day.addingTimeInterval(600)) == .ignore && prefs.verdict(for: d, at: day.addingTimeInterval(3600)) == .ask)
    prefs.apps["us.zoom.xos"] = .never
    #expect(prefs.verdict(for: d, at: day) == .ignore)
    let data = try! JSONEncoder().encode(prefs)
    #expect(try! JSONDecoder().decode(MeetingPrefs.self, from: data) == prefs)
}

@Test func speakerClusteringSeparatesTwoVoices() {
    let a: [Float] = [1, 0.1, 0, 0.2], b: [Float] = [0, 1, 0.1, 0]
    let feats = [a, b, a.map { $0 + 0.05 }, b.map { $0 * 1.3 }, a, b]
    let labels = SpeakerClustering.cluster(feats, maxSpeakers: 4)
    #expect(labels == [0, 1, 0, 1, 0, 1])
    let turns = SpeakerClustering.turns(segments: [(0, 1, a), (1, 2, b), (2, 3, a)])
    #expect(turns.map(\.speaker) == ["s1", "s2", "s1"])
    // One voice saying different things: a shared shape with small content noise stays one speaker.
    let base: [Float] = (0..<66).map { Float(sin(Double($0) * 0.3)) * 2 + 3 }
    var seed: UInt64 = 7
    let one: [[Float]] = (0..<8).map { _ in base.map { v in seed = seed &* 6364136223846793005 &+ 1442695040888963407; return v + Float(Int(seed >> 33) % 100) / 100 * 0.15 - 0.075 } }
    #expect(Set(SpeakerClustering.cluster(one)).count == 1)
    #expect(SpeakerClustering.cluster([a, a, a]).allSatisfy { $0 == 0 })
    // Three voices: two kinds of shape, one of them in two variants, come apart as three.
    let c: [Float] = base.map { $0 * 1.5 }, d: [Float] = base.enumerated().map { $0.offset % 2 == 0 ? $0.element * 1.5 : $0.element * 0.7 }
    let e: [Float] = base.enumerated().map { $0.offset % 3 == 0 ? $0.element * 0.4 : $0.element * 1.6 }
    let three = SpeakerClustering.cluster([c, d, e, c, d, e, c, d, e].map { v in v.map { $0 + 0.01 } })
    #expect(three == [0, 1, 2, 0, 1, 2, 0, 1, 2])
}

@Test func metaRoundTripAndWriter() throws {
    var meta = MeetingMeta(id: "2026-11-04-1103-roadmap", title: "Roadmap", startedAt: Date(timeIntervalSince1970: 1_762_225_413), app: MeetingApp(bundleID: "com.larksuite.macos.lark", name: "Lark", windowTitle: "Lark Meeting"))
    meta.speakers = [MeetingSpeaker(id: "me", name: "Me", isMe: true), MeetingSpeaker(id: "p2", name: "Person 2")]
    meta.durationS = 2158
    meta.marks = [MeetingMark(at: 120, text: "budget")]
    meta.processing.status = .ready
    let data = try MeetingMeta.encoder.encode(meta)
    #expect(try MeetingMeta.decoder.decode(MeetingMeta.self, from: data) == meta)
    let summary = MeetingSummary(title: "AWS cost review", overview: "We went over the AWS bill.", keywords: ["AWS", "cost"],
                                 decisions: [.init(text: "Shut the idle machines", context: "low use", ts: 300)],
                                 actionItems: [.init(text: "List the idle machines", owner: "Me", due: "Friday", ts: 320)],
                                 openQuestions: ["Shared memory limits?"], topics: [.init(title: "Bill", start: 0, end: 600, summary: "The total and the two accounts.")],
                                 participants: [.init(speakerID: "p2", suggestedName: "Yifei Gao", evidence: "called by name")], language: "zh-Hans")
    let md = MeetingWriter.summaryMarkdown(summary, meta: meta)
    #expect(md.hasPrefix("# AWS cost review") && md.contains("- [ ] `00:05:20` List the idle machines — **Me** (Friday)") && md.contains("### `00:00:00` Bill") && md.contains("- 00:02:00 budget"))
    let lines = [MeetingLine(speaker: "p2", start: 20.68, end: 33, text: "AWS 这块"), MeetingLine(speaker: "me", start: 33.18, end: 56, text: "其他的")]
    let page = MeetingWriter.knowledgePage(meta: meta, summary: summary, lines: lines, transcriptURL: URL(fileURLWithPath: "/tmp/m/transcript.md"), folderURL: URL(fileURLWithPath: "/tmp/m"))
    #expect(page.frontmatter.type == "meeting" && page.frontmatter.title == "AWS cost review" && page.frontmatter.tags == ["AWS", "cost"])
    #expect(page.frontmatter.resource == "file:///tmp/m/transcript.md" && page.frontmatter.sources.first?.id == "transcript")
    #expect(page.body.contains("## Decisions") && page.body.contains("**Person 2** `00:00:20`  \nAWS 这块"))
    let round = try OKFDocument.parse(page.serialize())
    #expect(round.frontmatter.title == "AWS cost review")
    #expect(MeetingWriter.slug(title: "Weekly sync: roadmap!", startedAt: meta.startedAt).hasSuffix("-weekly-sync-roadmap"))
    #expect(MeetingWriter.defaultTitle(app: MeetingApp(name: "Zoom", windowTitle: "Zoom Meeting"), startedAt: meta.startedAt).hasPrefix("Zoom "))
    #expect(MeetingWriter.defaultTitle(app: MeetingApp(name: "Chrome", windowTitle: "Weekly sync"), startedAt: meta.startedAt) == "Weekly sync")
    let summarySchema = MeetingPrompts.summarySchema
    #expect(summarySchema["properties"]["action_items"]["type"].string == "array")
}
