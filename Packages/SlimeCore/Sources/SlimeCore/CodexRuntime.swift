import Foundation

public actor CodexRuntime {
    public nonisolated let client: RPCClient
    public init(client: RPCClient = RPCClient()) {self.client=client}
    public func connect(executable:String,cwd:String) async throws {
        try await client.launch(executable:executable,arguments:["app-server","--stdio"],cwd:cwd)
        do {
        _ = try await client.call("initialize",params:.object([
            "clientInfo":.object(["name":.string("mochlet"),"title":.string("Mochlet"),"version":.string("0.1.0")]),
            "capabilities":.object(["experimentalApi":.bool(true)])]))
        try await client.notify("initialized")
        } catch {await client.stop();throw error}
    }
    public func prepare(project:Project,threadID:String?,readOnly:Bool) async throws -> String {
        try ProjectResolver.validateRoot(project)
        var params:[String:JSONValue]=["approvalPolicy":.string("on-request"),"sandbox":.string(readOnly ? "read-only":"workspace-write"),"approvalsReviewer":.string("user")]
        let method:String
        if let threadID {method="thread/resume";params["threadId"] = .string(threadID)}
        else {method="thread/start";params["cwd"] = .string(project.root)}
        let reply=try await client.call(method,params:.object(params))
        guard let cwd=reply["thread"]["cwd"].string,let id=reply["thread"]["id"].string else {throw MochletError.message("Codex did not return a verifiable session.")}
        try ProjectResolver.verifyCWD(expected:project.root,actual:cwd)
        if let threadID,threadID != id {throw MochletError.message("Codex resumed a different session.")}
        return id
    }
    public func send(threadID:String,text:String) async throws -> String {
        let result=try await client.call("turn/start",params:.object(["threadId":.string(threadID),"input":.array([.object(["type":.string("text"),"text":.string(text)])])]))
        guard let turn=result["turn"]["id"].string else {throw MochletError.message("Codex did not return a turn identifier.")};return turn
    }
    public func interrupt(threadID:String,turnID:String) async throws { _ = try await client.call("turn/interrupt",params:.object(["threadId":.string(threadID),"turnId":.string(turnID)])) }
}

public struct AgentInput: Identifiable,Sendable,Equatable {
    public var id:String {rpcID.formatted}
    public let rpcID:JSONValue
    public let method:String
    public let params:JSONValue
    public let details:JSONValue
    public init(rpcID:JSONValue,method:String,params:JSONValue,details:JSONValue = .null) {self.rpcID=rpcID;self.method=method;self.params=params;self.details=details}
}
