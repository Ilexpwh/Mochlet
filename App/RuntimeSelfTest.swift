#if DEBUG
import Foundation
import SlimeCore

/// Runs the real MainActor orchestration against disposable process fixtures.
/// Enabled only by the development verification script; never touches real agents.
@MainActor enum RuntimeSelfTest {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw MochletError.message(message) }
    }
    static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw MochletError.message("Native runtime fixture timed out")
    }
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mochlet-runtime-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPath = UserDefaults.standard.object(forKey: "codexPath")
        defer { if let oldPath { UserDefaults.standard.set(oldPath, forKey: "codexPath") } else { UserDefaults.standard.removeObject(forKey: "codexPath") } }
        for mode in ["cancel", "disconnect"] {
            let folder = root.appendingPathComponent(mode)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fixture = folder.appendingPathComponent("agent")
            try #"""
            #!/usr/bin/python3
            import sys,json,os,time
            folder=os.path.dirname(os.path.abspath(__file__))
            mode=os.path.basename(folder)
            def emit(v):
                print(json.dumps(v),flush=True)
            for line in sys.stdin:
                value=json.loads(line); method=value.get('method','')
                with open(folder+'/requests','a') as log: log.write(method+'\n')
                if method=='initialized': continue
                result={}
                if method=='thread/start':
                    if mode=='cancel': time.sleep(3)
                    if mode=='disconnect' and not os.path.exists(folder+'/failed'):
                        open(folder+'/failed','w').close(); sys.exit(1)
                    result={'thread':{'id':'fixture-thread','cwd':os.getcwd()}}
                elif method=='turn/start': result={'turn':{'id':'fixture-turn'}}
                elif method=='account/rateLimits/read': result={'rateLimits':{}}
                emit({'id':value.get('id'),'result':result})
                if method=='turn/start':
                    emit({'method':'turn/completed','params':{'threadId':'fixture-thread','turn':{'id':'fixture-turn','status':'completed'}}})
            """#.write(to: fixture, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
            let store = try Store(path: folder.appendingPathComponent("store.sqlite").path)
            let project = Project(name: "Fixture", root: folder.path); try await store.save(project)
            let model = AppModel(store: store, folder: folder)
            model.codexPath = fixture.path
            model.projects = [project]; model.selectedProjectID = project.id
            var first = WorkTask(projectID: project.id, title: "First"); first.state = .queued
            try await store.enqueue(first, prompt: "First", readOnly: true)
            if mode == "disconnect" {
                let second = WorkTask(projectID: project.id, title: "Second")
                try await store.enqueue(second, prompt: "Second", readOnly: true)
            }
            try await model.refresh(); model.queue = try await store.queuedCommands()
            let dispatch = Task { await model.runNext() }
            let requests = folder.appendingPathComponent("requests")
            if mode == "cancel" {
                try await wait { (try? String(contentsOf: requests, encoding: .utf8).contains("thread/start")) == true }
                model.cancelRun()
                await dispatch.value
                try await wait { !model.isBusy }
                try require(model.tasks.first?.state == .cancelled, "Cancelled startup lost its cancelled state")
                try require(!(try String(contentsOf: requests, encoding: .utf8)).contains("turn/start"), "Cancelled startup dispatched a prompt")
            } else {
                await dispatch.value
                try await wait { !model.isBusy }
                try await Task.sleep(for: .milliseconds(200))
                try require(model.queue.count == 1, "Disconnection automatically resumed the queue")
                try require(!(try String(contentsOf: requests, encoding: .utf8)).contains("turn/start"), "Interrupted startup sent a prompt")
                await model.resumeQueue()
                try await wait { !model.isBusy && model.queue.isEmpty }
                try require(model.tasks.contains { $0.title == "Second" && $0.state == .review }, "Explicit Resume did not complete the queued successor")
            }
            model.shutdown()
        }
        print("Native runtime fixtures passed: cancelled startup, paused disconnect queue, explicit resume.")
    }
}
#endif
