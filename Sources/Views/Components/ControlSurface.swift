import SwiftUI

/// The control background: Liquid Glass on macOS 26, a compatible material before.
/// The native popover keeps its own outer material and corners; glass is limited
/// to the controls inside it.
struct ControlSurface: ViewModifier {
    let accent: Color
    let interactive: Bool
    var cornerRadius: CGFloat = 14

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(accent.opacity(0.16)).interactive(interactive), in: shape)
        } else {
            content
                .background(.thinMaterial, in: shape)
                .background(accent.opacity(0.12), in: shape)
        }
    }
}

/// Hides the system focus ring on controls that draw their own (macOS 14 and later).
struct QuietFocusEffect: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}
