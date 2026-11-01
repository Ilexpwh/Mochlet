import SwiftUI
import SlimeCore

@MainActor @Observable final class NotchModel {
    var interaction = IslandInteraction()
    var width: CGFloat = 320
    var height: CGFloat = 38
    var notchWidth: CGFloat = 190
    var notchHeight: CGFloat = 32
    var hasNotch = true
    var tab = "Chat"
    var topRadius: CGFloat = -6
    var cornerRadius: CGFloat = 14
}

struct NotchView: View {
    @Bindable var model: AppModel
    @Bindable var island: NotchModel
    let hover: (Bool) -> Void
    let open: () -> Void
    let collapse: () -> Void
    let interact: () -> Void
    let workspace: () -> Void
    let stateChanged: () -> Void

    private var shape: IslandShape {
        IslandShape(width: island.width, height: island.height,
                    cornerRadius: island.cornerRadius, topRadius: island.topRadius)
    }
    var body: some View {
        ZStack(alignment: .top) {
            if island.interaction.mode == .expanded {
                expanded
                    .frame(width: 640, height: 400, alignment: .top)
                    .padding(.top, island.notchHeight)
            } else if island.interaction.mode == .compact {
                HStack(spacing: 0) {
                    SlimeView(mood: model.slimeMood, tint: model.tint)
                        .frame(width: 36, height: 36)
                    Spacer(minLength: island.notchWidth)
                    if !model.pendingInputs.isEmpty {
                        Text("\(model.pendingInputs.count)").font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.black).frame(width: 20, height: 20).background(model.tint, in: Circle())
                    } else {
                        Image(systemName: model.isBusy ? "ellipsis" : "sparkle")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(model.tint)
                            .frame(width: 24)
                    }
                }
                .padding(.horizontal, 18).frame(width: island.width, height: island.height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Open Mochlet, \(model.pendingInputs.count) requests")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open() }
            }
        }
        .frame(width: island.width, height: island.height, alignment: .top)
        .background(shape.fill(.black.opacity(island.interaction.mode == .hidden && island.hasNotch ? 0 : 1)))
        .clipShape(shape)
        .contentShape(shape)
        .onHover(perform: hover)
        .onTapGesture { if island.interaction.mode != .expanded { open() } else { interact() } }
        .preferredColorScheme(.dark)
        .tint(model.tint)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.pendingInputs.count) { _, count in
            if count > 0 { island.tab = "Attention" }
            stateChanged()
        }
        .onChange(of: model.isBusy) { _, _ in stateChanged() }
        .onChange(of: model.draft.isEmpty) { _, _ in stateChanged() }
        .onChange(of: model.hideWhenIdle) { _, _ in stateChanged() }
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SlimeView(mood: model.slimeMood, tint: model.tint).frame(width: 32, height: 32)
                Text(model.slimeName).font(.system(size: 13, weight: .semibold))
                Spacer()
                ForEach(["Chat", "Tasks", "Attention"], id: \.self) { tab in
                    Button { island.tab = tab; interact() } label: {
                        Text(tab == "Attention" && !model.pendingInputs.isEmpty ? "Attention · \(model.pendingInputs.count)" : tab)
                            .font(.system(size: 11, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 6)
                            .background(island.tab == tab ? .white.opacity(0.13) : .clear, in: Capsule())
                    }.buttonStyle(.plain)
                }
                Divider().frame(height: 16)
                Button { island.interaction.pinned.toggle(); stateChanged() } label: {
                    Image(systemName: island.interaction.pinned ? "pin.fill" : "pin")
                }.help(island.interaction.pinned ? "Unpin island" : "Keep island open")
                    .accessibilityLabel(island.interaction.pinned ? "Unpin island" : "Pin island")
                Button(action: workspace) { Image(systemName: "macwindow") }
                    .help("Open workspace").accessibilityLabel("Open workspace")
                Button(action: collapse) { Image(systemName: "chevron.up") }
                    .help("Collapse · Escape").accessibilityLabel("Collapse island")
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 20).padding(.bottom, 6)
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1).padding(.horizontal, 20)
            if island.tab == "Chat" {
                CompanionView(model: model, compact: true)
            } else if island.tab == "Attention" {
                ScrollView {
                    if model.pendingInputs.isEmpty {
                        ContentUnavailableView("All clear", systemImage: "checkmark.circle", description: Text("Questions and approvals will appear here."))
                    } else {
                        VStack(spacing: 12) {
                            ForEach(model.pendingInputs) { input in AttentionView(input: input, model: model).id(input.id) }
                        }.padding(18)
                    }
                }
            } else {
                ScrollView {
                    if model.tasks.isEmpty {
                        ContentUnavailableView("A little room for big work", systemImage: "tray", description: Text("Start a task in Chat to see it here."))
                    } else {
                        VStack(spacing: 8) {
                            ForEach(model.tasks.prefix(12)) { task in
                                Button {
                                    model.selectedTaskID = task.id; model.selectedProjectID = task.projectID
                                    island.tab = "Chat"; interact()
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: task.state == .running ? "ellipsis" : "terminal")
                                            .foregroundStyle(model.tint).frame(width: 24)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(task.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Text(model.projects.first(where: { $0.id == task.projectID })?.name ?? "Project")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(task.state.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                                    }.padding(12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain)
                            }
                        }.padding(18)
                    }
                }
            }
        }
    }
}
