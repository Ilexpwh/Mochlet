import Testing
import Foundation
@testable import SlimeCore

@Test func framesSurviveSplitUTF8AndRejectOverflow() throws {
    var framer=JSONLineFramer(limit:128)
    let bytes=Data("{\"text\":\"廣東話\"}\n{\"id\":2}\n".utf8)
    var frames:[JSONValue]=[]
    for b in bytes { frames += try framer.append(Data([b])) }
    #expect(frames.count == 2);#expect(frames[0]["text"].string == "廣東話")
    #expect(!framer.hasPartialFrame)
    #expect(throws:MochletError.self) { try framer.append(Data(repeating:65,count:129)) }
}
@Test func rpcCorrelatesOutOfOrderRepliesAndCloses() async throws {
    let client=RPCClient()
    let script="""
    import sys,json
    a=json.loads(sys.stdin.readline()); b=json.loads(sys.stdin.readline())
    for x in [b,a]:
        print(json.dumps({'id':x['id'],'result':{'method':x['method']}}),flush=True)
    """
    try await client.launch(executable:"/usr/bin/python3",arguments:["-u","-c",script],cwd:"/tmp")
    async let a=client.call("first")
    async let b=client.call("second")
    let (ra,rb)=try await (a,b)
    #expect(ra["method"].string == "first");#expect(rb["method"].string == "second")
    await client.stop()
}
