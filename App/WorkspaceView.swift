import SwiftUI
import SlimeCore

struct WorkspaceView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var section = "Companion"
    var body: some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:18) {
                HStack { SlimeView(tint:model.tint,animated:false).frame(width:38,height:38);Text("Mochlet").font(.title3.weight(.semibold)) }.padding(.horizontal,10)
                List(selection:$section) {
                    Label("Companion",systemImage:"bubble.left.and.bubble.right").tag("Companion")
                    Label("Projects",systemImage:"folder").tag("Projects")
                    Label("Task history",systemImage:"clock").tag("History")
                    Label("Meetings",systemImage:"waveform").tag("Meetings")
                    Label("Files",systemImage:"tray.and.arrow.down").tag("Files")
                    Label("Connections",systemImage:"link").tag("Connections")
                    Label("Google",systemImage:"person.crop.circle.badge.checkmark").tag("Google")
                    Label("GitHub",systemImage:"point.3.connected.trianglepath.dotted").tag("GitHub")
                    Label("Knowledge & Memory",systemImage:"books.vertical").tag("Knowledge")
                    Label("Appearance",systemImage:"paintpalette").tag("Appearance")
                    Label("Speech & Models",systemImage:"waveform").tag("Speech")
                    Label("Agent settings",systemImage:"slider.horizontal.3").tag("Agent")
                }.listStyle(.sidebar)
                Text("Your little companion\nfor big work.").font(.caption).foregroundStyle(.secondary).padding(18)
            }.padding(.top,16).navigationSplitViewColumnWidth(min:180,ideal:210)
        } detail: {
            Group {
                switch section {
                case "Projects": projectList
                case "History": history
                case "Meetings": MeetingsView(model: model)
                case "Files": FilesView(model: model)
                case "Connections": ConnectionsView(model: model) { section = "Companion" }
                case "Google": GoogleView(model: model) { section = "Companion" }
                case "GitHub": GitHubView(model: model)
                case "Knowledge": KnowledgeView(model: model)
                case "Appearance": appearance
                case "Speech": SpeechSettingsView(speech: model.speech)
                case "Agent": RuntimeSettings(model:model)
                default: CompanionView(model:model)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
        .tint(colorScheme == .dark ? model.tint : model.tint.mix(with:.black,by:0.35))
        .alert("Mochlet needs your attention",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0 {model.errorMessage=nil}})) { Button("OK") { model.errorMessage=nil } } message: { Text(model.errorMessage ?? "") }
    }
    private var projectList: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack { Text("Projects").font(.largeTitle.bold());Spacer();Button("Add folder",systemImage:"plus",action:model.addProject) }
            Text("Each task stays attached to its working folder and exact agent session.").foregroundStyle(.secondary)
            if model.projects.isEmpty { ContentUnavailableView("Bring your first project",systemImage:"folder.badge.plus",description:Text("Choose a local folder to give Mochlet a place to work.")) }
            List(model.projects) { p in
                VStack(alignment:.leading,spacing:5) { Text(p.name).font(.headline); Text(p.root).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    .padding(.vertical,6)
                    .contextMenu { Button("Use this project") { model.selectedProjectID=p.id;section="Companion" } }
            }
        }.padding(28)
    }
    private var history: some View {
        VStack(alignment:.leading) {
            Text("Task history").font(.largeTitle.bold()).padding()
            List(model.tasks) { t in Button { model.selectedTaskID=t.id;model.selectedProjectID=t.projectID;section="Companion" } label: {
                VStack(alignment:.leading,spacing:5) { Text(t.title).lineLimit(2);Text(t.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary) }.padding(.vertical,6)
            }.buttonStyle(.plain) }
        }.padding(12)
    }
    private var appearance: some View {
        Form {
            Section("Your companion") {
                SlimeView(tint:model.tint).frame(width:160,height:160).frame(maxWidth:.infinity)
                TextField("Name",text:$model.slimeName)
                Picker("Palette",selection:$model.palette) { ForEach(["Mint","Peach","Sky","Lilac"],id:\.self) { Text($0) } }
            }
            Section("Notch behavior") {
                Picker("Screen edge", selection: $model.dockEdge) {
                    ForEach(DockEdge.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Button("Center on selected edge") { model.dockFraction = 0.5 }
                Text("Drag the compact slime or the expanded header to the top, left or right edge. Position is remembered.").font(.caption).foregroundStyle(.secondary)
                Toggle("Open on hover", isOn: $model.openOnHover)
                Toggle("Hide when idle", isOn: $model.hideWhenIdle)
                Text("Hover to peek. Click to open. Escape to fold. Drafts, pending requests and pinned panels stay open.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Keyboard") { ShortcutSettings(shortcuts: model.shortcuts) }
            Section { Text("Motion follows the macOS Reduce Motion setting. Your choice of character is independent of the agent and model.").foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
}

private struct ShortcutSettings: View {
    @Bindable var shortcuts: HotKeyCenter
    var body: some View {
        Toggle("Enable global shortcuts", isOn: $shortcuts.enabled)
        Text("⌃⌥Space opens or folds Mochlet. Hold ⌃⌥V to record a command; release to transcribe, then review and Send. Release before recording starts cancels the request. Recording is capped at two minutes.").font(.caption).foregroundStyle(.secondary)
        ForEach(shortcuts.conflicts, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
    }
}

struct CompanionView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    var compact = false
    @FocusState private var composerFocused: Bool
    private func submit() {
        // Command-Return keeps the AppKit field editor active. End that edit
        // before clearing the binding, as a mouse click on Send already does.
        NSApp.keyWindow?.makeFirstResponder(nil)
        composerFocused = false
        model.submit()
        DispatchQueue.main.async { composerFocused = true }
    }
    var body: some View {
        VStack(spacing: compact ? 8 : 16) {
            HStack {
                if model.projects.isEmpty { Button("Add project",systemImage:"folder.badge.plus",action:model.addProject) }
                else { Picker("Project",selection:$model.selectedProjectID) { ForEach(model.projects) { Text($0.name).tag($0.id) } }.labelsHidden().frame(maxWidth:220) }
                if compact {
                    Menu(model.includeKnowledge ? "Memory on" : "Memory") {
                        Toggle("Use project memory", isOn: $model.includeKnowledge)
                        Toggle("Include personal memory", isOn: $model.includePersonalKnowledge).disabled(!model.includeKnowledge)
                    }.font(.caption).fixedSize()
                }
                Spacer()
                if let task = model.selectedTask, task.projectID == model.selectedProjectID {
                    Label(model.destinationProvider.title, systemImage: "terminal").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Agent", selection: $model.defaultProvider) { ForEach(AgentProvider.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(maxWidth: 140)
                }
            }
            if !compact, model.meetings.active { MeetingStatusView(meetings: model.meetings) }
            if !compact {
                HStack {
                    Toggle("Use project memory", isOn: $model.includeKnowledge)
                    if model.includeKnowledge { Toggle("Include personal memory", isOn: $model.includePersonalKnowledge) }
                    Spacer()
                }.font(.caption)
            }
            if !compact, let pending=model.pendingInputs.first { AttentionView(input:pending,model:model).id(pending.id) }
            if model.isBusy { HStack {ProgressView().controlSize(.small);Text(model.activity).font(.caption);Spacer();Button("Stop",action:model.cancelRun)} }
            if !model.queue.isEmpty {
                HStack {
                    Text("\(model.queue.count) queued").font(.caption)
                    Spacer()
                    if !model.isBusy { Button("Resume queue") { Task { await model.resumeQueue() } } }
                    Button("Cancel queued", action: model.cancelQueue)
                }
            }
            if let task = model.selectedTask {
              HStack { Text(task.state.rawValue.capitalized).font(.caption.weight(.semibold));Spacer();Button("New conversation") { model.selectedTaskID=nil } }
              if let workspace = model.taskWorkspaces[task.id] {
                  HStack {
                      Label("Isolated task workspace", systemImage: "arrow.triangle.branch").font(.caption).help(workspace.root)
                      Spacer(); Button("Review changes") { model.reviewWorkspace(task) }.disabled(model.isBusy)
                      Button("Show folder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.root) }
                  }.font(.caption)
              }
                ScrollView { Text(task.output.isEmpty ? task.title : task.output).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled).padding(8) }.background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12))
            } else {
                Spacer(minLength:0)
                SlimeView(mood:model.slimeMood,tint:model.tint).frame(width:compact ? (model.meetings.active || model.speech.active ? 36 : 72):170,height:compact ? (model.meetings.active || model.speech.active ? 36 : 72):170)
                Text("Hello, I’m \(model.slimeName).").font(compact ? .title3:.title).fontWeight(.semibold)
                Text(model.status).foregroundStyle(.secondary)
                Spacer(minLength:0)
            }
            VStack(spacing:10) {
                if let source = model.connectedDraft {
                    HStack {
                        Label(source.title, systemImage: "link").font(.caption).lineLimit(1)
                        Button("Discard source draft") { model.draft = ""; model.connectedDraft = nil }.disabled(model.preparingSubmission)
                    }
                }
                if !model.files.selected.isEmpty { AttachmentChips(files: model.files, tint: model.tint) }
                TextField("What shall we work on?",text:$model.draft,axis:.vertical).lineLimit(compact ? 1...3 : 3...6).textFieldStyle(.plain).focused($composerFocused)
                HStack {
                    Text(model.selectedProject?.name ?? "Choose a project to begin").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.files.choose() } label: { Image(systemName: "paperclip") }.accessibilityLabel("Attach files").disabled(model.files.busy)
                    VoiceControls(speech: model.speech)
                    Button(action:submit) { Image(systemName:"arrow.up").font(.headline).frame(width:24,height:24) }
                        .buttonStyle(.borderedProminent).tint(colorScheme == .dark ? model.tint : model.tint.mix(with:.black,by:0.35))
                        .disabled(model.files.busy || model.speech.active || model.selectedProject == nil || model.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.return,modifiers:.command).help("Send · Command Return").accessibilityLabel("Send task")
                }
            }.padding(14).background(.background,in:RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).stroke(.quaternary))
            if model.files.busy { HStack { ProgressView().controlSize(.small); Text("Reading files…").font(.caption); Button("Cancel") { model.files.cancel() } } }
            if let message = model.speech.message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if compact, let error=model.errorMessage { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
        }.padding(compact ? 16:30).frame(minWidth:compact ? 360:420)
          .onAppear { composerFocused = !compact }
          .sheet(isPresented: Binding(get: { model.reviewText != nil }, set: { if !$0 { model.reviewText = nil } })) {
              VStack(alignment: .leading) {
                  HStack { Text("Task changes").font(.title2.bold()); Spacer(); Button("Done") { model.reviewText = nil } }
                  ScrollView([.horizontal, .vertical]) { Text(model.reviewText ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
              }.padding(24).frame(minWidth: 700, minHeight: 480)
          }
    }
}
