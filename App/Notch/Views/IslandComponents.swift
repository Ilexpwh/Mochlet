import SwiftUI
import MochletCore

// The island's shared pieces. Every card is built from these so the type, spacing, hover and
// pressed states, keycap hints and accessibility labels are the same everywhere.

enum IslandButtonRole { case primary, secondary, quiet, destructive }

/// The app's reduce-motion choice (Settings override, else the system switch), set once at the root.
private struct IslandReduceMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var islandReduceMotion: Bool {
        get { self[IslandReduceMotionKey.self] }
        set { self[IslandReduceMotionKey.self] = newValue }
    }
}

/// Pressed buttons scale down a touch (not with reduce motion) and dim slightly.
struct IslandPressStyle: ButtonStyle {
    @Environment(\.islandReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A capsule button. Primary = ink fill with black text (one per card, the ⏎ action);
/// secondary = soft fill; quiet = text only; destructive = coral.
struct IslandButton: View {
    let title: String
    let symbol: String?
    var role: IslandButtonRole = .secondary
    var keycap: String? = nil
    var expands = false
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String? = nil, role: IslandButtonRole = .secondary, keycap: String? = nil, expands: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.role = role
        self.keycap = keycap
        self.expands = expands
        self.action = action
    }

    private var fill: Color {
        switch role {
        case .primary: return hovering ? Color.white : IslandStyle.ink
        case .secondary: return hovering ? IslandStyle.fillHover : IslandStyle.fill
        case .quiet: return hovering ? IslandStyle.fill : .clear
        case .destructive: return IslandStyle.error.opacity(hovering ? 0.28 : 0.18)
        }
    }

    private var foreground: Color {
        switch role {
        case .primary: return .black
        case .secondary: return IslandStyle.ink
        case .quiet: return hovering ? IslandStyle.ink : IslandStyle.ink2
        case .destructive: return Color(red: 1.0, green: 0.62, blue: 0.68)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                }
                Text(title).font(IslandStyle.secondaryStrong).lineLimit(1)
                if let keycap {
                    Text(keycap)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(role == .primary ? Color.black.opacity(0.12) : Color.white.opacity(0.12)))
                        .opacity(0.8)
                }
            }
            .padding(.horizontal, role == .quiet ? 8 : 11)
            .frame(height: 27)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(Capsule().fill(fill))
            .foregroundStyle(foreground)
            .contentShape(Capsule())
        }
        .buttonStyle(IslandPressStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A 26 pt round icon button: dim at rest, bright on hover.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var size: CGFloat = 26
    var tint: Color? = nil
    var filled = false
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, help: String = "", size: CGFloat = 26, tint: Color? = nil, filled: Bool = false, shortcut: KeyboardShortcut? = nil,
         action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.size = size
        self.tint = tint
        self.filled = filled
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? (hovering ? Color.white : IslandStyle.ink) : hovering ? IslandStyle.fillHover : Color.clear))
                .foregroundStyle(filled ? Color.black : tint ?? (hovering ? IslandStyle.ink : IslandStyle.ink2))
                .contentShape(Circle())
        }
        .buttonStyle(IslandPressStyle())
        .keyboardShortcut(shortcut)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help.isEmpty ? symbol : help)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// One header per card: a glyph or symbol, the title, a quieter subtitle, right-aligned meta
/// ("1/2", "33 s · 11 lines") and whatever trailing controls the card needs.
struct CardHeader<Trailing: View>: View {
    var glyph: String? = nil
    var symbol: String? = nil
    var tint: Color = IslandStyle.ink2
    let title: String
    var subtitle: String? = nil
    var meta: String? = nil
    /// With the app, the header ends with the pin and close buttons every card shares.
    var app: AppCoordinator? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(glyph: String? = nil, symbol: String? = nil, tint: Color = IslandStyle.ink2, title: String, subtitle: String? = nil, meta: String? = nil,
         app: AppCoordinator? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.glyph = glyph
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.meta = meta
        self.app = app
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 7) {
            if let glyph {
                Text(glyph).font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            }
            Text(title).font(IslandStyle.title).foregroundStyle(IslandStyle.ink).lineLimit(1).layoutPriority(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let meta, !meta.isEmpty {
                Text(meta).font(IslandStyle.caption).foregroundStyle(IslandStyle.ink3).monospacedDigit().lineLimit(1)
            }
            trailing()
            if let app { CardTools(app: app) }
        }
        .frame(minHeight: 26)
    }
}

/// Pin (keep the island open) and close, at the end of every card header.
struct CardTools: View {
    let app: AppCoordinator

    var body: some View {
        let pinned = app.notch.isPinned
        HStack(spacing: 0) {
            IconButton(pinned ? "pin.fill" : "pin", help: pinned ? "Unpin (⌘P)" : "Keep open (⌘P)", size: 24, tint: pinned ? IslandStyle.ink : nil) {
                app.notch.isPinned.toggle()
                app.window.send(.userInteracted)
            }
            IconButton("xmark", help: "Close (esc)", size: 24) { app.window.closeCard() }
        }
        .padding(.trailing, -4)
    }
}

/// A key hint: a small keycap and what it does ("⏎ send").
struct KeyHint: View {
    let keys: [(String, String)]
    init(_ keys: [(String, String)]) { self.keys = keys }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                HStack(spacing: 4) {
                    Text(k.0)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(IslandStyle.fill))
                        .foregroundStyle(IslandStyle.ink3)
                    Text(k.1).font(IslandStyle.caption).foregroundStyle(IslandStyle.hint)
                }
            }
        }
    }
}

/// A short note under a header ("Handled in iTerm.").
struct NoteLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
}

/// A small capsule label; selectable when used as an option.
struct Chip: View {
    let text: String
    var symbol: String? = nil
    var selected = false
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(IslandStyle.caption).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(selected ? IslandStyle.fillSelected : IslandStyle.fill))
        .foregroundStyle(tint ?? (selected ? IslandStyle.ink : IslandStyle.ink2))
        .fixedSize()
    }
}

/// A chip that acts: hover brightens, press scales.
struct ChipButton: View {
    let text: String
    var symbol: String? = nil
    var selected = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).padding(.top, 2) }
                Text(text).font(IslandStyle.caption).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: IslandStyle.chipRadius + 2, style: .continuous).fill(selected ? IslandStyle.fillSelected : hovering ? IslandStyle.fillHover : IslandStyle.fill))
            .foregroundStyle(selected || hovering ? IslandStyle.ink : IslandStyle.ink2)
            .contentShape(RoundedRectangle(cornerRadius: IslandStyle.chipRadius + 2, style: .continuous))
        }
        .buttonStyle(IslandPressStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(text)
    }
}

/// A radial colour wash rising from the card's bottom-left corner in the state colour.
struct StateWash: View {
    let color: Color

    var body: some View {
        RadialGradient(colors: [color.opacity(0.17), color.opacity(0.0)],
                       center: UnitPoint(x: 0.22, y: 1.15), startRadius: 0, endRadius: 460)
            .allowsHitTesting(false)
    }
}

/// A scroll that is as tall as its content up to `maxHeight` (so cards stay content-driven), with
/// the top and bottom edges fading out only while there is more to scroll. No scroll bar.
struct FadeScroll<Content: View>: View {
    var axes: Axis.Set = .vertical
    var maxHeight: CGFloat? = nil
    var fade: CGFloat = 12
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0
    @State private var frameHeight: CGFloat = 0

    var body: some View {
        let overflow = contentHeight > frameHeight + 1
        ScrollView(axes, showsIndicators: false) {
            content()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    if abs(contentHeight - h) > 0.5 { contentHeight = h }
                }
        }
        .frame(height: maxHeight.map { min($0, max(1, contentHeight)) })
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            if abs(frameHeight - h) > 0.5 { frameHeight = h }
        }
        .mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [overflow ? .clear : .black, .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
                Color.black
                LinearGradient(colors: [.black, overflow ? .clear : .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
            }
        )
    }
}

/// A symbol, one line that says what is going on, and a quieter hint of what to do.
struct EmptyState: View {
    let symbol: String
    let line: String
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(IslandStyle.ink3)
                Text(line).font(IslandStyle.bodyStrong).foregroundStyle(IslandStyle.ink).fixedSize(horizontal: false, vertical: true)
            }
            if let hint {
                Text(hint).font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink3).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A file path in small mono, `~` for home, truncated in the middle so the file name stays.
struct PathText: View {
    let path: String
    var body: some View {
        Text(IslandStyle.tilde(path)).font(IslandStyle.monoSmall).foregroundStyle(IslandStyle.hint).lineLimit(1).truncationMode(.middle)
    }
}

/// A 1 pt hairline between sections.
struct SectionRule: View {
    var body: some View { Rectangle().fill(IslandStyle.hairline).frame(height: 1) }
}

/// A 6 pt progress bar.
struct ProgressBar: View {
    let value: Double
    var tint: Color = IslandStyle.ink2
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(IslandStyle.fill)
                Capsule().fill(tint).frame(width: max(6, g.size.width * CGFloat(min(1, max(0, value)))))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.25), value: value)
    }
}

/// A small coloured count.
struct Badge: View {
    let count: Int
    var color: Color = IslandStyle.attention
    var body: some View {
        Text("\(count)").font(.system(size: 9.5, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(.black).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color))
    }
}

/// A hover-highlighted list row.
struct ListRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: IslandStyle.rowRadius, style: .continuous).fill(hovering ? IslandStyle.fillHover : IslandStyle.fill))
                .contentShape(RoundedRectangle(cornerRadius: IslandStyle.rowRadius, style: .continuous))
        }
        .buttonStyle(IslandPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// The island's text field look: soft fill, hairline, a brighter ring while focused.
    func islandField(focused: Bool = false, size: CGFloat = 12.5, mono: Bool = false) -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: size, design: mono ? .monospaced : .rounded))
            .foregroundStyle(IslandStyle.ink)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: IslandStyle.fieldRadius, style: .continuous).fill(IslandStyle.fieldFill))
            .overlay(RoundedRectangle(cornerRadius: IslandStyle.fieldRadius, style: .continuous).stroke(focused ? IslandStyle.focusRing : IslandStyle.hairline, lineWidth: 1))
    }

    /// Body text that wraps with a little line spacing.
    func islandBody() -> some View {
        self.font(IslandStyle.body).foregroundStyle(IslandStyle.ink).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }
}

/// The placeholder text of a field, in the hint grey.
func fieldPrompt(_ s: String) -> Text { Text(s).foregroundStyle(IslandStyle.ink3) }

/// The capsule look for a `Menu` label, matching a secondary `IslandButton`.
struct MenuLabel: View {
    let title: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
            Text(title).font(IslandStyle.secondaryStrong).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.7)
        }
        .padding(.horizontal, 11)
        .frame(height: 27)
        .background(Capsule().fill(IslandStyle.fill))
        .foregroundStyle(IslandStyle.ink)
        .contentShape(Capsule())
    }
}

/// The round icon look for a `Menu` label, matching an `IconButton`.
struct MenuIconLabel: View {
    let symbol: String
    var size: CGFloat = 24
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(IslandStyle.ink2)
            .contentShape(Circle())
    }
}

/// A two-line selectable option (label + description) for question cards.
struct OptionChip: View {
    let label: String
    var description: String = ""
    var selected = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: IslandStyle.buttonRadius, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                    Text(label).font(IslandStyle.secondaryStrong).fixedSize(horizontal: false, vertical: true)
                }
                if !description.isEmpty {
                    Text(description).font(IslandStyle.caption).foregroundStyle(selected ? IslandStyle.ink2 : IslandStyle.ink3)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(shape.fill(selected ? IslandStyle.fillSelected : hovering ? IslandStyle.fillHover : IslandStyle.fill))
            .overlay(shape.stroke(selected ? IslandStyle.focusRing : Color.clear, lineWidth: 1))
            .foregroundStyle(IslandStyle.ink)
            .contentShape(shape)
        }
        .buttonStyle(IslandPressStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A rounded box that groups a row's controls without being a button itself.
struct RowBox<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: IslandStyle.rowRadius, style: .continuous).fill(IslandStyle.fill))
    }
}
