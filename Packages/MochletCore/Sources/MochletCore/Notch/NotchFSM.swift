import Foundation

/// What the island shows while expanded.
public enum NotchView: String, Sendable, Codable, CaseIterable, Equatable {
    case greeting, home, ask, menu, approval, question, chat, diff, sessionDetail
    case meetingLive, ingest, projects, knowledge, signals, toast, whatsNew
}

/// Pure open/close logic of the island. Inputs come from the pointer poll, clicks, hooks and
/// timers; outputs are effects the window controller performs (set the mode, arm/cancel timers).
/// Timers never live here: `.schedule`/`.cancel` effects carry them to the host.
public struct NotchFSM: Sendable, Equatable {
    public enum State: Equatable, Sendable {
        case hidden
        case compact
        case expanded(NotchView)
        case listening

        public var isExpanded: Bool { if case .expanded = self { return true } else { return false } }
        public var isGreeting: Bool { self == .expanded(.greeting) }
    }

    /// Something that keeps the island open. `.any` holds in every state (push-to-talk, a drag);
    /// `.view(v)` only while `v` is showing (a focused field, a running stream); `.card(v)` is a
    /// card waiting on the user: it holds while showing, keeps the compact strip from hiding, and
    /// the island comes back to it after a toast or when another view collapses.
    public struct Hold: Hashable, Sendable {
        public enum Scope: Hashable, Sendable {
            case any
            case view(NotchView)
            case card(NotchView)
        }

        public var key: String
        public var scope: Scope

        public init(_ key: String, _ scope: Scope = .any) {
            self.key = key
            self.scope = scope
        }
    }

    public enum TimerID: String, Sendable, CaseIterable {
        case compactHide, expandedIdle, hoverClose, greetingCollapse, doneBeat
    }

    public enum Input: Equatable, Sendable {
        case launch
        case pointerEntered
        case pointerLeft
        case click
        case reveal
        /// The app shows something on its own: a notification, a card that needs the user.
        case openExternally(NotchView)
        /// The user asked for it: a click on the slime, a hotkey, a menu item.
        case open(NotchView)
        case switchView(NotchView)
        /// An action on the card is done; the island folds after a short beat.
        case acknowledged(delay: Double? = nil)
        case collapse
        case hide
        case timer(TimerID)
        case greetingComplete
        case voiceStart
        case voiceEnd
        case userInteracted
    }

    public enum Effect: Equatable, Sendable {
        case setState(State)
        case schedule(TimerID, Double)
        case cancel(TimerID)
        case cancelAll
        case peek
    }

    public struct Config: Sendable, Equatable {
        /// A card the user opened or engaged with closes this long after the pointer leaves.
        public var expandedIdle: Double = 15
        public var compactHide: Double = 60
        /// Opened by hovering: closes this long after the pointer leaves.
        public var hoverCloseGrace: Double = 0.6
        /// A notification the user only looked at closes this long after the pointer leaves.
        public var leaveGrace: Double = 0.8
        /// An acknowledged card folds after this beat.
        public var doneBeat: Double = 0.9
        public var greetingAutoCollapse: Double = 0.6
        public var greetingHoverCollapse: Double = 10
        public var openOnHover = false
        public init() {}
    }

    /// Cards that take precedence when the island returns to a pending one.
    public static let cardPriority: [NotchView] = [.approval, .question, .meetingLive, .ingest]

    public var config = Config()
    public private(set) var state: State = .hidden
    public private(set) var openedByHover = false
    /// The current card was opened by the app (a notification), not by the user.
    public private(set) var openedExternally = false
    /// The user interacted with the current card (click, key, drag).
    public private(set) var engaged = false
    public private(set) var pointerInside = false
    private var stateBeforeListening: State = .hidden

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Whether `holds` keep the island open in the current state.
    public func isHeld(_ holds: Set<Hold>) -> Bool {
        holds.contains { h in
            switch h.scope {
            case .any:
                return true
            case .view(let v):
                return state == .expanded(v)
            case .card(let v):
                switch state {
                case .expanded(let cur): return cur == v
                case .compact, .hidden: return true
                case .listening: return false
                }
            }
        }
    }

    /// The card waiting on the user, highest priority first.
    public func pendingCard(_ holds: Set<Hold>) -> NotchView? {
        let cards = holds.compactMap { h -> NotchView? in if case .card(let v) = h.scope { return v } else { return nil } }
        guard !cards.isEmpty else { return nil }
        return Self.cardPriority.first { cards.contains($0) } ?? cards.first
    }

    /// `heldOpen` as one global hold (tests and simple hosts).
    public mutating func handle(_ input: Input, heldOpen: Bool) -> [Effect] {
        handle(input, holds: heldOpen ? [Hold("any")] : [])
    }

    public mutating func handle(_ input: Input, holds: Set<Hold> = []) -> [Effect] {
        var fx: [Effect] = []
        switch input {
        case .launch:
            fx.append(.cancelAll)
            fx += transition(to: .expanded(.greeting))

        case .pointerEntered:
            pointerInside = true
            if config.openOnHover, state == .hidden || state == .compact, !isHeld(holds) {
                fx.append(.cancelAll)
                openedByHover = true
                openedExternally = false
                engaged = false
                fx += transition(to: .expanded(.home))
                return fx
            }
            switch state {
            case .hidden:
                fx.append(.cancelAll)
                if let card = pendingCard(holds) {
                    fx += present(card)
                } else if isHeld(holds) {
                    fx += transition(to: .expanded(.home))
                } else {
                    fx.append(.peek)
                    fx += transition(to: .compact)
                }
            case .compact:
                fx.append(.cancel(.compactHide))
                if let card = pendingCard(holds) {
                    fx.append(.cancelAll)
                    fx += present(card)
                }
            case .expanded(let v):
                fx.append(.cancel(.expandedIdle))
                fx.append(.cancel(.hoverClose))
                if v == .greeting { fx.append(.schedule(.greetingCollapse, config.greetingHoverCollapse)) }
            case .listening:
                if config.openOnHover {
                    fx.append(.cancelAll)
                    openedByHover = true
                    fx += transition(to: .expanded(.home))
                }
            }

        case .pointerLeft:
            pointerInside = false
            switch state {
            case .hidden:
                break
            case .compact:
                fx.append(.schedule(.compactHide, config.compactHide))
            case .expanded(let v):
                guard !isHeld(holds) else { break }
                if v == .greeting {
                    fx.append(.cancel(.greetingCollapse))
                    fx += transition(to: .compact)
                    fx.append(.schedule(.compactHide, config.compactHide))
                } else if openedByHover {
                    fx.append(.schedule(.hoverClose, config.hoverCloseGrace))
                } else if openedExternally, !engaged {
                    fx.append(.schedule(.hoverClose, config.leaveGrace))
                } else {
                    fx.append(.schedule(.expandedIdle, config.expandedIdle))
                }
            case .listening:
                break
            }

        case .click:
            openedByHover = false
            openedExternally = false
            engaged = true
            guard state == .compact || state == .hidden || state == .listening else { break }
            fx.append(.cancelAll)
            fx += transition(to: .expanded(pendingCard(holds) ?? .home))

        case .reveal:
            guard state == .hidden else { break }
            fx.append(.cancelAll)
            fx.append(.peek)
            fx += transition(to: .compact)
            fx.append(.schedule(.compactHide, config.compactHide))

        case .openExternally(let view):
            fx.append(.cancelAll)
            openedByHover = false
            openedExternally = true
            engaged = false
            fx += transition(to: .expanded(view))
            if !pointerInside, !isHeld(holds) { fx.append(.schedule(.expandedIdle, config.expandedIdle)) }

        case .open(let view):
            fx.append(.cancelAll)
            openedByHover = false
            openedExternally = false
            engaged = true
            fx += transition(to: .expanded(view))
            if !pointerInside, !isHeld(holds) { fx.append(.schedule(.expandedIdle, config.expandedIdle)) }

        case .switchView(let view):
            guard case .expanded = state else { break }
            fx += transition(to: .expanded(view))

        case .acknowledged(let delay):
            guard case .expanded = state else { break }
            openedByHover = false
            fx.append(.cancel(.expandedIdle))
            fx.append(.cancel(.hoverClose))
            fx.append(.schedule(.doneBeat, delay ?? config.doneBeat))

        case .collapse:
            openedByHover = false
            guard state.isExpanded || state == .listening else { break }
            fx.append(.cancelAll)
            fx += collapseOrReturn(holds)

        case .hide:
            fx.append(.cancelAll)
            openedByHover = false
            fx += transition(to: .hidden)

        case .timer(let id):
            switch id {
            case .compactHide:
                if state == .compact, !isHeld(holds) { fx += transition(to: .hidden) }
            case .expandedIdle, .hoverClose, .doneBeat:
                if case .expanded(let v) = state, v != .greeting, !isHeld(holds) {
                    openedByHover = false
                    fx += collapseOrReturn(holds)
                }
            case .greetingCollapse:
                if state.isGreeting {
                    fx += transition(to: .compact)
                    if !pointerInside { fx.append(.schedule(.compactHide, config.compactHide)) }
                }
            }

        case .greetingComplete:
            guard state.isGreeting else { break }
            fx.append(.schedule(.greetingCollapse, pointerInside ? config.greetingHoverCollapse : config.greetingAutoCollapse))

        case .voiceStart:
            stateBeforeListening = state
            fx.append(.cancelAll)
            openedByHover = false
            fx += transition(to: .listening)

        case .voiceEnd:
            guard state == .listening else { break }
            if case .expanded(let v) = stateBeforeListening, v != .greeting {
                fx += transition(to: .expanded(v))
                if !isHeld(holds), !pointerInside { fx.append(.schedule(.expandedIdle, config.expandedIdle)) }
            } else {
                fx += transition(to: .compact)
                if !pointerInside { fx.append(.schedule(.compactHide, config.compactHide)) }
            }

        case .userInteracted:
            openedByHover = false
            engaged = true
        }
        return fx
    }

    /// Fold to compact, or come back to the card that is still waiting on the user.
    private mutating func collapseOrReturn(_ holds: Set<Hold>) -> [Effect] {
        if let card = pendingCard(holds), state != .expanded(card) {
            return present(card)
        }
        var fx = transition(to: .compact)
        if !pointerInside { fx.append(.schedule(.compactHide, config.compactHide)) }
        return fx
    }

    private mutating func present(_ card: NotchView) -> [Effect] {
        openedByHover = false
        openedExternally = true
        engaged = false
        return transition(to: .expanded(card))
    }

    private mutating func transition(to new: State) -> [Effect] {
        guard new != state else { return [] }
        var fx: [Effect] = []
        if case .expanded = state, new == .compact || new == .hidden {
            // Nothing armed for the open island may fire after it folds (a stale idle timer
            // would otherwise re-arm the compact hide a while later).
            fx += [.cancel(.expandedIdle), .cancel(.hoverClose), .cancel(.doneBeat)]
        }
        state = new
        fx.append(.setState(new))
        return fx
    }
}
