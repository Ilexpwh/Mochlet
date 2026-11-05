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

    public enum TimerID: String, Sendable, CaseIterable {
        case compactHide, expandedIdle, hoverClose, greetingCollapse
    }

    public enum Input: Equatable, Sendable {
        case launch
        case pointerEntered
        case pointerLeft
        case click
        case reveal
        case openExternally(NotchView)
        case switchView(NotchView)
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
        public var expandedIdle: Double = 15
        public var compactHide: Double = 60
        public var hoverCloseGrace: Double = 0.6
        public var greetingAutoCollapse: Double = 0.6
        public var greetingHoverCollapse: Double = 10
        public var openOnHover = false
        public init() {}
    }

    public var config = Config()
    public private(set) var state: State = .hidden
    public private(set) var openedByHover = false
    public private(set) var pointerInside = false
    private var stateBeforeListening: State = .hidden

    public init(config: Config = Config()) {
        self.config = config
    }

    /// `heldOpen`: a pending approval/question, focused input, push-to-talk, drag or recording
    /// keeps the island from collapsing or hiding on timers and pointer leave.
    public mutating func handle(_ input: Input, heldOpen: Bool = false) -> [Effect] {
        var fx: [Effect] = []
        switch input {
        case .launch:
            fx.append(.cancelAll)
            fx += transition(to: .expanded(.greeting))

        case .pointerEntered:
            pointerInside = true
            if config.openOnHover, state == .hidden || state == .compact, !heldOpen {
                fx.append(.cancelAll)
                openedByHover = true
                fx += transition(to: .expanded(.home))
                return fx
            }
            switch state {
            case .hidden:
                fx.append(.cancelAll)
                if heldOpen {
                    fx += transition(to: .expanded(.home))
                } else {
                    fx.append(.peek)
                    fx += transition(to: .compact)
                }
            case .compact:
                fx.append(.cancel(.compactHide))
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
                guard !heldOpen else { break }
                if v == .greeting {
                    fx.append(.cancel(.greetingCollapse))
                    fx += transition(to: .compact)
                    fx.append(.schedule(.compactHide, config.compactHide))
                } else if openedByHover {
                    fx.append(.schedule(.hoverClose, config.hoverCloseGrace))
                } else {
                    fx.append(.schedule(.expandedIdle, config.expandedIdle))
                }
            case .listening:
                break
            }

        case .click:
            openedByHover = false
            guard state == .compact || state == .hidden || state == .listening else { break }
            fx.append(.cancelAll)
            fx += transition(to: .expanded(.home))

        case .reveal:
            guard state == .hidden else { break }
            fx.append(.cancelAll)
            fx.append(.peek)
            fx += transition(to: .compact)
            fx.append(.schedule(.compactHide, config.compactHide))

        case .openExternally(let view):
            fx.append(.cancelAll)
            openedByHover = false
            fx += transition(to: .expanded(view))
            if !pointerInside, !heldOpen { fx.append(.schedule(.expandedIdle, config.expandedIdle)) }

        case .switchView(let view):
            guard case .expanded = state else { break }
            fx += transition(to: .expanded(view))

        case .collapse:
            openedByHover = false
            guard state.isExpanded || state == .listening else { break }
            fx.append(.cancelAll)
            fx += transition(to: .compact)
            if !pointerInside { fx.append(.schedule(.compactHide, config.compactHide)) }

        case .hide:
            fx.append(.cancelAll)
            openedByHover = false
            fx += transition(to: .hidden)

        case .timer(let id):
            switch id {
            case .compactHide:
                if state == .compact, !heldOpen { fx += transition(to: .hidden) }
            case .expandedIdle, .hoverClose:
                if case .expanded(let v) = state, v != .greeting, !heldOpen {
                    openedByHover = false
                    fx += transition(to: .compact)
                    if !pointerInside { fx.append(.schedule(.compactHide, config.compactHide)) }
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
                if !heldOpen, !pointerInside { fx.append(.schedule(.expandedIdle, config.expandedIdle)) }
            } else {
                fx += transition(to: .compact)
                if !pointerInside { fx.append(.schedule(.compactHide, config.compactHide)) }
            }

        case .userInteracted:
            openedByHover = false
        }
        return fx
    }

    private mutating func transition(to new: State) -> [Effect] {
        guard new != state else { return [] }
        state = new
        return [.setState(new)]
    }
}
