import SwiftUI

/// The unit and its airflow. Everything here is drawn locally: it never polls
/// ThinQ or sends network commands.
///
/// The air is made of two layers: a heavily blurred haze that gives the stream its
/// body, and a `ParticleField` whose particles the pointer can push and throw.
struct AirIllustration: View {
    let isOn: Bool
    let mode: String
    let fan: String
    let oscillating: Bool
    let eco: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    /// True while any air is drawn, which outlasts `isOn` during the power-off fade.
    @State private var flowing = false
    @State private var follow = PointerFollow()
    @State private var transition = PowerTransition()
    @State private var probe = PointerProbe()
    @State private var field = ParticleField()

    /// Where the air leaves the vent, and how far it can travel. The stream reaches
    /// past the illustration's bottom edge, losing strength until it fades out over
    /// the content below, so there is never a visible line where it stops.
    private static let ventY: CGFloat = 65
    private static let streamLength: CGFloat = 135
    /// Extra room below the illustration that the air may drift into.
    private static let overflow: CGFloat = 70
    /// Keeps the air travelling at the same on-screen speed as the original, shorter
    /// stream (73 pt), now that it covers a longer distance.
    private static let lengthScale = 73 / Double(streamLength)
    /// Half-width of the opening the pointer cuts through the haze.
    private static let gap: CGFloat = 26

    private var flowColor: Color {
        eco ? Color.mint : mode == "HEAT" ? Color.orange : mode == "FAN" ? Color.white : Color.cyan
    }
    /// How the chosen fan speed looks: how fast the air travels and how much of it the
    /// vent blows, both relative to speed 2, which is the reference look.
    ///
    /// Faster air crosses the stream sooner, so `volume` also makes up for that: the
    /// amount of air *on screen* goes ~0.85×, 1×, 1.1×, 1.2×, 1.3× from speed 1 to 5.
    private var fanProfile: (pace: Double, volume: Double) {
        switch fan {
        case "LOW", "SLOW": return (0.70, 0.60)                 // 1
        case "LOW_MID", "AUTO": return (1.00, 1.00)             // 2, the reference
        case "MID": return (1.25, 1.40)                         // 3
        case "MID_HIGH": return (1.50, 1.83)                    // 4
        case "HIGH", "POWER", "TURBO": return (1.80, 2.38)      // 5
        default: return (1.00, 1.00)                            // Natural and unknown codes
        }
    }
    /// Natural wind keeps changing: it drifts slowly between speeds 1 and 3, like gusts.
    private var isNatural: Bool { fan == "NATURE" }
    private func gust(at time: Double) -> Double {
        guard isNatural else { return 0 }
        // Two slow waves, so the rhythm never repeats exactly. Range −1…1.
        return 0.65 * sin(time * 0.55) + 0.35 * sin(time * 1.37 + 1.2)
    }
    /// Fraction of the stream travelled per second at the reference speed 2.
    private static let referenceSpeed = 0.43 * lengthScale
    /// Average speed, used for timings like how long the air takes to drain away.
    private var speed: Double { Self.referenceSpeed * fanProfile.pace }
    /// Speed at this moment: steady for fixed speeds, gusting for Natural.
    private func speed(at time: Double) -> Double {
        speed * (1 + 0.3 * gust(at: time))
    }
    private func volume(at time: Double) -> Double {
        fanProfile.volume * (1 + 0.25 * gust(at: time))
    }

    var body: some View {
        GeometryReader { geometry in
        // The pointer is read from the screen every frame, so the air keeps following
        // it anywhere, not only while it hovers the illustration. Animation only runs
        // while the panel is open and air is flowing (including the on/off transition).
        TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                paused: !flowing || !visible || reduceMotion)) { timeline in
            let time = reduceMotion ? 0.0 : timeline.date.timeIntervalSinceReferenceDate
            let sway = oscillating ? sin(time * 1.1) : 0.0
            let _ = follow.update(target: isOn && !reduceMotion ? probe.location() : nil,
                                  width: geometry.size.width, time: time)
            let cursor = follow.attach(
                placed(Cursor(point: follow.point, strength: follow.strength, lean: follow.lean),
                       width: geometry.size.width, time: time, sway: sway),
                time: time)
            // The visible stretch of the haze: when turning on, air pours out of the
            // vent (head grows); when turning off, the vent stops and the last air drifts
            // down and fades (tail leaves). Reduce Motion skips straight to the end state.
            let flow = reduceMotion ? (head: isOn ? 1.0 : 0.0, tail: 0.0, density: 1.0)
                                    : transition.flow(isOn: isOn, time: time, speed: speed(at: time))
            let intensity = min(flow.head, 1 - flow.tail) * flow.density
            let flowSpeed = CGFloat(speed(at: time)) * Self.streamLength
            // Faster fan speeds also blow more air out of the vent.
            let _ = (field.volume = volume(at: time))
            // The air particles. While on, the vent emits (sparser during spin-up); once off
            // it stops and the particles already out drift on and fade by themselves.
            let particles = field.step(
                time: time, width: geometry.size.width, ventY: Self.ventY, streamLength: Self.streamLength,
                bottom: geometry.size.height + Self.overflow,
                emitting: isOn && flow.head > 0 ? flow.density : 0,
                flowSpeed: flowSpeed, sway: sway, lean: follow.lean,
                mouse: isOn && !reduceMotion ? probe.location() : nil)
            ZStack {
                if flowing {
                    Ellipse().fill(flowColor.opacity(0.12 * intensity))
                        .frame(width: 170, height: 34).blur(radius: 21)
                        .offset(x: CGFloat(sway * 8 + cursor.lean * 14), y: 34)
                    Canvas { context, size in
                        guard flow.head > flow.tail else { return }
                        let first = size.width / 2 - 76
                        // A soft haze of air under the particles, heavily blurred so it
                        // reads as moving air, never as individual lines.
                        context.drawLayer { haze in
                            haze.addFilter(.blur(radius: 5))
                            for lane in stride(from: 1, to: 22, by: 3) {
                                let origin = first + CGFloat(lane) * 7.1
                                var path = Path()
                                for sample in 0...24 {
                                    let t = flow.tail + (flow.head - flow.tail) * Double(sample) / 24
                                    let point = hazePoint(origin, lane: lane, t: t, time: time, sway: sway, cursor: cursor)
                                    if sample == 0 { path.move(to: point) } else { path.addLine(to: point) }
                                }
                                haze.stroke(path, with: softEdges(flowColor, 0.15 * flow.density, tail: flow.tail, head: flow.head),
                                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            }
                        }
                        // Particles, each drawn as a short streak along its motion: a calm
                        // one is a small wisp, a thrown one stretches into a motion blur.
                        for p in particles {
                            let force = ParticleField.strength(of: p, streamLength: Self.streamLength)
                            let velocity = hypot(p.vx, p.vy)
                            guard force > 0.01, velocity > 0.1 else { continue }
                            // Weaker air is also shorter, so the stream frays out; faster air
                            // smears further, capped so a swipe never draws long lines.
                            let blur = min(2.4, max(0.75, sqrt(velocity / max(1, flowSpeed))))
                            let length = p.length * CGFloat(0.45 + 0.55 * force) * blur
                            let head = CGPoint(x: p.x, y: p.y)
                            let tail = CGPoint(x: p.x - p.vx / velocity * length, y: p.y - p.vy / velocity * length)
                            // Fades in as it leaves the vent and out as it loses force.
                            let leaving = Double(min(1, p.travelled / 6))
                            let alpha = leaving * force * p.tone * (0.35 + 0.65 * flow.density)
                            // A soft, slightly curved wisp that fades in and out at both
                            // ends. A bright leading end would read as a falling drop.
                            let bend = CGFloat(sin(p.seed * 3 + time * 1.7)) * length * 0.2
                            let control = CGPoint(x: (head.x + tail.x) / 2 - p.vy / velocity * bend,
                                                  y: (head.y + tail.y) / 2 + p.vx / velocity * bend)
                            var streak = Path()
                            streak.move(to: tail)
                            streak.addQuadCurve(to: head, control: control)
                            context.stroke(streak, with: .linearGradient(Gradient(stops: [
                                .init(color: flowColor.opacity(0), location: 0),
                                .init(color: flowColor.opacity(alpha), location: 0.55),
                                .init(color: flowColor.opacity(alpha * 0.25), location: 1)
                            ]), startPoint: tail, endPoint: head),
                                style: StrokeStyle(lineWidth: p.width, lineCap: .round))
                        }
                    }
                    // Taller than the illustration so the air can drift past its edge
                    // and fade out over the content below, with no hard line.
                    .frame(width: geometry.size.width, height: geometry.size.height + Self.overflow)
                    .blur(radius: 1.0)
                    .offset(y: Self.overflow / 2)
                    .allowsHitTesting(false)
                }
                unit(sway: sway)
                    .frame(width: 180, height: 55)
                    // The unit stays fixed; only the airflow follows the pointer.
                    .rotation3DEffect(.degrees(-12), axis: (x: 0, y: 1, z: 0))
                    .rotationEffect(.degrees(4))
                    .shadow(color: .black.opacity(0.6), radius: 12, x: 0, y: 12)
                    .offset(y: -24)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        }
        .background(PointerAnchor(probe: probe))
        .onAppear { visible = true; flowing = isOn; transition.prime(isOn: isOn) }
        .onDisappear { visible = false }
        // Keep rendering after power-off until the last air has drifted away.
        .task(id: isOn) {
            if isOn { flowing = true; return }
            guard !reduceMotion else { flowing = false; return }
            try? await Task.sleep(nanoseconds: UInt64(PowerTransition.drainDuration(speed: speed) * 1_000_000_000))
            if !Task.isCancelled && !isOn { flowing = false }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: isOn)
    }

    // MARK: Haze geometry

    /// Vertical gradient that fades the haze in at the leading edge of the air and out
    /// at its trailing edge, so neither end of the stream is ever a hard cut.
    private func softEdges(_ color: Color, _ alpha: Double, tail: Double, head: Double) -> GraphicsContext.Shading {
        let y = { (t: Double) in Self.ventY + CGFloat(t) * Self.streamLength }
        // Dense near the vent, thinning out well before the end of its reach.
        return .linearGradient(Gradient(stops: [
            .init(color: color.opacity(0), location: 0),
            .init(color: color.opacity(alpha), location: 0.07),
            .init(color: color.opacity(alpha * 0.55), location: 0.3),
            .init(color: color.opacity(alpha * 0.15), location: 0.5),
            .init(color: color.opacity(0), location: 0.68)
        ]), startPoint: CGPoint(x: 0, y: y(tail)), endPoint: CGPoint(x: 0, y: y(max(head, tail + 0.01))))
    }

    /// The undisturbed streamline, before the pointer pushes it aside.
    private func basePoint(_ origin: CGFloat, lane: Int, t: Double, time: Double, sway: Double,
                           cursor: Cursor) -> CGPoint {
        // Spreads a little wider as it travels and weakens.
        let spread = (Double(lane) - 10.5) * t * 1.3
        let drift = sin(t * 4.5 + time * 1.5 + Double(lane) * 0.17) * t * 3.5
        // The whole stream bends gently toward the side the pointer is on.
        return CGPoint(x: origin + CGFloat(spread + drift + sway * t * 13 - t * 12 + cursor.lean * t * 16),
                       y: Self.ventY + CGFloat(t) * Self.streamLength)
    }

    /// The pointer only affects air while it is inside the stream itself: between the
    /// outermost streamlines at its height, from the vent to the end of the flow.
    /// The effect fades out over 14 pt as it leaves, so the stream never reacts to
    /// a pointer that is beside it.
    private func placed(_ cursor: Cursor, width: CGFloat, time: Double, sway: Double) -> Cursor {
        var result = cursor
        let crossing = min(1, max(0, Double((cursor.point.y - Self.ventY) / Self.streamLength)))
        let first = width / 2 - 76
        let left = basePoint(first, lane: 0, t: crossing, time: time, sway: sway, cursor: cursor).x
        let right = basePoint(first + 21 * 7.1, lane: 21, t: crossing, time: time, sway: sway, cursor: cursor).x
        // Down to where the air still has visible strength.
        let lowest = Self.ventY + Self.streamLength * 0.6
        let outside = max(0, left - cursor.point.x, cursor.point.x - right,
                          Self.ventY - 7 - cursor.point.y, cursor.point.y - lowest)
        let u = max(0, 1 - outside / 14)
        result.presence = u * u * (3 - 2 * u)
        return result
    }

    /// A point of the haze, gently parted by the pointer. The particles carry the real
    /// reaction; the haze only hints at it so the stream keeps its body.
    ///
    /// The split is a wedge: above the pointer the air flows straight, at the pointer it
    /// parts in two, and below it both halves keep fanning out. Air further below reacts
    /// to where the pointer was a moment ago, as the disturbance travels down (~90 pt/s).
    private func hazePoint(_ origin: CGFloat, lane: Int, t: Double, time: Double, sway: Double,
                           cursor: Cursor) -> CGPoint {
        var point = basePoint(origin, lane: lane, t: t, time: time, sway: sway, cursor: cursor)
        guard cursor.strength > 0.01 || cursor.trail.contains(where: { $0.block > 0.01 }) else { return point }
        let distanceBelow = max(0, point.y - cursor.point.y)
        let obstacle = cursor.sample(lag: min(1.0, Double(distanceBelow) / 90))
        guard obstacle.block > 0.01 else { return point }
        let dx = point.x - obstacle.point.x
        let above = obstacle.point.y - point.y
        let below = max(0, -above)
        // Eases in gently over the 55 pt above the pointer, full from there down.
        let u = above > 0 ? max(0, 1 - above / 55) : 1
        let vertical = u * u * (3 - 2 * u)
        // The opening and the lanes it moves both grow with distance below the pointer.
        let opening = Self.gap + below * 0.5
        let reach = Self.gap * 2.1 + below * 0.6
        let lateral = exp(-pow(dx / reach, 2))
        // No hard choice of side: air right behind the pointer parts gradually.
        let split = CGFloat(tanh(Double(dx / 12)))
        let push = opening * lateral * vertical * obstacle.block * 0.3
        // The split may carry air past the stream's own edges, but only as far as the
        // fan has opened, so the outermost lines bend outward softly instead of jumping.
        let firstOrigin = origin - CGFloat(lane) * 7.1
        let edge = split >= 0
            ? basePoint(firstOrigin + 21 * 7.1, lane: 21, t: t, time: time, sway: sway, cursor: cursor).x + 2 - point.x
            : point.x - basePoint(firstOrigin, lane: 0, t: t, time: time, sway: sway, cursor: cursor).x + 2
        let room = max(0, edge) + below * 0.45
        point.x += split * push * room / (room + push + 0.001)
        return point
    }

    // MARK: Unit

    private func unit(sway: Double) -> some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 9)
                .fill(LinearGradient(colors: [.white, Color(white: 0.77)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.7), lineWidth: 0.6)
            RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.13))
                .frame(height: isOn ? 9 : 3).padding(.horizontal, 8).padding(.bottom, 5)
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [Color(white: 0.82), Color(white: 0.44)], startPoint: .top, endPoint: .bottom))
                .frame(height: isOn ? 5 : 3)
                .rotation3DEffect(.degrees(isOn ? 35 + sway * 18 : 0), axis: (x: 1, y: 0, z: 0))
                .padding(.horizontal, 10).padding(.bottom, 4)
            HStack {
                Text("LG").font(.system(size: 5, weight: .bold)).foregroundStyle(Color(white: 0.35))
                Spacer()
                Circle().fill(isOn ? flowColor : Color.gray).frame(width: 2.5, height: 2.5)
            }.padding(.horizontal, 12).padding(.bottom, 19)
        }
    }
}
