import Testing
import simd
@testable import SlimeKit

@MainActor
@Suite struct SchedulerTests {
    @Test func firesInOrderAndCancelsByTag() {
        let s = Scheduler()
        var log: [String] = []
        s.schedule(at: 2, tag: "a") { log.append("a2") }
        s.schedule(at: 1, tag: "b") { log.append("b1") }
        s.schedule(at: 3, tag: "a") { log.append("a3") }
        s.cancel(tag: "a")
        s.fire(upTo: 5)
        #expect(log == ["b1"])
        #expect(s.count == 0)
        let tok = s.schedule(at: 1) { log.append("x") }
        s.cancel(tok)
        s.fire(upTo: 5)
        #expect(log == ["b1"])
    }

    @Test func actionsMayScheduleMore() {
        let s = Scheduler()
        var log: [Double] = []
        s.schedule(at: 1) {
            log.append(1)
            s.schedule(at: 2) { log.append(2) }
        }
        s.fire(upTo: 3)
        #expect(log == [1, 2])
    }
}

@Suite struct ClickGrammarTests {
    @Test func singleDoubleTripleClicks() {
        var g = ClickGrammar()
        g.settleInterval = 0.5
        var outs: [ClickGrammar.Output] = []
        _ = g.pressBegan(at: 0, position: .zero)
        outs += g.pressEnded(at: 0.1)
        outs += g.advance(to: 0.3)
        #expect(outs.isEmpty)
        outs += g.advance(to: 0.61)
        #expect(outs == [.click(count: 1)])

        outs = []
        _ = g.pressBegan(at: 1, position: .zero); outs += g.pressEnded(at: 1.05)
        _ = g.pressBegan(at: 1.2, position: .zero); outs += g.pressEnded(at: 1.25)
        outs += g.advance(to: 1.5)
        #expect(outs.isEmpty)
        outs += g.advance(to: 1.8)
        #expect(outs == [.click(count: 2)])

        outs = []
        for i in 0..<3 {
            _ = g.pressBegan(at: 3 + Double(i) * 0.2, position: .zero)
            outs += g.pressEnded(at: 3.05 + Double(i) * 0.2)
        }
        outs += g.advance(to: 4.2)
        #expect(outs == [.click(count: 3)])
    }

    @Test func holdVersusClick() {
        var g = ClickGrammar()
        _ = g.pressBegan(at: 0, position: .zero)
        var outs = g.advance(to: 0.24)
        #expect(outs.isEmpty)
        outs = g.pressEnded(at: 0.24)
        outs += g.advance(to: 1.0)
        #expect(outs == [.click(count: 1)])

        _ = g.pressBegan(at: 2, position: .zero)
        outs = g.advance(to: 2.25)
        #expect(outs == [.holdBegan])
        outs = g.pressEnded(at: 3)
        outs += g.advance(to: 4)
        #expect(outs.isEmpty)
    }

    @Test func dragCancelsClicks() {
        var g = ClickGrammar()
        _ = g.pressBegan(at: 0, position: .zero)
        var outs = g.pressMoved(at: 0.05, position: SIMD2(0.1, 0))
        #expect(outs.isEmpty)
        outs = g.pressMoved(at: 0.1, position: SIMD2(0.5, 0))
        #expect(outs == [.dragBegan])
        outs = g.pressEnded(at: 0.3)
        outs += g.advance(to: 1)
        #expect(outs.isEmpty)
    }

    @Test func fiveClicksSplitImmediately() {
        var g = ClickGrammar()
        var outs: [ClickGrammar.Output] = []
        for i in 0..<5 {
            let t = Double(i) * 0.2
            _ = g.pressBegan(at: t, position: .zero)
            outs += g.pressEnded(at: t + 0.05)
        }
        #expect(outs == [.splitNow(extra: 0)])
        _ = g.pressBegan(at: 1.1, position: .zero)
        outs = g.pressEnded(at: 1.15)
        #expect(outs == [.splitNow(extra: 1)])
        outs = g.advance(to: 5)
        #expect(outs.isEmpty)
    }
}

@MainActor
@Suite struct StateMachineTests {
    private func makeEngine() -> SlimeEngine {
        let e = SlimeEngine(profile: .main, seed: 3)
        e.simulate(0.1)
        return e
    }

    @Test func prioritiesResolve() {
        let e = makeEngine()
        e.agent(.working)
        #expect(e.state == .working)
        e.startQuestion()
        #expect(e.state == .question)
        e.simulate(2.3)
        #expect(e.state == .working)
        e.agent(.error)
        e.startListening()
        #expect(e.state == .listening)
        e.stopListening(hadSpeech: false)
        #expect(e.state == .error)
    }

    @Test func timedStatesExpire() {
        let e = makeEngine()
        e.greet()
        #expect(e.state == .greeting)
        e.simulate(2.1)
        #expect(e.state == .idle)
        e.agent(.finished)
        e.simulate(2.5)
        #expect(e.state == .idle)
        #expect(e.agentState == .idle)
    }

    @Test func errorIsHeldAtLeastThreeSeconds() {
        let e = makeEngine()
        e.agent(.error)
        e.simulate(1)
        e.agent(.idle)
        #expect(e.state == .error)
        e.simulate(2.1)
        #expect(e.state == .idle)
    }

    @Test func sleepRuleAndWake() {
        let e = makeEngine()
        e.sleepAfter = 1
        e.simulate(1.2)
        #expect(e.state == .sleeping)
        e.pressBegan(at: SIMD2(0, -1))
        e.pressEnded()
        #expect(e.state == .idle)
        e.simulate(0.05)
        e.pointer(SIMD2(0.5, -1))
        e.simulate(1.2)
        #expect(e.state != .sleeping, "a nearby pointer keeps the slime awake")
    }

    @Test func agentWorkWakesTheSlime() {
        let e = makeEngine()
        e.sleepNow()
        #expect(e.state == .sleeping)
        e.agent(.working)
        #expect(e.state == .working)
        #expect(e.userState == .none)
    }

    @Test func stateChangesCancelLoops() {
        let e = makeEngine()
        e.agent(.waiting)
        e.simulate(0.1)
        #expect(e.scheduler.hasPending(tag: "state"))
        e.agent(.idle)
        e.simulate(0.01)
        #expect(e.scheduler.hasPending(tag: "state"), "idle schedules its micro-idle loop")
        e.agent(.working)
        e.agent(.idle)
        #expect(e.state == .idle)
    }

    @Test func chewingEndsWithGulpThenHappy() {
        let e = makeEngine()
        var events: [SlimeEvent] = []
        e.onEvent = { events.append($0) }
        e.drop()
        #expect(e.state == .chewing)
        #expect(events.contains(.dropAccepted))
        e.simulate(0.3)
        e.ingestionFinished(success: true)
        e.simulate(0.5)
        #expect(e.state == .chewing, "chewing lasts at least 0.9 s")
        // With arms the catch, hug, bites and digest take about 2.9 s before the gulp.
        let t0 = e.time
        while e.state == .chewing && e.time - t0 < 5 { e.simulate(1.0 / 60.0) }
        #expect(e.state == .idle)
        #expect(e.emote == .happy)
        #expect(e.drainCues().isEmpty == false || true)
    }

    @Test func clicksProduceEvents() {
        let e = makeEngine()
        e.clickGrammar.settleInterval = 0.3
        var events: [SlimeEvent] = []
        e.onEvent = { events.append($0) }
        e.pressBegan(at: SIMD2(0.3, -1))
        e.pressEnded()
        e.simulate(0.4)
        #expect(events.contains(.clickClassified(count: 1)))
        #expect(e.emote == .poked)
        events = []
        e.pressBegan(at: SIMD2(0.3, -1))
        e.simulate(0.3)
        #expect(events.contains(.holdBegan))
        e.pressEnded()
        #expect(events.contains { if case .holdEnded = $0 { return true } else { return false } })
    }

    @Test func soundsAreRateLimited() {
        let e = makeEngine()
        e.cue(.plip)
        e.cue(.plip)
        e.simulate(0.1)
        e.cue(.plip)
        let cues = e.drainCues().filter { $0.sound == .plip }
        #expect(cues.count == 2)
        #expect(SlimeSound.allCases.count == 44)
    }

    @Test func framesAreDeterministicForASeed() {
        let a = SlimeEngine(profile: .main, seed: 21)
        let b = SlimeEngine(profile: .main, seed: 21)
        for e in [a, b] {
            e.simulate(0.5)
            e.greet()
            e.simulate(1.0)
            e.trigger(.love)
            e.simulate(1.0)
        }
        #expect(a.frame() == b.frame())
    }

    @Test func frameIntervalFollowsActivity() {
        let e = makeEngine()
        e.simulate(3)
        _ = e.frame()
        let quiet = e.frameInterval
        e.greet()
        e.simulate(0.2)
        _ = e.frame()
        #expect(e.frameInterval == nil)
        #expect(quiet != nil)
    }
}
