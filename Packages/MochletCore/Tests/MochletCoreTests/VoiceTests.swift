import Foundation
import Testing
@testable import MochletCore

private let projects = [
    Project(slug: "mochlet", name: "Mochlet", aliases: ["slime"], description: "notch slime", paths: ["/tmp/mochlet"]),
    Project(slug: "lantern", name: "Lantern", aliases: ["lamp"], description: "", paths: ["/tmp/lantern"]),
]
private let ctx = IntentRouter.Context(clipboardURL: URL(string: "https://example.com/clip"), chatFocused: false, projects: projects)

@Test func prepassRoutesLinksNotesAndCommands() {
    #expect(IntentRouter.prepass("", context: ctx)?.intent == .cancel)
    #expect(IntentRouter.prepass("never mind", context: ctx)?.intent == .cancel)
    #expect(IntentRouter.prepass("Cancel.", context: ctx)?.intent == .cancel)
    let link = IntentRouter.prepass("read https://arxiv.org/abs/2404.16130 for me", context: ctx)
    #expect(link?.intent == .ingestURL && link?.url?.host == "arxiv.org")
    let clip = IntentRouter.prepass("save this link", context: ctx)
    #expect(clip?.intent == .ingestURL && clip?.url?.absoluteString == "https://example.com/clip")
    #expect(IntentRouter.prepass("save this link", context: IntentRouter.Context(projects: projects)) == nil)
    let note = IntentRouter.prepass("remember that, call the dentist tomorrow", context: ctx)
    #expect(note?.intent == .note && note?.task == "call the dentist tomorrow")
    let note2 = IntentRouter.prepass("Note to self: buy oat milk.", context: ctx)
    #expect(note2?.intent == .note && note2?.task == "buy oat milk")
    #expect(IntentRouter.prepass("open settings", context: ctx)?.intent == .settingsOpen)
    #expect(IntentRouter.prepass("stop recording", context: ctx)?.intent == .meetingStop)
    #expect(IntentRouter.prepass("start taking meeting notes", context: ctx)?.intent == .meetingStart)
    #expect(IntentRouter.prepass("what's hot in AI today?", context: ctx)?.intent == .signalsShow)
    let kb = IntentRouter.prepass("what did I save about Vision Pro", context: ctx)
    #expect(kb?.intent == .kbQuery)
    #expect(IntentRouter.prepass("kb: headset", context: ctx)?.text == "headset")
    #expect(IntentRouter.prepass("hello there", context: ctx) == nil)
    #expect(IntentRouter.prepass("hello there", context: IntentRouter.Context(chatFocused: true, projects: projects))?.intent == .dictate)
}

@Test func prepassProjectCommands() {
    let en = IntentRouter.prepass("work on mochlet: fix the build", context: ctx)
    #expect(en?.intent == .projectStart && en?.project?.slug == "mochlet" && en?.task == "fix the build")
    let alias = IntentRouter.prepass("work on lamp: add a login page", context: ctx)
    #expect(alias?.intent == .projectStart && alias?.project?.slug == "lantern" && alias?.task == "add a login page")
    let unknown = IntentRouter.prepass("let's eat at home", context: ctx)
    #expect(unknown == nil)
    let resume = IntentRouter.prepass("resume mochlet", context: ctx)
    #expect(resume?.intent == .projectStart && resume?.task == "")
}

@Test func decisionRequestAndFill() async throws {
    let req = IntentRouter.request("can you summarise what the agent is doing", context: ctx)
    #expect(req.options.count == VoiceIntent.allCases.count)
    #expect(req.options.contains { $0.id == "kb_query" } && req.tag == "intent")
    let engine = FixtureDecisionEngine(byTag: ["intent": "project_start"])
    let a = try await engine.decide(req)
    let filled = IntentRouter.fill(a, text: "let mochlet add tests for the router", context: ctx)
    #expect(filled.intent == .projectStart && filled.project?.slug == "mochlet")
    #expect(filled.task == "add tests for the router")
    let missing = IntentRouter.fill(.projectStart, text: "start working on the parser", context: ctx)
    #expect(missing.missingProject)
    let noFixture = FixtureDecisionEngine()
    await #expect(throws: DecisionError.self) { try await noFixture.decide(req) }
}

@Test func jevRequestAndResponse() throws {
    let req = DecisionRequest(state: "s", instructions: "pick", options: [DecisionOption(id: "a", description: "A"), DecisionOption(id: "b", description: "B")], tag: "t")
    let body = JevAPI.body(req)
    let v = JSONValue.parse(String(decoding: body, as: UTF8.self))!
    #expect(v["model"].string == "jev-latest" && v["questions"]["q"]["type"].string == "choice" && v["questions"]["q"]["criteria"]["b"].string == "B")
    let resp = #"{"answers":{"q":{"choice":"b","probabilities":{"a":0.2,"b":0.8},"confidence":0.8}}}"#
    let a = try JevAPI.parse(Data(resp.utf8), options: req.options)
    #expect(a.choice == "b" && a.confidence == 0.8 && a.backend == "jev")
    #expect(throws: DecisionError.self) { try JevAPI.parse(Data(#"{"error":{"message":"bad key"}}"#.utf8), options: req.options) }
}

@Test func noteWriterAppendsUnderTheMinute() throws {
    var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 6; c.hour = 9; c.minute = 5
    let cal = Calendar(identifier: .gregorian)
    let date = cal.date(from: c)!
    #expect(NoteWriter.path(for: date, calendar: cal) == "notes/2026/11/06.md")
    let first = NoteWriter.append("Call the dentist", to: nil, at: date, calendar: cal)
    #expect(first.frontmatter.type == "note" && first.frontmatter.title == "Notes 2026-11-06")
    #expect(first.body.contains("## 09:05\n\nCall the dentist"))
    let again = NoteWriter.append("Buy stamps", to: first, at: date, calendar: cal)
    #expect(again.body.components(separatedBy: "## 09:05").count == 2)
    #expect(again.body.contains("Call the dentist\n\nBuy stamps"))
    let later = NoteWriter.append("Lunch", to: again, at: date.addingTimeInterval(600), calendar: cal)
    #expect(later.body.contains("## 09:15\n\nLunch"))
    let round = try OKFDocument.parse(later.serialize())
    #expect(round.frontmatter.title == "Notes 2026-11-06" && round.body.contains("## 09:15"))
}
