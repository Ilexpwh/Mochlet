import SwiftUI
import SlimeCore

struct AttentionView: View {
    var input:AgentInput
    @Bindable var model:AppModel
    @State private var answers:[String:String]=[:]
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Label("Codex needs your input",systemImage:"hand.raised").font(.headline)
            if input.method == "item/tool/requestUserInput" {
                ForEach(input.params["questions"].array,id:\.formatted) { q in
                    let id=q["id"].string ?? ""
                    Text(q["question"].string ?? "Question")
                    ForEach(q["options"].array,id:\.formatted) { option in
                        Button(option["label"].string ?? "Option") {answers[id]=option["label"].string}
                    }
                    if q["isSecret"] == .bool(true) {
                        SecureField("Your answer", text: Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 }))
                    } else {
                        TextField("Your answer", text: Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 }))
                    }
                }
                Button("Send answers") {
                    let response=Dictionary(uniqueKeysWithValues:answers.map {($0.key,JSONValue.object(["answers":.array([.string($0.value)])]))})
                    model.answer(input,result:.object(["answers":.object(response)]))
                }.disabled(input.params["questions"].array.contains{(answers[$0["id"].string ?? ""] ?? "").isEmpty})
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
            Section("Codex") {
                TextField("Executable path",text:$model.codexPath)
                Toggle("Read-only agent workspace",isOn:$model.readOnly)
                Text("New turns use on-request approvals. Changing this setting affects the next run, not active work.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Account limits") {
                Button(model.runtime == nil ? "Connect Codex and read limits" : "Refresh", action: { Task { await model.connectAndReadUsage() } }).disabled(model.connectingRuntime)
                if model.usageDate != nil { UsageCard(value: model.usage, observedAt: model.usageDate) }
                else {Text("Unavailable until a supported Codex account is connected. Missing values are not zero usage.").foregroundStyle(.secondary)}
                DisclosureGroup("Protocol details") { Text(model.usage.formatted).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
    }
}
