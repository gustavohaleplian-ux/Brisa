import SwiftUI
import AppKit

/// A button that opens a menu with the look of a native macOS menu, just below it.
///
/// A real native menu is a separate system window: it can't leave the screen together
/// with the panel, and SwiftUI's `Menu` ignores the first click in a menu bar panel. This
/// menu is instead a small borderless window *attached* to the panel (a child window):
/// it opens on the first click, extends below the panel like a native menu, and fades
/// out together with the panel when it closes.
struct PopupMenuButton<Label: View>: View {
    struct Item {
        let title: String
        let action: () -> Void
    }

    let items: [Item]
    @ViewBuilder let label: () -> Label
    @State private var controller = PopupMenuController()

    var body: some View {
        Button { controller.toggle(items.map { ($0.title, $0.action) }) } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(controller: controller))
    }
}

/// Opens, positions and closes the menu window.
@MainActor
private final class PopupMenuController {
    weak var anchor: NSView?
    private var panel: PopupMenuPanel?
    private var monitors: [Any] = []

    func toggle(_ items: [(title: String, action: () -> Void)]) {
        if panel != nil { close() } else { open(items) }
    }

    private func open(_ items: [(title: String, action: () -> Void)]) {
        guard let anchor, let parent = anchor.window else { return }
        let content = PopupMenuContent(items: items) { [weak self] in self?.close() }
        let host = FirstClickHostingView(rootView: content)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        let panel = PopupMenuPanel(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.appearance = parent.appearance
        panel.contentView = host

        // Just below the button, aligned to its leading edge, like a native pull-down.
        // Kept on screen; opens upward only if there is no room below.
        let button = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var origin = NSPoint(x: button.minX - 6, y: button.minY - size.height - 4)
        if let screen = parent.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            if origin.y < screen.minY + 4 { origin.y = button.maxY + 4 }
        }
        panel.setFrameOrigin(origin)
        parent.addChildWindow(panel, ordered: .above)
        // Keep the panel focused, so it doesn't turn grey while the menu is open.
        parent.makeKey()
        self.panel = panel

        // A click anywhere else in the app closes just the menu (a click on the "…"
        // button itself is left to toggle it). Esc closes it too.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, event.window !== panel else { return }
                if let anchor = self.anchor, event.window === anchor.window,
                   anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return }
                self.close()
            }
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Esc
            MainActor.assumeIsolated { self?.close() }
            return nil
        } as Any)
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }
}

/// The menu's window: borderless, transparent, and never focused, so the panel keeps
/// focus while the menu is open. The app closes it together with the panel.
final class PopupMenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Clicks on a window that isn't focused still reach the menu items on the first try.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The menu itself, drawn like a native macOS menu: the system menu material, 13 pt
/// items and the accent-colored highlight under the pointer.
private struct PopupMenuContent: View {
    let items: [(title: String, action: () -> Void)]
    let dismiss: () -> Void
    @State private var highlighted: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items, id: \.title) { item in
                Button {
                    dismiss()
                    item.action()
                } label: {
                    Text(item.title)
                        .font(.system(size: 13))
                        .foregroundStyle(highlighted == item.title ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(highlighted == item.title ? Color(nsColor: .controlAccentColor) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { highlighted = item.title } else if highlighted == item.title { highlighted = nil }
                }
            }
        }
        .padding(5)
        .frame(width: 170)
        .background(MenuMaterial().clipShape(RoundedRectangle(cornerRadius: 10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// The system's own menu background material, blurring what is behind the window.
private struct MenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// An invisible, click-through view behind the button, used for positioning. When the
/// button leaves the screen (the panel closed), the menu and its click watchers go too.
private struct MenuAnchorView: NSViewRepresentable {
    let controller: PopupMenuController
    final class FlippedView: NSView {
        var onDetach: (() -> Void)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { onDetach?() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
    func makeNSView(context: Context) -> FlippedView {
        let view = FlippedView()
        controller.anchor = view
        view.onDetach = { [weak controller] in controller?.close() }
        return view
    }
    func updateNSView(_ nsView: FlippedView, context: Context) { controller.anchor = nsView }
}
