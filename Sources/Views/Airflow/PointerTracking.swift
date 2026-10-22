import SwiftUI
import AppKit

/// The pointer as the airflow sees it: a smoothed position, how strongly it is
/// present in the stream, and where it has been over the last second.
struct Cursor {
    let point: CGPoint
    /// 0 when the pointer is away, easing to 1 while it hovers the airflow.
    let strength: Double
    /// -1 (left) to 1 (right), already scaled by strength.
    let lean: Double
    /// 1 while the pointer is inside the stream, easing to 0 just outside it.
    var presence: CGFloat = 0
    /// Where the obstacle was over the last second, newest last. Air further below
    /// reacts to where the pointer *was*, because the disturbance travels down with
    /// the air instead of the whole fan snapping to the pointer at once.
    var trail: [TrailSample] = []
    var now: Double = 0

    struct TrailSample {
        let time: Double
        let point: CGPoint
        let block: CGFloat
    }

    /// The obstacle as it was `lag` seconds ago, interpolated between samples.
    func sample(lag: Double) -> (point: CGPoint, block: CGFloat) {
        guard let newest = trail.last else { return (point, CGFloat(strength) * presence) }
        let target = now - lag
        guard target < newest.time else { return (newest.point, newest.block) }
        for index in stride(from: trail.count - 1, to: 0, by: -1) {
            let a = trail[index - 1], b = trail[index]
            guard a.time <= target else { continue }
            let f = CGFloat((target - a.time) / max(0.0001, b.time - a.time))
            return (CGPoint(x: a.point.x + (b.point.x - a.point.x) * f,
                            y: a.point.y + (b.point.y - a.point.y) * f),
                    a.block + (b.block - a.block) * f)
        }
        return (trail[0].point, trail[0].block)
    }
}

/// Converts the global pointer position into the illustration's own coordinates
/// (top-left origin), through an invisible AppKit view placed behind it. Reading the
/// screen position every frame lets the air react even when the pointer is outside
/// the illustration.
@MainActor
final class PointerProbe {
    weak var view: NSView?
    func location() -> CGPoint? {
        guard let view, let window = view.window, window.isVisible else { return nil }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return view.convert(inWindow, from: nil)
    }
}

/// The invisible, click-through view that gives `PointerProbe` its coordinates.
struct PointerAnchor: NSViewRepresentable {
    let probe: PointerProbe
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        probe.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { probe.view = nsView }
}

/// Eases the drawn pointer toward the real one each frame so the air reacts with a
/// little inertia, and keeps the trail of recent positions. It is not observed, so
/// updating it never triggers extra renders.
@MainActor
final class PointerFollow {
    private(set) var point = CGPoint.zero
    private(set) var strength = 0.0
    /// How far the whole stream bends toward the pointer (-1…1). Eased much more
    /// slowly than the pointer itself, so the air sways like a breeze.
    private(set) var lean = 0.0
    private var lastTime: Double?
    private var elapsed = 0.0
    private var trail: [Cursor.TrailSample] = []

    func update(target: CGPoint?, width: CGFloat, time: Double) {
        elapsed = lastTime.map { min(0.1, max(0, time - $0)) } ?? 0
        lastTime = time
        if let target {
            if strength < 0.01 {
                point = target
            } else {
                // Soft follow (~0.2 s) for the obstacle the pointer makes in the air.
                let blend = CGFloat(1 - exp(-elapsed * 5))
                point.x += (target.x - point.x) * blend
                point.y += (target.y - point.y) * blend
            }
        }
        strength += ((target == nil ? 0 : 1) - strength) * (1 - exp(-elapsed * 3))
        let half = max(1, width / 2)
        let leanTarget = strength * min(1, max(-1, Double((point.x - half) / half)))
        lean += (leanTarget - lean) * (1 - exp(-elapsed * 1.8))
    }

    /// Records this frame's obstacle and hands back the cursor with its recent trail.
    func attach(_ cursor: Cursor, time: Double) -> Cursor {
        trail.append(.init(time: time, point: cursor.point,
                           block: CGFloat(cursor.strength) * cursor.presence))
        trail.removeAll { $0.time < time - 1.2 }
        var result = cursor
        result.trail = trail
        result.now = time
        return result
    }
}

/// Tracks the unit being switched on or off, so the air can pour out of the vent
/// and drain away naturally instead of appearing or vanishing at once.
@MainActor
final class PowerTransition {
    private var powered: Bool?
    private var poweredAt = -Double.infinity

    /// Time until the last air leaves the stream after power-off. The trailing edge
    /// moves at the slowest particle's speed, so no gust is ever cut off midway.
    static func drainDuration(speed: Double) -> Double { 1 / (speed * 0.8) + 0.2 }

    /// Records the power state when the panel appears, so the first change after that
    /// is animated even if the animation was idle (unit off) until then.
    func prime(isOn: Bool) {
        if powered == nil { powered = isOn }
    }

    /// The stretch of each streamline that holds air, as fractions from the vent (0)
    /// to the end of the stream (1), plus how dense the air is (0…1).
    /// Turning on: the air waits for the louver to open, then the fan spins up, so the
    /// first gusts leave slowly, accelerate to full speed and thicken into the normal
    /// flow. Turning off: the vent stops and the trailing edge drifts down with the air.
    /// Opening the panel shows the settled state.
    func flow(isOn: Bool, time: Double, speed: Double) -> (head: Double, tail: Double, density: Double) {
        if powered == nil { powered = isOn }
        if powered != isOn { powered = isOn; poweredAt = time }
        let elapsed = max(0, time - poweredAt)
        guard isOn else { return (head: 1, tail: min(1, elapsed * speed * 0.8), density: 1) }
        let blowing = elapsed - 0.35          // the louver opens first
        guard blowing > 0 else { return (head: 0, tail: 0, density: 0) }
        // Constant acceleration until full speed after `spinUp` seconds.
        let spinUp = 0.9, full = speed * 1.25
        let travelled = blowing < spinUp ? full * blowing * blowing / (2 * spinUp)
                                         : full * (blowing - spinUp / 2)
        let u = min(1, blowing / 1.6)
        return (head: min(1, travelled), tail: 0, density: u * u * (3 - 2 * u))
    }
}
