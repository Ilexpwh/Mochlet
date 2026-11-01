import SwiftUI
import SlimeCore

extension ConnectionsController {
    func allowReplies(_ enabled: Bool) {
        guard var account else { return }
        let capability = account.provider + ".reply.write"
        if enabled { account.scopes.insert(capability) } else { account.scopes.remove(capability) }
        account.generation = UUID().uuidString; replyPreview = nil
        run { try await self.store.saveConnection(account) }
    }
    func prepareReply(projectID: String) {
        guard let account, let source else { return }; let body = replyBody
        replyPreview = nil
        run {
            let delivery = TeamDelivery(account: account, reader: try await self.tokens.reader(account))
            let draft = try await delivery.prepare(projectID: projectID, source: source, body: body)
            try Task.checkCancellation(); try await self.store.prepareDelivery(draft)
            self.replyPreview = draft
        }
    }
    func sendReply(_ draft: DeliveryDraft) {
        guard let account else { return }; replyPreview = nil
        run {
            try await TeamDelivery(account: account, reader: self.tokens.reader(account)).execute(draft, store: self.store)
            self.replyBody = ""; self.message = "Reply delivered. Refresh the source to see the new conversation."
        }
    }
    func reconcileReply(_ record: DeliveryRecord) {
        guard let account else { return }
        run {
            try await TeamDelivery(account: account, reader: self.tokens.reader(account)).reconcile(record, store: self.store)
            self.message = "Matching remote delivery confirmed. Nothing was resent."
        }
    }
}

struct TeamReplyView: View {
    @Bindable var model: AppModel
    var body: some View {
        @Bindable var controller = model.connections
        if let account = controller.account, account.scopes.contains(account.provider + ".reply.write") {
            DisclosureGroup("Reply to this source") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Write a reply", text: $controller.replyBody, axis: .vertical).lineLimit(3...10)
                        .onChange(of: controller.replyBody) { controller.replyPreview = nil }
                    Text("Slack and Lark replies include a visible delivery reference. Linear comments use an internal delivery ID. Review the exact text and destination before sending.").font(.caption).foregroundStyle(.secondary)
                    Button("Preview reply") { controller.prepareReply(projectID: model.selectedProjectID) }
                        .disabled(controller.replyBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !account.projectIDs.contains(model.selectedProjectID))
                    if let draft = controller.replyPreview, draft.projectID == model.selectedProjectID {
                        Text(draft.preview).textSelection(.enabled).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        HStack {
                            Button("Send this reply") { controller.sendReply(draft) }.buttonStyle(.borderedProminent)
                            Button("Discard preview") { controller.replyPreview = nil }
                        }
                    }
                }.padding(.top, 8)
            }
        }
    }
}
struct TeamDeliveryHistory: View {
    @Bindable var controller: ConnectionsController
    var body: some View {
        if !controller.deliveries.isEmpty {
            DisclosureGroup("Reply delivery history") {
                ForEach(controller.deliveries) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.draft.kind.title + " • " + record.state.capitalized).font(.headline)
                        Text(record.draft.collection + " / " + record.draft.remoteID).font(.caption).textSelection(.enabled)
                        DisclosureGroup("Reviewed message") { Text(record.draft.preview).textSelection(.enabled) }
                        if record.state == "uncertain" {
                            Button("Check remote result — do not resend") { controller.reconcileReply(record) }.disabled(controller.busy)
                        }
                    }.padding(.vertical, 8)
                }
            }
        }
    }
}
