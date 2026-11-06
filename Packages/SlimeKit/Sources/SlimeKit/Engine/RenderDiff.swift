import Foundation
import simd

/// "Has the picture visibly changed?" for a frame drawn at a given scale. Positions compare with a
/// pixel tolerance and unit values with a small epsilon, against the frame that was last drawn, so
/// slow breathing redraws a couple of times a second while any discrete change redraws at once.
public extension SlimeFrame {
    func visuallyDiffers(from o: SlimeFrame, pixelsPerUnit ppu: Double, pixelTolerance: Double = 0.3) -> Bool {
        let tol = pixelTolerance / max(ppu, 1e-6)
        let tol2 = tol * tol
        @inline(__always) func moved(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool { simd_distance_squared(a, b) > tol2 }
        @inline(__always) func diff(_ a: Double, _ b: Double, _ e: Double) -> Bool { abs(a - b) > e }
        if profile != o.profile || state != o.state || emote != o.emote || airborne != o.airborne { return true }
        if ring.count != o.ring.count || eyes.count != o.eyes.count || accessories.count != o.accessories.count
            || particles.count != o.particles.count || blobs.count != o.blobs.count || blushCenters.count != o.blushCenters.count { return true }
        for i in ring.indices where moved(ring[i], o.ring[i]) { return true }
        if moved(root, o.root) { return true }
        if diff(contactWidth, o.contactWidth, tol) { return true }
        // Body scale/rotation move a point at 1R by about that much in R, so they share the pixel tolerance.
        if diff(body.rotation, o.body.rotation, tol) || diff(body.scaleX, o.body.scaleX, tol) || diff(body.scaleY, o.body.scaleY, tol) { return true }
        for i in eyes.indices {
            let a = eyes[i], b = o.eyes[i]
            if a.shape != b.shape || a.visible != b.visible { return true }
            if moved(a.center, b.center) { return true }
            if diff(a.radius * a.scale, b.radius * b.scale, tol) || diff(a.openness, b.openness, 0.02) { return true }
            if diff(a.foreshorten.x, b.foreshorten.x, 0.01) || diff(a.foreshorten.y, b.foreshorten.y, 0.01) { return true }
        }
        if mouth.shape != o.mouth.shape || mouth.visible != o.mouth.visible || moved(mouth.center, o.mouth.center)
            || diff(mouth.open, o.mouth.open, 0.02) || diff(mouth.foreshorten.x, o.mouth.foreshorten.x, 0.01) || diff(mouth.foreshorten.y, o.mouth.foreshorten.y, 0.01) { return true }
        if diff(blush, o.blush, 0.02) { return true }
        if blush > 0.01 { for i in blushCenters.indices where moved(blushCenters[i], o.blushCenters[i]) { return true } }
        if moved(core, o.core) || diff(coreBoost, o.coreBoost, 0.02) { return true }
        if moved(highlightShift, o.highlightShift) { return true }
        if diff(tint.opacity, o.tint.opacity, 0.015) || diff(tint.desaturation, o.tint.desaturation, 0.015) || tint.color != o.tint.color { return true }
        for i in accessories.indices {
            let a = accessories[i], b = o.accessories[i]
            if a.kind != b.kind || moved(a.anchor, b.anchor) || diff(a.pop, b.pop, 0.015) { return true }
            switch a.kind {
            case .dots, .badge, .recDot: if diff(a.phase, b.phase, 0.04) { return true }
            case .micBars: for k in a.levels.indices where k < b.levels.count && diff(a.levels[k], b.levels[k], 0.03) { return true }
            case .question, .exclamation: break
            }
        }
        for i in particles.indices {
            let a = particles[i], b = o.particles[i]
            if a.kind != b.kind || moved(a.position, b.position) || diff(a.progress, b.progress, 0.02) || diff(a.spin * a.age, b.spin * b.age, 0.03) { return true }
        }
        for i in blobs.indices {
            let a = blobs[i], b = o.blobs[i]
            if moved(a.position, b.position) || diff(a.radius, b.radius, tol) || diff(a.stretch, b.stretch, 0.02) || diff(a.heading, b.heading, 0.02) { return true }
        }
        if traits.count != o.traits.count { return true }
        for i in traits.indices {
            let a = traits[i], b = o.traits[i]
            if a.kind != b.kind || moved(a.anchor, b.anchor) || diff(a.phase, b.phase, 0.02) || diff(a.scale, b.scale, 0.01)
                || diff(a.direction.x, b.direction.x, 0.01) || diff(a.direction.y, b.direction.y, 0.01) { return true }
        }
        if arms.count != o.arms.count || props.count != o.props.count || innerItems.count != o.innerItems.count || chewPhase != o.chewPhase { return true }
        for i in arms.indices {
            let a = arms[i], b = o.arms[i]
            if a.shape != b.shape || moved(a.shoulder, b.shoulder) || moved(a.elbow, b.elbow) || moved(a.hand, b.hand) || diff(a.reach, b.reach, 0.01) { return true }
        }
        for i in props.indices {
            let a = props[i], b = o.props[i]
            if a.prop != b.prop || moved(a.position, b.position) || diff(a.angle, b.angle, 0.01) || diff(a.scale, b.scale, 0.01) { return true }
        }
        for i in innerItems.indices {
            let a = innerItems[i], b = o.innerItems[i]
            if moved(a.position, b.position) || diff(a.angle, b.angle, 0.02) || diff(a.opacity, b.opacity, 0.02) { return true }
        }
        if diff(opacity, o.opacity, 0.01) || diff(faceOpacity, o.faceOpacity, 0.01) || diff(glowBoost, o.glowBoost, 0.02) || diff(sizeScale, o.sizeScale, tol) { return true }
        if profile == .ghost, moved(ghostStretch, o.ghostStretch) || diff(ghostHeading, o.ghostHeading, 0.01) { return true }
        return false
    }
}

public extension PlacedSlime {
    func visuallyDiffers(from o: PlacedSlime, pixelsPerUnit ppu: Double, pixelTolerance: Double = 0.3) -> Bool {
        if id != o.id || abs(scale - o.scale) > 0.004 || appearance != o.appearance || frame.outfit != o.frame.outfit { return true }
        if simd_distance(offset, o.offset) * ppu > pixelTolerance { return true }
        return frame.visuallyDiffers(from: o.frame, pixelsPerUnit: ppu * scale, pixelTolerance: pixelTolerance)
    }

    /// True when any placed slime in `a` differs visibly from its counterpart in `b`.
    static func visuallyDiffer(_ a: [PlacedSlime], _ b: [PlacedSlime], pixelsPerUnit ppu: Double, pixelTolerance: Double = 0.3) -> Bool {
        if a.count != b.count { return true }
        for i in a.indices where a[i].visuallyDiffers(from: b[i], pixelsPerUnit: ppu, pixelTolerance: pixelTolerance) { return true }
        return false
    }
}
