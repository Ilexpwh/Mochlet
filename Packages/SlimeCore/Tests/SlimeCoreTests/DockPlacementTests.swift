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
