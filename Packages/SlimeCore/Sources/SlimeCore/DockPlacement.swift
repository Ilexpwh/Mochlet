import Foundation

public enum DockEdge: String, CaseIterable, Codable, Sendable { case top, left, right }

public struct DockPlacement: Codable, Equatable, Sendable {
    public var edge: DockEdge
    public var fraction: Double
    public init(edge: DockEdge = .top, fraction: Double = 0.5) {
        self.edge = edge
        self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0.5
    }
    public static func nearest(to point: CGPoint, in screen: CGRect) -> Self {
        let distances: [(DockEdge, CGFloat)] = [(.top, abs(screen.maxY - point.y)), (.left, abs(screen.minX - point.x)), (.right, abs(screen.maxX - point.x))]
        let edge = distances.min { $0.1 < $1.1 }!.0
        let fraction = edge == .top ? (point.x - screen.minX) / max(screen.width, 1) : (point.y - screen.minY) / max(screen.height, 1)
        return Self(edge: edge, fraction: fraction)
    }
    public func panelOrigin(in screen: CGRect, size: CGSize) -> CGPoint {
        func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat { max(lower, min(max(lower, upper), value)) }
        switch edge {
        case .top:
            return .init(x: clamp(screen.minX + screen.width * fraction - size.width / 2, screen.minX, screen.maxX - size.width), y: screen.maxY - size.height)
        case .left, .right:
            return .init(x: edge == .left ? screen.minX : screen.maxX - size.width,
                         y: clamp(screen.minY + screen.height * fraction - size.height / 2, screen.minY, screen.maxY - size.height))
        }
    }
}
