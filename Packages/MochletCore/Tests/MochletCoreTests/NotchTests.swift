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
        #expect(l.slimeRadius(mode: .compact) > 10 && l.slimeRadius(mode: .compact) < 16)
        #expect(l.miniSlotOffset(mode: .expanded) == 0)
    }
}
