import SwiftUI

@main
struct ClaudeHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // Held by the App so MenuBarExtra reliably re-renders when it changes.
    @StateObject private var login = LoginModel.shared

    var body: some Scene {
        MenuBarExtra("ClaudeHUD", systemImage: "flask") {
            Button(appDelegate.panelVisible ? "Hide HUD" : "Show HUD") {
                appDelegate.togglePanel()
            }
            Button("Install Claude Code Hooks…") {
                appDelegate.installHooks()
            }
            Divider()
            Button(login.enabled ? "✓ Start at Login" : "Start at Login") {
                login.toggle()
            }
            Divider()
            Button("Quit ClaudeHUD") {
                NSApp.terminate(nil)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var panelVisible = false
    @Published var hovering = false

    private var panel: FloatingPanel?
    private let store = MonitorStore()
    private var probeTimer: Timer?
    private var clickMonitor: Any?
    private var globalClickMonitor: Any?
    private var usageTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.migrateFromSMAppService()
        let scale = initialScale()
        let controller = NSHostingController(
            rootView: WidgetView()
                .environmentObject(store)
                .environmentObject(self)
        )
        controller.sizingOptions = []

        let panel = FloatingPanel()
        panel.contentViewController = controller
        panel.applyPanelBehavior()
        panel.setContentSize(NSSize(width: designWidth * scale, height: designHeight * scale))
        panel.restorePosition()
        self.panel = panel

        // Defer showing until scene setup has settled, so nothing in the
        // launch sequence can order the panel back out.
        DispatchQueue.main.async { [weak self] in
            panel.orderFrontRegardless()
            self?.panelVisible = panel.isVisible
        }

        store.start()
        startProbe()
        startUsageHeartbeat()

        // any click anywhere acknowledges a ringing permission alarm — the
        // widget itself is click-through, and the click that approves the
        // permission in the editor should silence the ring anyway. The global
        // monitor covers other apps, the local one our own chrome.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.store.acknowledge()
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in self?.store.acknowledge() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // reflect an external change (e.g. removed under System Settings)
        LoginModel.shared.refresh()
    }

    func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
        panelVisible = panel.isVisible
        if panelVisible { refreshUsage() } // don't show yesterday's flasks
    }

    // The emitter's usage fetch is otherwise hook-driven, so without Claude
    // activity the flasks freeze at the last persisted values (the original
    // has the same flaw). Nudge it periodically and on wake from sleep; the
    // emitter self-throttles on oauth_updated_at, so extra nudges are cheap.
    private func startUsageHeartbeat() {
        refreshUsage()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUsage() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // twice, because the network is often not up yet right after wake
            for delay in [3.0, 20.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    Task { @MainActor in self?.refreshUsage() }
                }
            }
        }
    }

    private func refreshUsage() {
        guard panelVisible else { return }
        let process = Process()
        process.executableURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/claudehud-emitter")
        process.arguments = ["usage"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    func hidePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panelVisible = false
    }

    func applyScale(_ k: Double) {
        guard let panel else { return }
        // keep the top-right corner fixed — the widget lives at the screen's
        // right edge, so growing rightward would push it off the screen
        let topRight = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        panel.setContentSize(NSSize(width: designWidth * k, height: designHeight * k))
        panel.setFrameTopLeftPoint(NSPoint(x: topRight.x - panel.frame.width, y: topRight.y))
    }

    private func initialScale() -> Double {
        let stored = UserDefaults.standard.double(forKey: "cm-scale")
        return stored == 0 ? 1 : stored
    }

    // The whole widget is click-through except the chrome strip — flasks and
    // cards are pure display. macOS click-through is whole-window only, and
    // no mouse events arrive while the window ignores the cursor — so poll
    // the global cursor position, like the original's cursor_probe.
    private func startProbe() {
        probeTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probeTick() }
        }
    }

    private func probeTick() {
        guard let panel, panel.isVisible else {
            hovering = false
            return
        }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        let inside = frame.contains(mouse)
        if hovering != inside { hovering = inside }

        var overChrome = false
        if inside {
            let k = UserDefaults.standard.double(forKey: "cm-scale")
            let scale = k == 0 ? 1 : k
            let point = CGPoint(
                x: (mouse.x - frame.minX) / scale,
                y: (frame.maxY - mouse.y) / scale // flip to top-left origin
            )
            overChrome = chromeStripRect.contains(point)
        }
        let ignore = inside && !overChrome
        if panel.ignoresMouseEvents != ignore {
            panel.ignoresMouseEvents = ignore
        }
    }

    func installHooks() {
        let emitter = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/claudehud-emitter")
        let process = Process()
        process.executableURL = emitter
        process.arguments = ["install"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var output = ""
        do {
            try process.run()
            process.waitUntilExit()
            output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            ) ?? ""
        } catch {
            output = "failed to run claudehud-emitter: \(error.localizedDescription)"
        }

        let alert = NSAlert()
        alert.messageText = "Claude Code hooks"
        alert.informativeText = output.isEmpty ? "done" : output
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
