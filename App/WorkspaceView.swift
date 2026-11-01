import SwiftUI
import SlimeCore

struct WorkspaceView: View {
    @Bindable var model: AppModel
    @State private var section = "Companion"
    var body: some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:18) {
                HStack { SlimeView(tint:model.tint,animated:false).frame(width:38,height:38);Text("Mochlet").font(.title3.weight(.semibold)) }.padding(.horizontal,10)
                List(selection:$section) {
                    Label("Companion",systemImage:"bubble.left.and.bubble.right").tag("Companion")
                    Label("Projects",systemImage:"folder").tag("Projects")
                    Label("Task history",systemImage:"clock").tag("History")
                    Label("Appearance",systemImage:"paintpalette").tag("Appearance")
                }.listStyle(.sidebar)
                Text("Your little companion\nfor big work.").font(.caption).foregroundStyle(.secondary).padding(18)
            }.padding(.top,16).navigationSplitViewColumnWidth(min:180,ideal:210)
        } detail: {
            Group {
                switch section {
                case "Projects": projectList
                case "History": history
                case "Appearance": appearance
                default: CompanionView(model:model)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
        .tint(model.tint.mix(with:.black,by:0.25))
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
            Section { Text("Motion follows the macOS Reduce Motion setting. Your choice of character is independent of the agent and model.").foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
}

struct CompanionView: View {
    @Bindable var model: AppModel
    var compact = false
    @FocusState private var composerFocused: Bool
    var body: some View {
        VStack(spacing:16) {
            HStack {
                if model.projects.isEmpty { Button("Add project",systemImage:"folder.badge.plus",action:model.addProject) }
                else { Picker("Project",selection:$model.selectedProjectID) { ForEach(model.projects) { Text($0.name).tag($0.id) } }.labelsHidden().frame(maxWidth:220) }
                Spacer();Label("Codex",systemImage:"terminal").font(.caption).foregroundStyle(.secondary)
            }
            if let task = model.selectedTask {
                HStack { Text(task.state.rawValue.capitalized).font(.caption.weight(.semibold));Spacer();Button("New conversation") { model.selectedTaskID=nil } }
                ScrollView { Text(task.output.isEmpty ? task.title : task.output).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled).padding(8) }.background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12))
            } else {
                Spacer(minLength:0)
                SlimeView(mood:model.isBusy ? .working:.idle,tint:model.tint).frame(width:compact ? 110:170,height:compact ? 110:170)
                Text("Hello, I’m \(model.slimeName).").font(compact ? .title3:.title).fontWeight(.semibold)
                Text(model.status).foregroundStyle(.secondary)
                Spacer(minLength:0)
            }
            VStack(spacing:10) {
                TextField("What shall we work on?",text:$model.draft,axis:.vertical).lineLimit(3...6).textFieldStyle(.plain).focused($composerFocused)
                HStack {
                    Text(model.selectedProject?.name ?? "Choose a project to begin").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(action:model.submit) { Image(systemName:"arrow.up").font(.headline).frame(width:24,height:24) }
                        .buttonStyle(.borderedProminent).tint(model.tint.mix(with:.black,by:0.25))
                        .disabled(model.selectedProject == nil || model.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.return,modifiers:.command).help("Send · Command Return").accessibilityLabel("Send task")
                }
            }.padding(14).background(.background,in:RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).stroke(.quaternary))
            if compact, let error=model.errorMessage { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
        }.padding(compact ? 18:30).frame(minWidth:compact ? 360:420)
        .onAppear { composerFocused=true }
    }
}
