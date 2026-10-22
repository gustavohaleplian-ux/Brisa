import SwiftUI
import AppKit

/// The app's entry point. Brisa lives only in the menu bar (no Dock icon, no main
/// window): `BrisaDelegate` owns the menu bar item and the panel.
@main
@MainActor
struct BrisaApp: App {
    @NSApplicationDelegateAdaptor(BrisaDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// App-level actions offered in the panel's "…" menu.
@MainActor
enum AppLifecycle {
    /// Quits and opens Brisa again. The relaunch is handed to a short-lived shell that
    /// waits for this instance to exit first, so two copies never run side by side.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }
}

/// Owns the menu bar item (temperature and animated icon) and the panel, an
/// `NSPopover` hosting `ClimatePanel`, and decides when the panel opens and closes.
@MainActor
final class BrisaDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = ClimateModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let symbol = NSImage(systemSymbolName: "air.conditioner.horizontal", accessibilityDescription: "Brisa")
    /// 0 = off (unit only, centered), 1 = on (unit with airflow).
    private var iconProgress: CGFloat = 1
    private var iconTarget: CGFloat = 1
    private var iconTimer: Timer?

    // SF Symbols has no variant without airflow, so every frame draws the same symbol
    // revealed from the top: 46% shows only the unit body. Frames keep the full size,
    // and the visible part stays vertically centered, so the menu bar never jumps.
    private func icon(progress: CGFloat) -> NSImage? {
        guard let full = symbol else { return nil }
        let size = full.size
        let visible = size.height * (0.46 + 0.54 * progress)
        let image = NSImage(size: size, flipped: false) { _ in
            let lift = (size.height - visible) / 2
            NSRect(x: 0, y: size.height - visible - lift, width: size.width, height: visible).clip()
            full.draw(in: NSRect(x: 0, y: -lift, width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Brisa"
        return image
    }

    private func animateIcon(on: Bool) {
        let target: CGFloat = on ? 1 : 0
        guard target != iconTarget else { return }
        iconTarget = target
        iconTimer?.invalidate()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            iconProgress = target
            statusItem?.button?.image = icon(progress: target)
            return
        }
        let start = iconProgress, began = Date(), duration = 0.45
        iconTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, Date().timeIntervalSince(began) / duration)
                let eased = CGFloat(t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
                self.iconProgress = start + (target - start) * eased
                self.statusItem?.button?.image = self.icon(progress: self.iconProgress)
                if t >= 1 { timer.invalidate() }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.image = icon(progress: 1)
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(togglePanel)
        }
        // Closing is handled by the app itself (see watchForOutsideClicks): the automatic
        // "transient" behavior loses track of the panel once the "…" menu window is
        // attached to it, leaving the panel open and unfocused.
        popover.behavior = .applicationDefined
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        // Hide the anchor arrow. There is no public API for this, so check first
        // and keep the default arrow if AppKit ever removes the key.
        if popover.responds(to: Selector(("setShouldHideAnchor:"))) {
            popover.setValue(true, forKey: "shouldHideAnchor")
        }
        model.onStatusChange = { [weak self] in self?.updateStatusItem() }
        updateStatusItem()
        Task { await model.reconnect() }
        model.startAutoRefresh()
        // After sleep the last reading may be hours old; read again on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let model = self?.model else { return }
                Task { await model.refreshQuietly() }
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.title = " " + model.menuTemperature
        // Airflow only when the unit reports being on; off shows the bare unit.
        animateIcon(on: !(model.ready && model.power == "POWER_OFF"))
        let context = model.demo ? "Demonstração" : !model.ready ? "Sem estado atualizado" :
            model.power == "POWER_OFF" ? "Desligado · temperatura ambiente" : "Temperatura configurada"
        button.toolTip = "Brisa · " + context + " · " + model.menuTemperature
        button.setAccessibilityLabel("Brisa, " + context + ", " + model.menuTemperature)
        if popover.isShown {
            popover.positioningRect = iconRect(in: button)
        }
    }

    private func iconRect(in button: NSStatusBarButton) -> NSRect {
        // Anchor to the image rather than to the variable-width temperature title.
        let rect = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
        return rect.isEmpty ? button.bounds : rect
    }

    @objc private func togglePanel() {
        if popover.isShown {
            closePanel()
            return
        }
        guard let button = statusItem?.button else { return }
        panelOpening += 1
        // Opening the panel shows fresh data: re-read if the last read is over a minute old.
        Task { [model] in await model.refreshQuietly(ifOlderThan: 60) }
        let controller = NSHostingController(rootView: ClimatePanel(model: model).preferredColorScheme(.dark))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        // A menu bar app is not active on its own; activate it so the very first click
        // on any control in the panel works, instead of only bringing the app forward.
        NSApp.activate()
        // AppKit centers around the anchor when space permits and keeps the
        // popover inside the screen near an edge or the camera housing.
        popover.show(relativeTo: iconRect(in: button), of: button, preferredEdge: .minY)
        let window = popover.contentViewController?.view.window
        window?.makeKey()
        // AppKit hands focus to the first focusable control (the temperature track),
        // which draws a focus ring on open. Start with nothing focused instead.
        DispatchQueue.main.async { window?.makeFirstResponder(nil) }
        watchForOutsideClicks()
    }

    func popoverDidClose(_ notification: Notification) {
        stopWatchingOutsideClicks()
        // Release the panel so its TimelineView cannot keep animating offscreen. Done on
        // the next turn, so a button inside the panel can finish its own work first.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.popover.contentViewController = nil
        }
    }

    // MARK: Closing on outside clicks

    private var outsideClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// Counts openings of the panel, so a delayed close never hits a newer opening.
    private var panelOpening = 0

    /// The panel closes when the app says so, not automatically: on any click outside
    /// Brisa (another app, the desktop, the menu bar), and when Brisa stops being the
    /// active app (switching apps with a click or ⌘Tab). The menu bar icon toggles it.
    private func watchForOutsideClicks() {
        stopWatchingOutsideClicks()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func stopWatchingOutsideClicks() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        outsideClickMonitor = nil
        resignObserver = nil
    }

    private func closePanel() {
        let window = popover.contentViewController?.view.window
        guard popover.isShown || window?.isVisible == true else { return }
        // AppKit refuses to close the popover while the "…" menu window is still
        // attached to it, so let go of the menu first. It fades out over the same time
        // as the panel, so both leave together.
        dismissAttachedMenus()
        popover.performClose(nil)
        // Safety net: if the close was refused anyway, force it once the fade is over.
        // Only for this same opening of the panel, never one opened again since.
        let opening = panelOpening
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.panelOpening == opening,
                  self.popover.contentViewController?.view.window?.isVisible == true else { return }
            self.popover.close()
        }
    }

    /// Detaches the "…" menu window from the panel and fades it out.
    private func dismissAttachedMenus() {
        guard let window = popover.contentViewController?.view.window else { return }
        for menu in (window.childWindows ?? []).compactMap({ $0 as? PopupMenuPanel }) {
            window.removeChildWindow(menu)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                menu.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { menu.orderOut(nil) }
            }
        }
    }
}
