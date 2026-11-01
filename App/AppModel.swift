import SwiftUI
import AppKit
import SlimeCore

@MainActor @Observable final class AppModel {
    let store: Store
    let folder: URL
    var projects: [Project] = []
    var tasks: [WorkTask] = []
    var selectedProjectID = ""
    var selectedTaskID: String?
    var draft = ""
    var errorMessage: String?
    var isBusy = false
    var status = "Ready when you are"
    var runtime: CodexRuntime?
    var runtimeEvents: Task<Void,Never>?
    var activeTaskID: String?
    var activeRunID: String?
    var activeThreadID: String?
    var activeTurnID: String?
    var pendingInputs: [AgentInput] = []
    var deliveringInputs: Set<String> = []
    var usage: JSONValue = .null
    var usageDate: Date?
    var activity = ""
    var items: [String:JSONValue] = [:]
    var readOnly = false
    var codexPath: String = UserDefaults.standard.string(forKey:"codexPath") ?? "/opt/homebrew/bin/codex" {
        didSet { UserDefaults.standard.set(codexPath,forKey:"codexPath") }
    }
    var queue: [(WorkTask,String,Bool)] = []
    var slimeName: String { didSet { UserDefaults.standard.set(slimeName, forKey: "slimeName") } }
    var palette: String { didSet { UserDefaults.standard.set(palette, forKey: "palette") } }
    var selectedProject: Project? { projects.first { $0.id == selectedProjectID } }
    var selectedTask: WorkTask? { tasks.first { $0.id == selectedTaskID } }
    var tint: Color {
        switch palette {
        case "Peach": Color(red: 0.97, green: 0.74, blue: 0.62)
        case "Sky": Color(red: 0.65, green: 0.80, blue: 0.96)
        case "Lilac": Color(red: 0.79, green: 0.73, blue: 0.94)
        default: Color(red: 0.64, green: 0.88, blue: 0.75)
        }
    }
    var slimeMood: SlimeMood {
        if !pendingInputs.isEmpty { return .attention }
        if isBusy { return .working }
        if errorMessage != nil { return .error }
        if selectedTask?.state == .review { return .success }
        if selectedTask?.state == .interrupted { return .disconnected }
        return .idle
    }
    var openOnHover = UserDefaults.standard.bool(forKey: "openOnHover") {
        didSet { UserDefaults.standard.set(openOnHover, forKey: "openOnHover") }
    }
    var hideWhenIdle = UserDefaults.standard.object(forKey: "hideWhenIdle") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hideWhenIdle, forKey: "hideWhenIdle") }
    }
    init(store: Store, folder: URL) {
        self.store = store; self.folder = folder
        slimeName = UserDefaults.standard.string(forKey: "slimeName") ?? "Mochlet"
        palette = UserDefaults.standard.string(forKey: "palette") ?? "Mint"
    }
    func load() async {
        do {
            try await store.recover()
            try await refresh()
            selectedProjectID = projects.first?.id ?? ""
        } catch { report(error) }
    }
    func refresh() async throws { projects = try await store.projects(); tasks = try await store.tasks() }
    func report(_ error: Error) { errorMessage = error.localizedDescription }
    func addProject() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.message = "Choose the working folder for a project."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                if let existing = projects.first(where: { $0.root == url.resolvingSymlinksInPath().path }) { selectedProjectID = existing.id; return }
                let project = Project(name: url.lastPathComponent, root: url.path)
                try await store.save(project); try await refresh(); selectedProjectID = project.id
            } catch { report(error) }
        }
    }
    func submit() {
        guard let project = selectedProject, !draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        let prompt=draft;draft=""
        let task: WorkTask
        if let existing=selectedTask,existing.projectID == project.id, existing.id != activeTaskID,
           existing.state != .queued {task=existing}
        else {task=WorkTask(projectID:project.id,title:prompt)}
        Task {
            do {
                try ProjectResolver.validateRoot(project)
                var queued=task;queued.state = .queued
                try await store.save(queued);try await refresh();selectedTaskID=queued.id
                queue.append((queued,prompt,readOnly));await runNext()
            } catch {draft=prompt;report(error)}
        }
    }
    func runNext() async {
        guard !isBusy,!queue.isEmpty else{return}
        let (queued,prompt,readOnly)=queue.removeFirst()
        guard let project=projects.first(where:{$0.id == queued.projectID}) else{return}
        isBusy=true;activeTaskID=queued.id
        var task=queued;task.state = .running
        if !task.output.isEmpty {task.output += "\n\n— Follow-up —\n\(prompt)\n\n"}
        let run=Run(taskID:task.id,prompt:prompt);activeRunID=run.id
        do {
            try await store.begin(task,run:run);try await refresh()
            if runtime == nil {
                let r=CodexRuntime();runtime=r
                runtimeEvents=Task { [weak self] in
                    for await event in r.client.events { await self?.receive(event) }
                }
                try await r.connect(executable:codexPath,cwd:project.root)
            }
            guard let runtime else{return}
            let thread=try await runtime.prepare(project:project,threadID:task.threadID,readOnly:readOnly)
            task.threadID=thread;activeThreadID=thread
            try await store.save(task);try await refresh()
            let turn = try await runtime.send(threadID:thread,text:prompt)
            guard activeRunID == run.id else { return }
            activeTurnID = turn
            status="Working in \(project.name)";activity="Codex is working"
            await refreshUsage()
        } catch { if activeRunID == run.id { report(error);await finish(.failed) } }
    }
    func refreshUsage() async {
        guard let runtime else{return}
        do {usage=try await runtime.client.call("account/rateLimits/read");usageDate=Date()}
        catch {usage = .null;usageDate=nil}
    }
    func receive(_ event:JSONValue) async {
        let method=event["method"].string ?? "";let p=event["params"]
        if method == "mochlet/disconnected" {
            runtime=nil;usageDate=nil
            if isBusy {errorMessage=p["reason"].string;await finish(.interrupted,continueQueue:false)}
            return
        }
        if method == "account/rateLimits/updated" {usage=p;usageDate=Date();return}
        guard isBusy,let taskID=activeTaskID else{return}
        if let thread=p["threadId"].string,thread != activeThreadID {return}
        if let turn=p["turnId"].string ?? p["turn"]["id"].string,let activeTurnID,turn != activeTurnID{return}
        if event["id"] != .null {
            guard let runtime else{return}
            let supported=["item/commandExecution/requestApproval","item/fileChange/requestApproval","item/tool/requestUserInput"]
            if supported.contains(method) {
                pendingInputs.append(.init(rpcID:event["id"],method:method,params:p,details:items[p["itemId"].string ?? ""] ?? .null))
                activity="Needs your input"
                do {if var task=tasks.first(where:{$0.id == taskID}) {task.state = .waiting;try await store.save(task);try await refresh()}}
                catch{report(error)}
            } else {try? await runtime.client.reject(id:event["id"],message:"This request type is not supported by Mochlet yet.")}
            return
        }
        do {
            switch method {
            case "item/agentMessage/delta":
                if let index=tasks.firstIndex(where:{$0.id == taskID}),let delta=p["delta"].string {
                    tasks[index].output += delta
                    if tasks[index].output.utf8.count > 2_000_000 {tasks[index].output=String(tasks[index].output.suffix(1_000_000));activity="Showing recent output; full session remains in Codex"}
                }
            case "item/started","item/completed":
                let item=p["item"];if let id=item["id"].string {items[id]=item}
                activity=item["type"].string ?? "Working"
                if method == "item/completed",let task=tasks.first(where:{$0.id == taskID}) {try await store.save(task)}
            case "turn/completed":
                let state=p["turn"]["status"].string
                if let error=p["turn"]["error"]["message"].string {errorMessage=error}
                await finish(state == "completed" ? .review : state == "interrupted" ? .cancelled:.failed)
            case "serverRequest/resolved": pendingInputs.removeAll {$0.rpcID == p["requestId"]}
            case "error": errorMessage=p["error"]["message"].string ?? "Codex reported an error."
            default:break
            }
        } catch {report(error)}
    }
    func finish(_ state:WorkState,continueQueue:Bool = true) async {
        guard let taskID=activeTaskID else{return}
        if var task=tasks.first(where:{$0.id == taskID}),let runID=activeRunID {
            task.state=state
            do {try await store.finish(task,runID:runID);try await refresh()} catch {report(error)}
        }
        isBusy=false;activeTaskID=nil;activeRunID=nil;activeThreadID=nil;activeTurnID=nil;pendingInputs=[];deliveringInputs=[];items=[:]
        status=state == .review ? "Work is ready to review" : state.rawValue.capitalized;activity=status
        if continueQueue {await runNext()}
    }
    func answer(_ input:AgentInput,result:JSONValue) {
        guard pendingInputs.contains(where:{$0.id == input.id}), !deliveringInputs.contains(input.id), let runtime else{return}
        deliveringInputs.insert(input.id)
        Task {
            defer { deliveringInputs.remove(input.id) }
            do {
                try await runtime.client.reply(id:input.rpcID,result:result)
                pendingInputs.removeAll {$0.id == input.id}
                if pendingInputs.isEmpty,let index=tasks.firstIndex(where:{$0.id == activeTaskID}) {tasks[index].state = .running;try await store.save(tasks[index])}
            } catch {report(error)}
        }
    }
    func cancelRun() {
        guard let runtime,let thread=activeThreadID,let turn=activeTurnID else{return}
        Task {do {try await runtime.interrupt(threadID:thread,turnID:turn)} catch {report(error)}}
    }
    func shutdown() {
        runtimeEvents?.cancel()
        if let runtime {Task {await runtime.client.stop()}}
    }

}
