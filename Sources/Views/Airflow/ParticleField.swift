import CoreGraphics
import Foundation

/// The air as real particles: each one leaves the vent, is carried down by the flow
/// and keeps its own position and velocity. The pointer pushes particles away while it
/// rests in the stream and hands its own motion to them when it moves, so a quick swipe
/// throws them far. Drag then slows them back to the flow, and they keep drifting down
/// from wherever they were thrown, losing strength until they fade out.
@MainActor
final class ParticleField {
    struct Particle {
        var x: CGFloat, y: CGFloat
        var vx: CGFloat, vy: CGFloat
        /// Distance travelled, in points; strength fades with it.
        var travelled: CGFloat = 0
        /// Position across the vent, -1 (left) … 1 (right), for the fan's spread.
        let spread: CGFloat
        /// This particle's share of the flow speed, its reach and its look.
        let pace: CGFloat, reach: Double, length: CGFloat, width: CGFloat, tone: Double, seed: Double
    }

    private(set) var particles: [Particle] = []
    /// How much air the vent blows relative to the default fan speed (1).
    var volume = 1.0
    private var lastTime: Double?
    private var lastMouse: CGPoint?
    private var mouseVelocity = CGVector.zero
    private var emitDebt = 0.0
    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15

    // Tuning. Particles per second at full flow, and the pointer's reach and force.
    static let emissionRate = 40.0
    static let maxParticles = 280
    static let pointerRadius: CGFloat = 40
    /// Steady push away from a resting pointer (pt/s²), so air flows around it.
    static let pointerPush: CGFloat = 800
    /// Share of the pointer's own velocity handed to particles it sweeps through.
    static let pointerCarry: CGFloat = 0.85
    /// How quickly thrown particles slow back to the flow (1/s); lower glides longer.
    static let drag: CGFloat = 1.6

    private func random() -> Double {
        rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(rng >> 11) / Double(1 << 53)
    }

    /// Advances the simulation to `time` and returns the particles to draw.
    /// - Parameters:
    ///   - emitting: 0…1 share of full flow leaving the vent (0 once switched off).
    ///   - flowSpeed: downward speed of the air in pt/s.
    ///   - mouse: pointer in the illustration's coordinates, or nil.
    func step(time: Double, width: CGFloat, ventY: CGFloat, streamLength: CGFloat, bottom: CGFloat,
              emitting: Double, flowSpeed: CGFloat, sway: Double, lean: Double, mouse: CGPoint?) -> [Particle] {
        // Opening the panel with the unit on shows a stream that is already flowing.
        if lastTime == nil, emitting > 0.99 {
            var warm = time - 6
            lastTime = warm
            while warm < time {
                warm += 1.0 / 30.0
                advance(dt: 1.0 / 30.0, time: warm, width: width, ventY: ventY, streamLength: streamLength,
                        bottom: bottom, emitting: emitting, flowSpeed: flowSpeed, sway: sway, lean: lean, mouse: nil)
            }
            lastTime = time
            return particles
        }
        let gap = lastTime.map { time - $0 } ?? 0
        lastTime = time
        // After a long pause (panel closed, animation stopped) start fresh.
        if gap > 1 { particles.removeAll(); lastMouse = nil; return particles }
        let dt = CGFloat(min(0.05, max(0, gap)))
        guard dt > 0 else { return particles }
        // The pointer's velocity, lightly smoothed, is what throws particles.
        if let mouse, let lastMouse {
            let measured = CGVector(dx: (mouse.x - lastMouse.x) / dt, dy: (mouse.y - lastMouse.y) / dt)
            mouseVelocity = CGVector(dx: mouseVelocity.dx * 0.4 + measured.dx * 0.6,
                                     dy: mouseVelocity.dy * 0.4 + measured.dy * 0.6)
            let speed = hypot(mouseVelocity.dx, mouseVelocity.dy)
            if speed > 1600 { mouseVelocity.dx *= 1600 / speed; mouseVelocity.dy *= 1600 / speed }
        } else {
            mouseVelocity = .zero
        }
        lastMouse = mouse
        advance(dt: Double(dt), time: time, width: width, ventY: ventY, streamLength: streamLength,
                bottom: bottom, emitting: emitting, flowSpeed: flowSpeed, sway: sway, lean: lean, mouse: mouse)
        return particles
    }

    private func advance(dt: Double, time: Double, width: CGFloat, ventY: CGFloat, streamLength: CGFloat,
                         bottom: CGFloat, emitting: Double, flowSpeed: CGFloat, sway: Double, lean: Double,
                         mouse: CGPoint?) {
        let step = CGFloat(dt)
        let center = width / 2
        // Emit new air from the vent, sparser and slower while the fan spins up.
        emitDebt += Self.emissionRate * emitting * volume * dt
        while emitDebt >= 1 {
            emitDebt -= 1
            guard particles.count < Self.maxParticles else { continue }
            let spread = CGFloat(random() * 2 - 1)
            let pace = CGFloat(0.8 + 0.45 * random())
            particles.append(Particle(
                x: center - 3 + spread * 76, y: ventY + CGFloat(random()) * 3,
                vx: 0, vy: flowSpeed * pace * CGFloat(0.4 + 0.6 * emitting),
                spread: spread, pace: pace,
                reach: 0.45 + 0.55 * random(),
                length: CGFloat(5 + 8 * random()),
                width: CGFloat(0.6 + 0.8 * random()),
                tone: 0.34 + 0.26 * random(),
                seed: random() * 10))
        }
        let settle = 1 - exp(-Self.drag * step)
        let radius = Self.pointerRadius
        var index = 0
        while index < particles.count {
            var p = particles[index]
            // The flow this particle would follow undisturbed: down the vent's fan,
            // swayed by the louver, leaning toward the pointer, with its own flutter.
            // Air, not rain: it meanders in slow, wide curves, and as it loses strength it
            // slows down and spreads out sideways instead of falling at a constant speed.
            let force = CGFloat(Self.strength(of: p, streamLength: streamLength))
            let flutter = CGFloat(sin(time * 1.3 + p.seed * 6 + Double(p.y) * 0.035)) * 9
                + CGFloat(sin(time * 2.9 + p.seed * 2.3)) * 3
            let flowX = p.spread * (3.5 + 9 * (1 - force)) - 2.8 + CGFloat(sway) * 8 + CGFloat(lean) * 5 + flutter
            let flowY = flowSpeed * p.pace * (0.5 + 0.5 * force)
            p.vx += (flowX - p.vx) * settle
            p.vy += (flowY - p.vy) * settle
            // The pointer: a resting one pushes air aside; a moving one carries the air
            // it sweeps through along with it. Both fade smoothly toward its edge.
            if let mouse {
                let dx = p.x - mouse.x, dy = p.y - mouse.y
                let distance = hypot(dx, dy)
                if distance < radius {
                    let falloff = pow(1 - distance / radius, 2)
                    let nx = dx / max(distance, 1), ny = dy / max(distance, 1)
                    p.vx += nx * Self.pointerPush * falloff * step
                    p.vy += ny * Self.pointerPush * falloff * step * 0.7
                    // Only the pointer's motion is handed over, so a resting pointer
                    // never brakes the air; a swipe flings it in the swipe's direction.
                    let grip = min(1, step * 10) * Self.pointerCarry * falloff
                    p.vx += mouseVelocity.dx * grip
                    p.vy += mouseVelocity.dy * grip
                }
            }
            p.x += p.vx * step
            p.y += p.vy * step
            // Strength fades with time in the air (measured as calm-flow distance), not
            // with distance flown, so a particle thrown far stays visible in flight.
            p.travelled += flowY * step
            let alive = Self.strength(of: p, streamLength: streamLength) > 0.01
                && p.y < bottom && p.y > ventY - 40 && p.x > -30 && p.x < width + 30
            if alive { particles[index] = p; index += 1 } else { particles.swapAt(index, particles.count - 1); particles.removeLast() }
        }
    }

    /// How much strength a particle has left: full near the vent, fading as it travels
    /// toward the end of its own reach, so the stream frays out unevenly.
    static func strength(of p: Particle, streamLength: CGFloat) -> Double {
        let t = Double(p.travelled / streamLength)
        let start = p.reach * 0.45
        let u = min(1, max(0, (t - start) / max(0.01, p.reach - start)))
        return 1 - u * u * (3 - 2 * u)
    }
}
