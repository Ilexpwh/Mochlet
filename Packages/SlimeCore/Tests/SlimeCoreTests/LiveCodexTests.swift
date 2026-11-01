import Testing
import Foundation
@testable import SlimeCore

@Test(.enabled(if:ProcessInfo.processInfo.environment["MOCHLET_LIVE_CODEX"] == "1"))
func realCodexReadOnlyRoundTrip() async throws {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("mochlet-smoke-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:folder)}
    let r=CodexRuntime()
    try await r.connect(executable:"/opt/homebrew/bin/codex",cwd:folder.path)
    let project=Project(name:"Smoke",root:folder.path)
    let thread=try await r.prepare(project:project,threadID:nil,readOnly:true)
    let events=Task { () throws -> String in
        var text=""
        for await event in r.client.events {
            if event["id"] != .null {try await r.client.reject(id:event["id"],message:"No tools authorized in this smoke test.")}
            if event["method"].string == "item/agentMessage/delta" {text += event["params"]["delta"].string ?? ""}
            if event["method"].string == "turn/completed" {break}
            if event["method"].string == "mochlet/disconnected" {throw MochletError.message("Disconnected")}
        };return text
    }
    let timer=Task {try? await Task.sleep(for:.seconds(90));await r.client.stop()}
    _ = try await r.send(threadID:thread,text:"Reply with exactly MOCHLET_OK. Do not call tools, read files, or modify anything.")
    let output=try await events.value
    #expect(output.contains("MOCHLET_OK"))
    let resumed=try await r.prepare(project:project,threadID:thread,readOnly:true)
    #expect(resumed == thread)
    timer.cancel();await r.client.stop()
}
