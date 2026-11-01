import Testing
@testable import SlimeCore

@Test func notchPeekClickAndDismissal() {
    var island = IslandInteraction()
    island.timeout(held: false, autoHide: true)
    #expect(island.mode == .hidden)
    island.enter(openOnHover: false)
    #expect(island.mode == .compact)
    island.open()
    island.leave()
    #expect(island.dismissalDelay(held: false, autoHide: true) == 15)
    island.timeout(held: true, autoHide: true)
    #expect(island.mode == .expanded)
    island.timeout(held: false, autoHide: true)
    #expect(island.mode == .compact)
    island.timeout(held: false, autoHide: false)
    #expect(island.mode == .compact)
}

@Test func hoverOpenBecomesPersistentAfterInteraction() {
    var island = IslandInteraction()
    island.enter(openOnHover: true)
    island.leave()
    #expect(island.dismissalDelay(held: false, autoHide: true) == 0.6)
    island.interact()
    #expect(island.dismissalDelay(held: false, autoHide: true) == 15)
    island.pinned = true
    island.timeout(held: false, autoHide: true)
    #expect(island.mode == .expanded)
    island.collapse()
    #expect(!island.pinned)
    island.enter(openOnHover: false)
    island.timeout(held: false, autoHide: true)
    #expect(island.mode == .compact)
}
