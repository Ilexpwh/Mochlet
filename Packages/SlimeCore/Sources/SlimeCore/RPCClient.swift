import Foundation
import Darwin

public actor RPCClient {
    public nonisolated let events: AsyncStream<JSONValue>
    private let eventSink: AsyncStream<JSONValue>.Continuation
    private var process: Process?
    private var input: FileHandle?
    private var pending:[Int:CheckedContinuation<JSONValue,Error>]=[:]
    private var nextID=1
    private var framer=JSONLineFramer()
    private var closed=false
    public init() { let pair=AsyncStream<JSONValue>.makeStream(bufferingPolicy:.bufferingNewest(2048));events=pair.stream;eventSink=pair.continuation }
    public func launch(executable: String, arguments: [String], cwd: String) throws {
        guard process == nil else { throw MochletError.message("Agent transport is already started.") }
        let p=Process();let stdin=Pipe();let stdout=Pipe();let stderr=Pipe()
        p.executableURL=URL(fileURLWithPath:executable);p.arguments=arguments;p.currentDirectoryURL=URL(fileURLWithPath:cwd)
        p.standardInput=stdin;p.standardOutput=stdout;p.standardError=stderr
        try p.run();process=p;input=stdin.fileHandleForWriting
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1)
        Task.detached { [weak self] in
            do {
                while true {
                    let bytes=stdout.fileHandleForReading.availableData
                    if bytes.isEmpty {break}
                    guard let self else {return};try await self.receive(bytes)
                }
                p.waitUntilExit()
                await self?.end(reason:"Agent connection closed (exit \(p.terminationStatus)).")
            } catch { await self?.end(reason:error.localizedDescription) }
        }
        Task.detached {
            // Drain stderr without persisting possible credentials or user content.
            while !stderr.fileHandleForReading.availableData.isEmpty {}
        }
    }
    public func call(_ method: String, params: JSONValue = .object([:]), timeout: Double = 45) async throws -> JSONValue {
        let id=nextID;nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !closed,input != nil else { continuation.resume(throwing:MochletError.message("Agent is not connected."));return }
                pending[id]=continuation
                do { try write(.object(["id":.number(Double(id)),"method":.string(method),"params":params])) }
                catch { pending.removeValue(forKey:id)?.resume(throwing:error);return }
                Task { [weak self] in try? await Task.sleep(for:.seconds(timeout));await self?.fail(id,reason:"Agent request timed out: \(method)") }
            }
        } onCancel: { Task { await self.fail(id,reason:"Request cancelled") } }
    }
    public func notify(_ method: String, params: JSONValue = .object([:])) throws { try write(.object(["method":.string(method),"params":params])) }
    public func reply(id: JSONValue, result: JSONValue) throws { try write(.object(["id":id,"result":result])) }
    public func reject(id: JSONValue, message: String) throws { try write(.object(["id":id,"error":.object(["code":.number(-32601),"message":.string(message)])])) }
    private func write(_ value: JSONValue) throws {
        guard let input,!closed else { throw MochletError.message("Agent is disconnected.") }
        var data=try JSONEncoder().encode(value);data.append(10);try input.write(contentsOf:data)
    }
    private func receive(_ data: Data) throws {
        guard !closed else{return}
        for frame in try framer.append(data) {
            if frame["method"].string == nil,let n=frame["id"].number,let c=pending.removeValue(forKey:Int(n)) {
                if frame["error"] != .null {c.resume(throwing:MochletError.message(frame["error"]["message"].string ?? "Agent request failed"))}
                else {c.resume(returning:frame["result"])}
            } else {
                if case .dropped = eventSink.yield(frame) { throw MochletError.message("Agent output exceeded the event queue. Reconnect explicitly.") }
            }
        }
    }
    private func fail(_ id:Int,reason:String) { pending.removeValue(forKey:id)?.resume(throwing:MochletError.message(reason)) }
    private func end(reason:String) {
        guard !closed else{return};closed=true
        for c in pending.values {c.resume(throwing:MochletError.message(reason))};pending.removeAll()
        eventSink.yield(.object(["method":.string("mochlet/disconnected"),"params":.object(["reason":.string(reason)])]));eventSink.finish()
        try? input?.close();input=nil
        if process?.isRunning == true { process?.terminate() }
    }
    public func stop() {end(reason:"Connection stopped")}
}
