import SwiftUI
import MochletCore

/// The island's design tokens: one type scale, one grey ramp, the state colours, radii and the
/// few spacings every card is built from. Nothing on a card goes below 10.5 pt or 40 % white.
enum IslandStyle {
    // MARK: Type scale
    static let hero = Font.system(size: 18, weight: .semibold, design: .rounded)
    static let title = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 12.5, design: .rounded)
    static let bodyStrong = Font.system(size: 12.5, weight: .semibold, design: .rounded)
    static let secondary = Font.system(size: 11.5, design: .rounded)
    static let secondaryStrong = Font.system(size: 11.5, weight: .semibold, design: .rounded)
    static let caption = Font.system(size: 10.5, weight: .medium, design: .rounded)
    static let captionStrong = Font.system(size: 10.5, weight: .semibold, design: .rounded)
    static let mono = Font.system(size: 11.5, design: .monospaced)
    static let monoSmall = Font.system(size: 10.5, design: .monospaced)

    // MARK: Ink ramp (white over black)
    static let ink = Color.white.opacity(0.96)
    static let ink2 = Color.white.opacity(0.72)
    static let ink3 = Color.white.opacity(0.52)
    static let hint = Color.white.opacity(0.40)
    static let hairline = Color.white.opacity(0.07)
    static let fill = Color.white.opacity(0.09)
    static let fillHover = Color.white.opacity(0.14)
    static let fillSelected = Color.white.opacity(0.22)
    static let fieldFill = Color.white.opacity(0.07)
    static let focusRing = Color.white.opacity(0.20)

    // MARK: State colours
    static let thinking = Color(red: 0.70, green: 0.61, blue: 1.0)
    static let working = Color(red: 0.50, green: 0.83, blue: 1.0)
    static let attention = Color(red: 1.0, green: 0.76, blue: 0.30)
    static let done = Color(red: 0.45, green: 0.90, blue: 0.60)
    static let error = Color(red: 0.94, green: 0.31, blue: 0.42)
    static let neutral = Color.white.opacity(0.45)

    static func color(_ s: SessionState) -> Color {
        switch s {
        case .idle, .ended: return neutral
        case .thinking: return thinking
        case .working: return working
        case .approval, .question: return attention
        case .finished: return done
        case .error, .ratelimit: return error
        }
    }

    static func label(_ s: SessionState) -> String {
        switch s {
        case .idle: return "idle"
        case .thinking: return "thinking"
        case .working: return "working"
        case .approval: return "needs approval"
        case .question: return "has a question"
        case .finished: return "done"
        case .error: return "error"
        case .ratelimit: return "rate limited"
        case .ended: return "ended"
        }
    }

    static func elapsed(_ d: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    /// The colour washed over a card's bottom corner, by view (and the focused session's state).
    static func wash(for view: NotchView, session: SessionState?) -> Color? {
        switch view {
        case .approval, .question: return attention
        case .sessionDetail, .diff:
            switch session {
            case .finished?: return done
            case .error?, .ratelimit?: return error
            case .approval?, .question?: return attention
            default: return nil
            }
        case .meetingLive: return working
        case .toast: return nil
        default: return nil
        }
    }

    // MARK: Radii and spacing
    static let chipRadius: CGFloat = 8
    static let buttonRadius: CGFloat = 10
    static let fieldRadius: CGFloat = 10
    static let cardRadius: CGFloat = 14
    static let rowRadius: CGFloat = 9
    static let s4: CGFloat = 4
    static let s6: CGFloat = 6
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16

    /// `~` for the home folder; paths are shown middle-truncated.
    static func tilde(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}
