import Testing
import Foundation
@testable import SlimeCore

@Test func edgeDockingUsesScreenCoordinatesAndClamps() {
    let screen = CGRect(x: -1440, y: 100, width: 1440, height: 900)
    let size = CGSize(width: 680, height: 480)
    #expect(DockPlacement.nearest(to: .init(x: -1438, y: 550), in: screen).edge == .left)
    #expect(DockPlacement.nearest(to: .init(x: -2, y: 550), in: screen).edge == .right)
    #expect(DockPlacement.nearest(to: .init(x: -720, y: 998), in: screen).edge == .top)
    #expect(DockPlacement(edge: .top, fraction: 0).panelOrigin(in: screen, size: size).x == -1440)
    #expect(DockPlacement(edge: .right, fraction: 1).panelOrigin(in: screen, size: size) == CGPoint(x: -680, y: 520))
    #expect(DockPlacement(fraction: .nan).fraction == 0.5)
}

@Test func dockingDragCancellationRejectsLateUpdatesAndRelease() {
    var drag = DockDrag()
    let origin = CGPoint(x: -1000, y: 500)
    #expect(drag.update(origin: origin, pointer: .init(x: -900, y: 600), translation: .init(width: 20, height: 10)) == CGPoint(x: -980, y: 490))
    // Moving the host does not change the drag's original anchor.
    #expect(drag.update(origin: .init(x: -980, y: 490), pointer: .init(x: -850, y: 620), translation: .init(width: 70, height: -10)) == CGPoint(x: -930, y: 510))
    #expect(drag.cancel() && !drag.isActive)
    #expect(drag.update(origin: origin, pointer: .zero, translation: .zero) == nil)
    #expect(!drag.cancel() && !drag.finish())
    #expect(drag.update(origin: origin, pointer: .zero, translation: .zero) == origin)
    #expect(drag.finish() && !drag.finish())
    #expect(drag.update(origin: origin, pointer: .init(x: CGFloat.nan, y: 0), translation: .zero) == nil)
    #expect(!drag.isActive)
}
