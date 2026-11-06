import Testing
@testable import MochletCore

@Suite struct NotchFSMTests {
    @Test func launchGreetsThenCollapses() {
        var f = NotchFSM()
        var fx = f.handle(.launch)
        #expect(f.state == .expanded(.greeting))
        #expect(fx.contains(.setState(.expanded(.greeting))))
        fx = f.handle(.greetingComplete)
        #expect(fx.contains(.schedule(.greetingCollapse, 0.6)))
        fx = f.handle(.timer(.greetingCollapse))
        #expect(f.state == .compact)
        #expect(fx.contains(.schedule(.compactHide, 60)))
    }

    @Test func hoverPeeksAndHides() {
        var f = NotchFSM()
        var fx = f.handle(.pointerEntered)
        #expect(f.state == .compact)
        #expect(fx.contains(.peek))
        fx = f.handle(.pointerLeft)
        #expect(fx.contains(.schedule(.compactHide, 60)))
        _ = f.handle(.timer(.compactHide))
        #expect(f.state == .hidden)
    }

    @Test func clickOpensHomeAndIdleCollapses() {
        var f = NotchFSM()
        _ = f.handle(.pointerEntered)
        _ = f.handle(.click)
        #expect(f.state == .expanded(.home))
        let fx = f.handle(.pointerLeft)
        #expect(fx.contains(.schedule(.expandedIdle, 15)))
        _ = f.handle(.timer(.expandedIdle))
        #expect(f.state == .compact)
    }

    @Test func heldOpenBlocksTimers() {
        var f = NotchFSM()
        _ = f.handle(.openExternally(.approval))
        #expect(f.state == .expanded(.approval))
        _ = f.handle(.pointerLeft, heldOpen: true)
        _ = f.handle(.timer(.expandedIdle), heldOpen: true)
        #expect(f.state == .expanded(.approval))
        _ = f.handle(.timer(.expandedIdle), heldOpen: false)
        #expect(f.state == .compact)
    }

    @Test func openOnHoverUsesGrace() {
        var c = NotchFSM.Config()
        c.openOnHover = true
        var f = NotchFSM(config: c)
        _ = f.handle(.pointerEntered)
        #expect(f.state == .expanded(.home))
        #expect(f.openedByHover)
        let fx = f.handle(.pointerLeft)
        #expect(fx.contains(.schedule(.hoverClose, 0.6)))
        _ = f.handle(.userInteracted)
        #expect(!f.openedByHover)
    }

    @Test func voiceRoundTrip() {
        var f = NotchFSM()
        _ = f.handle(.click)
        _ = f.handle(.voiceStart)
        #expect(f.state == .listening)
        _ = f.handle(.pointerLeft)
        #expect(f.state == .listening)
        _ = f.handle(.voiceEnd)
        #expect(f.state == .expanded(.home))
        _ = f.handle(.collapse)
        #expect(f.state == .compact)
    }

    @Test func revealAndHide() {
        var f = NotchFSM()
        let fx = f.handle(.reveal)
        #expect(f.state == .compact)
        #expect(fx.contains(.schedule(.compactHide, 60)))
        _ = f.handle(.reveal)
        #expect(f.state == .compact)
        _ = f.handle(.hide)
        #expect(f.state == .hidden)
    }

    @Test func pointerLeaveDuringGreetingCollapses() {
        var f = NotchFSM()
        _ = f.handle(.launch)
        _ = f.handle(.pointerEntered)
        _ = f.handle(.pointerLeft)
        #expect(f.state == .compact)
    }

    // MARK: Notifications fold once looked at or acted on

    @Test func notificationEnteredThenLeftUsesGrace() {
        var f = NotchFSM()
        var fx = f.handle(.openExternally(.sessionDetail))
        #expect(fx.contains(.schedule(.expandedIdle, 15)))
        fx = f.handle(.pointerEntered)
        #expect(fx.contains(.cancel(.expandedIdle)))
        fx = f.handle(.pointerLeft)
        #expect(fx.contains(.schedule(.hoverClose, 0.8)))
        #expect(!fx.contains(.schedule(.expandedIdle, 15)))
        _ = f.handle(.timer(.hoverClose))
        #expect(f.state == .compact)
    }

    @Test func engagedCardUsesIdle() {
        var f = NotchFSM()
        _ = f.handle(.openExternally(.sessionDetail))
        _ = f.handle(.pointerEntered)
        _ = f.handle(.userInteracted)
        let fx = f.handle(.pointerLeft)
        #expect(fx.contains(.schedule(.expandedIdle, 15)))
    }

    @Test func userOpenedCardUsesIdle() {
        var f = NotchFSM()
        _ = f.handle(.open(.chat))
        #expect(!f.openedExternally)
        _ = f.handle(.pointerEntered)
        let fx = f.handle(.pointerLeft)
        #expect(fx.contains(.schedule(.expandedIdle, 15)))
    }

    @Test func acknowledgedWithPointerInsideCollapsesAfterBeat() {
        var f = NotchFSM()
        _ = f.handle(.openExternally(.sessionDetail))
        _ = f.handle(.pointerEntered)
        var fx = f.handle(.acknowledged())
        #expect(fx.contains(.schedule(.doneBeat, 0.9)))
        fx = f.handle(.timer(.doneBeat))
        #expect(f.state == .compact)
        #expect(!fx.contains(.schedule(.compactHide, 60)))     // the pointer is still on the strip
        _ = f.handle(.acknowledged(delay: 2))
        #expect(f.state == .compact)                             // nothing to acknowledge when compact
    }

    @Test func foldCancelsExpandedTimers() {
        // The user clicks a button (engaged), the pointer leaves during the done beat, the beat
        // folds the island: the idle timer armed on leaving must not survive the fold.
        var f = NotchFSM()
        _ = f.handle(.openExternally(.question))
        _ = f.handle(.pointerEntered)
        _ = f.handle(.userInteracted)
        _ = f.handle(.acknowledged())
        var fx = f.handle(.pointerLeft)
        #expect(fx.contains(.schedule(.expandedIdle, 15)))
        fx = f.handle(.timer(.doneBeat))
        #expect(f.state == .compact)
        #expect(fx.contains(.cancel(.expandedIdle)) && fx.contains(.cancel(.hoverClose)))
        #expect(fx.contains(.schedule(.compactHide, 60)))
    }

    @Test func acknowledgedDelayIsHonoured() {
        var f = NotchFSM()
        _ = f.handle(.openExternally(.sessionDetail))
        let fx = f.handle(.acknowledged(delay: 2.4))
        #expect(fx.contains(.schedule(.doneBeat, 2.4)))
    }

    @Test func beatIsNoopWhileHeld() {
        var f = NotchFSM()
        let holds: Set<NotchFSM.Hold> = [NotchFSM.Hold("approval", .card(.approval))]
        _ = f.handle(.openExternally(.approval), holds: holds)
        _ = f.handle(.acknowledged(), holds: holds)
        _ = f.handle(.timer(.doneBeat), holds: holds)
        #expect(f.state == .expanded(.approval))
    }

    // MARK: Scoped holds

    @Test func scopedViewHoldDoesNotBlockAnotherCard() {
        var f = NotchFSM()
        let holds: Set<NotchFSM.Hold> = [NotchFSM.Hold("meeting", .view(.meetingLive))]
        _ = f.handle(.openExternally(.sessionDetail), holds: holds)
        var fx = f.handle(.pointerLeft, holds: holds)
        #expect(fx.contains(.schedule(.hoverClose, 0.8)))
        _ = f.handle(.timer(.hoverClose), holds: holds)
        #expect(f.state == .compact)
        // The held view itself stays.
        _ = f.handle(.openExternally(.meetingLive), holds: holds)
        fx = f.handle(.pointerLeft, holds: holds)
        #expect(!fx.contains { if case .schedule = $0 { return true } else { return false } })
        _ = f.handle(.timer(.expandedIdle), holds: holds)
        #expect(f.state == .expanded(.meetingLive))
    }

    @Test func anyHoldBlocksEverything() {
        var f = NotchFSM()
        let holds: Set<NotchFSM.Hold> = [NotchFSM.Hold("ptt")]
        _ = f.handle(.openExternally(.sessionDetail), holds: holds)
        _ = f.handle(.pointerLeft, holds: holds)
        _ = f.handle(.timer(.expandedIdle), holds: holds)
        #expect(f.state == .expanded(.sessionDetail))
        #expect(f.isHeld(holds))
    }

    @Test func toastOverApprovalReturnsToCard() {
        var f = NotchFSM()
        let holds: Set<NotchFSM.Hold> = [NotchFSM.Hold("approval", .card(.approval))]
        _ = f.handle(.openExternally(.approval), holds: holds)
        _ = f.handle(.openExternally(.toast), holds: holds)
        #expect(f.state == .expanded(.toast))
        _ = f.handle(.collapse, holds: holds)
        #expect(f.state == .expanded(.approval))
        // Answered: the hold goes, the beat folds it.
        _ = f.handle(.acknowledged())
        _ = f.handle(.timer(.doneBeat))
        #expect(f.state == .compact)
    }

    @Test func escOnCardCollapsesAndHoverReturns() {
        var f = NotchFSM()
        let holds: Set<NotchFSM.Hold> = [NotchFSM.Hold("question", .card(.question))]
        _ = f.handle(.openExternally(.question), holds: holds)
        _ = f.handle(.pointerEntered, holds: holds)
        _ = f.handle(.collapse, holds: holds)
        #expect(f.state == .compact)
        _ = f.handle(.pointerLeft, holds: holds)
        _ = f.handle(.pointerEntered, holds: holds)
        #expect(f.state == .expanded(.question))
    }

    @Test func compactDoesNotHideWhilePending() {
        var f = NotchFSM()
        let holds: Set<NotchFSM.Hold> = [NotchFSM.Hold("approval", .card(.approval))]
        _ = f.handle(.reveal, holds: holds)
        _ = f.handle(.timer(.compactHide), holds: holds)
        #expect(f.state == .compact)
        _ = f.handle(.timer(.compactHide))
        #expect(f.state == .hidden)
        // From hidden, a hover brings the card straight back.
        _ = f.handle(.pointerEntered, holds: holds)
        #expect(f.state == .expanded(.approval))
    }

    @Test func idleOnOtherViewReturnsToPendingCard() {
        var f = NotchFSM()
        let holds: Set<NotchFSM.Hold> = [NotchFSM.Hold("approval", .card(.approval))]
        _ = f.handle(.open(.chat), holds: holds)
        _ = f.handle(.timer(.expandedIdle), holds: holds)
        #expect(f.state == .expanded(.approval))
        #expect(f.pendingCard(holds) == .approval)
    }

    @Test func pendingCardPriority() {
        let f = NotchFSM()
        let holds: Set<NotchFSM.Hold> = [NotchFSM.Hold("q", .card(.question)), NotchFSM.Hold("a", .card(.approval)), NotchFSM.Hold("i", .card(.ingest))]
        #expect(f.pendingCard(holds) == .approval)
        #expect(f.pendingCard([NotchFSM.Hold("x", .view(.chat))]) == nil)
    }

    @Test func pinnedBlocksTimersUntilUnpinned() {
        var f = NotchFSM()
        let pin: Set<NotchFSM.Hold> = [NotchFSM.Hold("pin")]
        _ = f.handle(.open(.chat), holds: pin)
        _ = f.handle(.pointerLeft, holds: pin)
        _ = f.handle(.timer(.expandedIdle), holds: pin)
        #expect(f.state == .expanded(.chat))
        _ = f.handle(.timer(.expandedIdle))
        #expect(f.state == .compact)
    }
}

@Suite struct NotchGeometryTests {
    @Test func notchMeasuredFromAuxiliaryAreas() {
        let g = NotchGeometry(screenWidth: 1512, safeAreaTop: 32, auxiliaryLeftWidth: 656, auxiliaryRightWidth: 656, menuBarHeight: 37)
        #expect(g.hasNotch)
        #expect(g.width == 200)
        #expect(g.height == 32)
    }

    @Test func noNotchBar() {
        let g = NotchGeometry(screenWidth: 2560, safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 25)
        #expect(!g.hasNotch)
        #expect(g.width == 80)
        #expect(g.height == 24)
    }

    @Test func fallbackWhenAreasMissing() {
        let g = NotchGeometry(screenWidth: 1512, safeAreaTop: 32, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 37)
        #expect(g.width == NotchGeometry.fallbackNotchWidth)
    }

    @Test func displayChoiceRoundTrip() {
        for c in [DisplayChoice.notch, .menuBar, .followMouse, .display(uuid: "ABC")] {
            #expect(DisplayChoice(storageValue: c.storageValue) == c)
        }
        #expect(DisplayChoice(storageValue: "display:") == .notch)
        let cands = [DisplayCandidate(uuid: "a", hasNotch: false, containsMouse: false),
                     DisplayCandidate(uuid: "b", hasNotch: true, containsMouse: true)]
        #expect(DisplayResolver.index(for: .notch, in: cands) == 1)
        #expect(DisplayResolver.index(for: .menuBar, in: cands) == 0)
        #expect(DisplayResolver.index(for: .display(uuid: "zz"), in: cands) == 1)
        #expect(DisplayResolver.index(for: .followMouse, in: cands) == 1)
    }

    @Test func layoutSizes() {
        let l = NotchLayout(geometry: .fallback)
        #expect(l.size(mode: .hidden, view: .home).width == 184)
        #expect(l.size(mode: .compact, view: .home).width == 184 + 84 + 84)
        #expect(l.size(mode: .compact, view: .home, miniCount: 4).width > l.size(mode: .compact, view: .home).width)
        #expect(l.size(mode: .expanded, view: .chat).height == 260)
        #expect(l.size(mode: .expanded, view: .question, measuredHeight: 230).height == 230)
        #expect(l.size(mode: .expanded, view: .question, measuredHeight: 900).height == 360)
        #expect(l.size(mode: .expanded, view: .question, measuredHeight: 10).height == NotchLayout.viewHeight(.question))
        #expect(l.slimeRadius(mode: .compact) > 10 && l.slimeRadius(mode: .compact) < 16)
        #expect(l.miniSlotOffset(mode: .expanded) == 0)
    }

    @Test func compactWingFollowsMeasuredContent() {
        let l = NotchLayout(geometry: .fallback)
        let bare = l.size(mode: .compact, view: .home).width
        let withTicker = l.size(mode: .compact, view: .home, rightContent: 230).width
        #expect(withTicker == 184 + 84 + 12 + 230 + 10)
        #expect(withTicker > bare)
        #expect(l.size(mode: .compact, view: .home, rightContent: 30).width == bare)   // small content fits the minimum wing
    }

    @Test func centredIslandAlignsNotchSlotRegardlessOfWing() {
        let l = NotchLayout(geometry: .fallback)
        let container = 720.0
        let notchLeft = container / 2 - 92
        let narrow = l.size(mode: .compact, view: .home).width
        let wide = l.size(mode: .compact, view: .home, miniCount: 4, rightContent: 230).width
        for w in [narrow, wide] {
            let x = l.islandMinX(mode: .compact, width: w, mainAway: false, containerWidth: container)
            #expect(x + NotchLayout.compactWing == notchLeft)
        }
        #expect(l.islandMinX(mode: .hidden, width: 184, mainAway: false, containerWidth: container) == notchLeft)
        #expect(l.islandMinX(mode: .compact, width: narrow, mainAway: true, containerWidth: container) == notchLeft)
        #expect(l.islandMinX(mode: .expanded, width: 640, mainAway: false, containerWidth: container) == 40)
        let bar = NotchLayout(geometry: NotchGeometry(hasNotch: false, width: 80, height: 24))
        #expect(bar.islandMinX(mode: .compact, width: 248, mainAway: false, containerWidth: container) == (container - 248) / 2)
    }
}
