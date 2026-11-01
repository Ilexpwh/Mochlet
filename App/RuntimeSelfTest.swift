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
        try await connectedDraftRouting(root: root)
        try await githubQueuedRevision(root: root)
        try await queuedMemory(root: root)
        try await multipleMemorySources(root: root)
        try await taskEditDuringSubmission(root: root)
        if let executable = ProcessInfo.processInfo.environment["MOCHLET_PI_FIXTURE_PATH"] {
            try await piWorkflow(root: root.appendingPathComponent("pi"), executable: executable)
        }
        print("Native runtime fixtures passed: cancelled startup, paused disconnect queue, explicit resume.")
    }
    static func taskEditDuringSubmission(root: URL) async throws {
        let folder = root.appendingPathComponent("board-race")
        let store = try Store(path: ":memory:")
        let a = Project(name: "Original", root: root.path), b = Project(name: "Destination", root: folder.path)
        try await store.save(a); try await store.save(b)
        let original = try await store.createDraft(projectID: a.id, title: "Mint task", provider: .codex)
        var account = ConnectedAccount(provider: "google", remoteID: "fixture", label: "Fixture", scopes: [GoogleScope.drive])
        account.projectIDs = [a.id]; try await store.saveConnection(account)
        let source = ConnectedSource(accountID: account.id, service: "drive", collection: "files", remoteID: "fixture", title: "Mint", body: "Mint", url: "https://drive.google.com/", revision: "1")
        try await store.saveSources([source], account: account)
        let model = AppModel(store: store, folder: folder)
        var note = KnowledgeNote(scope: a.id, title: "Mint", body: "Mint"); try note.bind(source: source, account: account)
        try await model.knowledge.vault?.save(note)
        var edited = original; edited.projectID = b.id; edited.provider = AgentProvider.pi.rawValue; edited.title = "Saved destination"
        let changed = edited
        model.knowledge.validateConnected = { _ in
            try await Task.sleep(for: .milliseconds(10))
            try await store.editTask(expected: original, updated: changed, details: .init(taskID: original.id))
        }
        try await model.refresh(); model.selectedProjectID = a.id; model.selectedTaskID = original.id
        model.includeKnowledge = true; model.draft = "Mint"; model.submit()
        try await wait { !model.preparingSubmission }
        try require(try await store.tasks().first { $0.id == original.id } == changed, "Submission overwrote a concurrently edited task destination")
        try require(try await store.queuedCommands().isEmpty && model.runtime == nil, "Stale task preparation reached queue/runtime")
        try require(model.errorMessage?.contains("changed") == true, "Concurrent edit was not reported")
        model.shutdown()
    }
    static func multipleMemorySources(root: URL) async throws {
        let folder = root.appendingPathComponent("multiple-memory")
        let store = try Store(path: ":memory:")
        let project = Project(name: "Multiple memory", root: root.path); try await store.save(project)
        var account = ConnectedAccount(provider: "google", remoteID: "fixture", label: "Fixture", scopes: [GoogleScope.drive])
        account.projectIDs = [project.id]; try await store.saveConnection(account)
        let model = AppModel(store: store, folder: folder)
        guard let vault = model.knowledge.vault else { throw MochletError.message("Missing fixture vault") }
        var notes: [KnowledgeNote] = []
        for id in ["A", "B"] {
            let source = ConnectedSource(accountID: account.id, service: "drive", collection: "files", remoteID: id, title: id, body: "Mint", url: "https://drive.google.com/", revision: "1")
            try await store.saveSources([source], account: account)
            var note = KnowledgeNote(scope: project.id, title: id, body: "Mint"); try note.bind(source: source, account: account)
            try await vault.save(note)
            notes.append(try await vault.search(id, scope: project.id).first!)
        }
        let firstID = notes[0].id, secondID = notes[1].id
        model.knowledge.validateConnected = { note in
            if note.id == secondID {
                try await Task.sleep(for: .milliseconds(10))
                try await vault.remove(firstID)
            }
        }
        var task = WorkTask(projectID: project.id, title: "Two-source context"); task.state = .queued
        try await store.enqueue(task, prompt: "Fixture private context", readOnly: true, knowledge: notes.map(KnowledgeEvidence.init))
        model.projects = [project]; model.selectedProjectID = project.id
        model.codexPath = folder.appendingPathComponent("must-not-start").path
        try await model.refresh(); model.queue = try await store.queuedCommands()
        await model.runNext(); try await wait { !model.isBusy }
        try require(model.tasks.first?.state == .failed && model.runtime == nil, "Earlier memory invalidated during later validation reached runtime startup")
        try require(model.errorMessage?.contains("must-not-start") != true, "Two-source validation failed only at executable launch")
        model.shutdown()
    }
    static func queuedMemory(root: URL) async throws {
        for mode in ["forgotten", "disconnected", "changed-during-prepare"] {
            let folder = root.appendingPathComponent("memory-" + mode)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = try Store(path: folder.appendingPathComponent("store.sqlite").path)
            let project = Project(name: "Memory fixture", root: folder.path); try await store.save(project)
            let model = AppModel(store: store, folder: folder)
            model.projects = [project]; model.selectedProjectID = project.id
            var note = KnowledgeNote(scope: project.id, title: "Private fixture", body: "Mint")
            var account = ConnectedAccount(provider: "google", remoteID: "fixture", label: "Fixture", scopes: [GoogleScope.drive])
            account.projectIDs = [project.id]
            if mode == "disconnected" {
                try await store.saveConnection(account)
                let source = ConnectedSource(accountID: account.id, service: "drive", collection: "files", remoteID: "fixture", title: "Private fixture", body: "Mint", url: "https://drive.google.com/", revision: "1")
                try await store.saveSources([source], account: account); try note.bind(source: source, account: account)
            }
            guard let vault = model.knowledge.vault else { throw MochletError.message("Missing fixture vault") }
            try await vault.save(note)
            let saved = try await vault.search("", scope: project.id)[0]
            var task = WorkTask(projectID: project.id, title: "Memory fixture"); task.state = .queued
            try await store.enqueue(task, prompt: "Fixture context", readOnly: true, knowledge: [KnowledgeEvidence(saved)])
            if mode == "forgotten" { try await vault.remove(note.id) }
            if mode == "disconnected" { try await store.disconnect(account.id) }
            let fixture = folder.appendingPathComponent("agent")
            try #"""
            #!/usr/bin/python3
            import json,sys,os,glob
            folder=os.path.dirname(os.path.abspath(__file__))
            for line in sys.stdin:
                value=json.loads(line); method=value.get('method','')
                with open(folder+'/requests','a') as log: log.write(method+'\n')
                if method=='initialized': continue
                result={}
                if method=='thread/start':
                    for f in glob.glob(folder+'/Knowledge/*.md'): os.remove(f)
                    result={'thread':{'id':'fixture-thread','cwd':os.getcwd()}}
                print(json.dumps({'id':value.get('id'),'result':result}),flush=True)
            """#.write(to: fixture, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
            model.codexPath = fixture.path; try await model.refresh(); model.queue = try await store.queuedCommands()
            await model.runNext(); try await wait { !model.isBusy }
            try require(model.tasks.first?.state == .failed, "Unavailable queued memory did not fail: " + mode)
            let requests = (try? String(contentsOf: folder.appendingPathComponent("requests"), encoding: .utf8)) ?? ""
            try require(!requests.contains("turn/start"), "Invalid memory reached agent inference: " + mode)
            if mode == "changed-during-prepare" { try require(requests.contains("thread/start"), "Final evidence recheck fixture did not reach prepare") }
            else { try require(requests.isEmpty, "Invalid memory started a runtime: " + mode) }
            model.shutdown()
        }
    }
    static func githubQueuedRevision(root: URL) async throws {
        let folder = root.appendingPathComponent("github-revision")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for args in [["init", folder.path], ["-C", folder.path, "remote", "add", "origin", "https://github.com/owner/repo.git"]] {
            let result = try await CommandProcess().run(executable: "/usr/bin/git", arguments: args)
            try require(result.status == 0, "Could not prepare local GitHub routing fixture")
        }
        let fixture = folder.appendingPathComponent("gh-fixture")
        try #"""
        #!/usr/bin/python3
        import sys,json
        path=sys.argv[-1]
        if path=='user': value={'id':1,'login':'owner'}
        elif path=='repos/owner/repo': value={'id':2,'full_name':'owner/repo','html_url':'https://github.com/owner/repo'}
        else: value={'id':1,'number':1,'title':'Issue','body':'Changed source','state':'open','html_url':'https://github.com/owner/repo/issues/1','updated_at':'2'}
        print(json.dumps(value))
        """#.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let oldPath = UserDefaults.standard.object(forKey: "ghPath")
        defer { if let oldPath { UserDefaults.standard.set(oldPath, forKey: "ghPath") } else { UserDefaults.standard.removeObject(forKey: "ghPath") } }
        let store = try Store(path: ":memory:")
        let project = Project(name: "Fixture", root: folder.path); try await store.save(project)
        let account = try JSONDecoder().decode(GitHubAccount.self, from: Data(#"{"id":1,"login":"owner"}"#.utf8))
        let repo = try JSONDecoder().decode(GitHubRepository.self, from: Data(#"{"id":2,"full_name":"owner/repo","html_url":"https://github.com/owner/repo"}"#.utf8))
        let issue = try JSONDecoder().decode(GitHubIssue.self, from: Data(#"{"id":1,"number":1,"title":"Issue","body":"Original source","state":"open","html_url":"https://github.com/owner/repo/issues/1","updated_at":"1"}"#.utf8))
        let binding = GitHubBinding(projectID: project.id, account: account, repository: repo)
        try await store.bindGitHub(binding)
        var task = try await store.prepareGitHubTask(issue, binding: binding); task.state = .queued
        try await store.enqueue(task, prompt: "Original source", readOnly: true)
        let model = AppModel(store: store, folder: folder); model.github.ghPath = fixture.path
        try await model.refresh(); model.queue = try await store.queuedCommands()
        await model.runNext()
        try require(model.runtime == nil && model.tasks.first?.state == .failed, "Changed GitHub source reached an agent")
        try require(model.errorMessage?.contains("GitHub issue changed") == true, "Unexpected source validation failure")
        model.shutdown()
    }
    static func connectedDraftRouting(root: URL) async throws {
        let store = try Store(path: ":memory:")
        let a = Project(name: "A", root: root.path), b = Project(name: "B", root: root.appendingPathComponent("other").path)
        try await store.save(a); try await store.save(b)
        var account = ConnectedAccount(provider: "google", remoteID: "fixture", label: "fixture", scopes: [GoogleScope.mail]); account.projectIDs = [a.id]
        try await store.saveConnection(account)
        let source = ConnectedSource(accountID: account.id, service: "gmail", collection: "threads", remoteID: "fixture", title: "Context", body: "Untrusted reference", url: "https://mail.google.com", revision: "1")
        try await store.saveSources([source], account: account)
        let task = try await store.captureSource(source, account: account, projectID: a.id, provider: .codex)
        let model = AppModel(store: store, folder: root); try await model.refresh()
        model.selectedProjectID = b.id; model.selectedTaskID = task.id; model.draft = "Use source"
        model.connectedDraft = .init(taskID: task.id, projectID: a.id, source: source, account: account)
        model.submit()
        try require(model.errorMessage != nil && !model.preparingSubmission && model.draft == "Use source", "Source draft escaped into a different project")
        model.errorMessage = nil; model.selectedProjectID = a.id; model.selectedTaskID = nil; model.submit()
        try require(model.errorMessage != nil && !model.preparingSubmission, "New conversation discarded source provenance")
        model.errorMessage = nil; model.selectedTaskID = task.id; model.activeTaskID = task.id; model.submit()
        try require(model.errorMessage != nil && !model.preparingSubmission, "Active task fork discarded source provenance")
        let queued = try await store.queuedCommands()
        try require(queued.isEmpty, "Invalid source draft reached the queue")
        model.activeTaskID = nil; model.connectedDraft = nil; model.draft = ""
        let revision = model.composerRevision
        model.draft = "New user draft during retrieval"
        do {
            try model.installConnectedDraft(.init(taskID: task.id, projectID: a.id, source: source, account: account), instruction: "Prepared instruction", expectedRevision: revision, expectedTaskID: task.id)
            throw MochletError.message("Source retrieval overwrote a concurrent draft")
        } catch {
            try require(model.draft == "New user draft during retrieval" && model.connectedDraft == nil, "Concurrent composer edits were lost")
        }
        model.draft = ""
        let currentRevision = model.composerRevision
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try model.installConnectedDraft(.init(taskID: task.id, projectID: a.id, source: source, account: account), instruction: "Cancelled source", expectedRevision: currentRevision, expectedTaskID: task.id)
                throw MochletError.message("Cancelled source preparation installed a draft")
            } catch is CancellationError { }
        }
        try await cancelled.value
        try require(model.draft.isEmpty && model.connectedDraft == nil, "Cancellation changed the composer")
        let issue = try JSONDecoder().decode(GitHubIssue.self, from: Data(#"{"id":1,"number":1,"title":"Issue","body":"Reference","state":"open","html_url":"https://github.com/owner/repo/issues/1","updated_at":"1"}"#.utf8))
        let githubAccount = try JSONDecoder().decode(GitHubAccount.self, from: Data(#"{"id":1,"login":"owner"}"#.utf8))
        let repository = try JSONDecoder().decode(GitHubRepository.self, from: Data(#"{"id":2,"full_name":"owner/repo","html_url":"https://github.com/owner/repo"}"#.utf8))
        let binding = GitHubBinding(projectID: a.id, account: githubAccount, repository: repository)
        model.connectedDraft = .init(taskID: task.id, projectID: a.id, issue: issue, binding: binding)
        model.draft = "Fix this issue"; model.selectedProjectID = b.id; model.selectedTaskID = task.id; model.errorMessage = nil
        model.submit()
        try require(model.errorMessage != nil && !model.preparingSubmission, "GitHub draft escaped into another project")
        model.selectedProjectID = a.id; model.selectedTaskID = nil; model.errorMessage = nil; model.submit()
        try require(model.errorMessage != nil && !model.preparingSubmission, "GitHub draft lost its task binding")
        model.selectedTaskID = task.id; model.activeTaskID = task.id; model.errorMessage = nil; model.submit()
        try require(model.errorMessage != nil && !model.preparingSubmission, "GitHub draft forked active work")
        let githubQueued = try await store.queuedCommands()
        try require(githubQueued.isEmpty, "GitHub routing rejection still queued work")
        print("Native source routing fixtures passed: Google and GitHub changed project, new conversation, active-task fork.")
    }
    static func piWorkflow(root: URL, executable: String) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldPath = UserDefaults.standard.object(forKey: "piPath")
        defer { if let oldPath { UserDefaults.standard.set(oldPath, forKey: "piPath") } else { UserDefaults.standard.removeObject(forKey: "piPath") } }
        let store = try Store(path: root.appendingPathComponent("store.sqlite").path)
        let project = Project(name: "Pi fixture", root: root.path); try await store.save(project)
        let model = AppModel(store: store, folder: root); model.piPath = executable
        defer { model.shutdown() }
        model.projects = [project]; model.selectedProjectID = project.id
        var task = WorkTask(projectID: project.id, title: "Pi native fixture"); task.provider = "pi"
        var session: String?
        for turn in 0..<2 {
            task.state = .queued
            try await store.enqueue(task, prompt: "Native fixture", readOnly: false)
            try await model.refresh(); model.queue = try await store.queuedCommands()
            await model.runNext()
            try await wait { model.pendingInputs.first?.method == "item/commandExecution/requestApproval" }
            model.answer(model.pendingInputs[0], result: .object(["decision": .string("decline")]))
            try await wait { model.pendingInputs.first?.method == "item/tool/requestUserInput" }
            model.answer(model.pendingInputs[0], result: .object(["answers": .object(["choice": .object(["answers": .array([.string("Mochlet")])])])]))
            try await wait { !model.isBusy }
            task = model.tasks.first!
            try require(task.state == .review && task.sessionConfirmed, "Pi native task did not finish with a confirmed session")
            try require(task.output.components(separatedBy: "PI_FIXTURE_OK").count == turn + 2, "Pi snapshots duplicated or erased a turn")
            try require(!task.output.contains("provisional"), "Pi final output did not replace provisional text")
            if let session { try require(task.threadID == session, "Pi native follow-up changed session") }
            session = task.threadID
            try require(model.providerUsageProvider == .pi && model.usageDate == nil, "Pi usage was confused with Codex account allowance")
        }
        print("Native Pi fixtures passed: decline, question, exact resume, output replacement, provider usage.")
    }

}
#endif
