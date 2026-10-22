import SwiftUI

/// A wide temperature control with a stable cold-to-warm scale, usable with the mouse,
/// the keyboard and VoiceOver. The color indicates the setpoint, never whether a
/// cooling-only appliance can heat.
struct TemperatureTrack: View {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let step: Double
    let onEditingChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var editing = false
    @State private var hovering = false
    // The panel grants this control focus automatically when it opens, so the ring
    // only appears once the person actually uses the keyboard on it.
    @State private var keyboardFocus = false
    private let colors: [Color] = [Color(red: 0.12, green: 0.49, blue: 0.95),
        Color(red: 0.25, green: 0.77, blue: 0.91), Color(red: 0.90, green: 0.77, blue: 0.51),
        Color(red: 0.98, green: 0.40, blue: 0.25)]
    private var fraction: Double {
        min(1, max(0, (value - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)))
    }
    private func snapped(_ number: Double) -> Double {
        let quantized = bounds.lowerBound + ((number - bounds.lowerBound) / step).rounded() * step
        return min(bounds.upperBound, max(bounds.lowerBound, quantized))
    }
    private func adjust(_ delta: Double) {
        guard isEnabled else { return }
        onEditingChanged(true)
        value = snapped(value + delta)
        onEditingChanged(false)
    }
    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - 24)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04))
                LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                    .opacity(isEnabled ? 0.32 : 0.08)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: CGFloat(fraction) * travel + 12)
                    }
                    .opacity(isEnabled ? 0.64 : 0.12)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(focused && keyboardFocus ? 0.7 : hovering ? 0.25 : 0.1), lineWidth: focused && keyboardFocus ? 2 : 1)
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(colors: [.white, Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 18, height: editing ? 32 : 28)
                    .overlay(Capsule().fill(.black.opacity(0.18)).frame(width: 2, height: 10))
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                    .offset(x: 3 + CGFloat(fraction) * travel)
                    .opacity(isEnabled ? 1 : 0.4)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    guard isEnabled else { return }
                    if !editing { editing = true; keyboardFocus = false; focused = true; onEditingChanged(true) }
                    let position = min(1, max(0, (gesture.location.x - 12) / travel))
                    value = snapped(bounds.lowerBound + Double(position) * (bounds.upperBound - bounds.lowerBound))
                }
                .onEnded { _ in
                    guard editing else { return }
                    editing = false
                    onEditingChanged(false)
                })
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: editing)
        }
        .frame(height: 38)
        .focusable(isEnabled)
        .focused($focused)
        .modifier(QuietFocusEffect())
        .onAppear { DispatchQueue.main.async { focused = false } }
        .onChange(of: focused) { _, hasFocus in
            if !hasFocus { keyboardFocus = false }
        }
        .onMoveCommand { direction in
            keyboardFocus = true
            switch direction {
            case .right, .up: adjust(step)
            case .left, .down: adjust(-step)
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Temperatura desejada")
        .accessibilityValue("\(value.formatted()) graus Celsius")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(step)
            case .decrement: adjust(-step)
            @unknown default: break
            }
        }
    }
}
