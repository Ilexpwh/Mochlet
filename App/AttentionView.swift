import SwiftUI
import SlimeCore

struct AttentionView: View {
    var input:AgentInput
    @Bindable var model:AppModel
    @State private var answers:[String:[String]]=[:]
    @State private var custom:[String:String]=[:]
    private func values(_ id: String) -> [String] { if let text = custom[id], !text.isEmpty { return [text] }; return answers[id] ?? [] }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Label("\(model.runtimeProvider?.title ?? "Agent") needs your input",systemImage:"hand.raised").font(.headline)
            if input.method == "item/tool/requestUserInput" {
                ForEach(input.params["questions"].array,id:\.formatted) { q in
                    let id=q["id"].string ?? ""
                    Text(q["question"].string ?? "Question")
                    ForEach(q["options"].array,id:\.formatted) { option in
                        let label = option["label"].string ?? "Option"
                        Button((answers[id]?.contains(label) == true ? "✓ " : "") + label) {
                            custom[id] = ""
                            if q["multiSelect"] == .bool(true) {
                                if answers[id]?.contains(label) == true { answers[id]?.removeAll { $0 == label } }
                                else { answers[id, default: []].append(label) }
                            } else { answers[id] = [label] }
                        }
                    }
                    if q["isSecret"] == .bool(true) {
                        SecureField("Your answer", text: Binding(get: { custom[id] ?? "" }, set: { custom[id] = $0 }))
                    } else {
                        TextField("Your answer", text: Binding(get: { custom[id] ?? "" }, set: { custom[id] = $0 }))
                    }
                }
                Button("Send answers") {
                    let response=Dictionary(uniqueKeysWithValues:input.params["questions"].array.map { q in let id=q["id"].string ?? ""; return (id,JSONValue.object(["answers":.array(values(id).map(JSONValue.string))])) })
                    model.answer(input,result:.object(["answers":.object(response)]))
                }.disabled(input.params["questions"].array.contains{values($0["id"].string ?? "").isEmpty})
            } else {
                Text(input.params["reason"].string ?? "Review this action before continuing.")
                ScrollView {Text(input.params["command"].string ?? input.details.formatted).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.frame(maxHeight:160)
                HStack {
                    Button("Decline") {model.answer(input,result:.object(["decision":.string("decline")]))}
                    Button("Approve once") {model.answer(input,result:.object(["decision":.string("accept")]))}.buttonStyle(.borderedProminent)
                }
            }
        }.disabled(model.deliveringInputs.contains(input.id))
            .overlay(alignment: .topTrailing) { if model.deliveringInputs.contains(input.id) { ProgressView().controlSize(.small).padding(8) } }
            .padding(14).background(.orange.opacity(0.09),in:RoundedRectangle(cornerRadius:12))
    }
}

struct RuntimeSettings: View {
    @Bindable var model:AppModel
    var body:some View {
        Form {
            Section("Coding agents") {
                Picker("New conversation agent", selection: $model.defaultProvider) { ForEach(AgentProvider.allCases, id: \.self) { Text($0.title).tag($0) } }
                Text("Existing tasks keep their original agent and exact session. Start a new conversation to change providers.").font(.caption).foregroundStyle(.secondary)
                Toggle("Read-only agent tools",isOn:$model.readOnly)
            }
            Section("Codex") {
                TextField("Executable path",text:$model.codexPath)
                Text("New turns use on-request approvals. Changing this setting affects the next run, not active work.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code · experimental") {
                TextField("Claude executable", text: $model.claudePath)
                Text("Requires CLI 2.1.296 with its own authentication. Local CLI permission rules apply. Read-only offers Read, Glob, Grep and questions; writable runs also offer Edit, Write and Bash. Background tools and MCP are disabled in this adapter.").font(.caption).foregroundStyle(.secondary)
                if model.providerUsage != .null {
                    Text("Last Claude turn · reported API usage (not subscription allowance)").font(.caption)
                    Text(model.providerUsage.formatted).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            Section("Codex account limits") {
                Button(model.runtime == nil ? "Connect Codex and read limits" : "Refresh", action: { Task { await model.connectAndReadUsage() } }).disabled(model.connectingRuntime || (model.isBusy && model.runtimeProvider != .codex))
                if model.usageDate != nil { UsageCard(value: model.usage, observedAt: model.usageDate) }
                else {Text("Unavailable until a supported Codex account is connected. Missing values are not zero usage.").foregroundStyle(.secondary)}
                DisclosureGroup("Protocol details") { Text(model.usage.formatted).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
    }
}
