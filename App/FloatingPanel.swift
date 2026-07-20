import AppKit

/// Borderless panel that floats above all windows on every Space
/// without ever stealing focus from the active app.
final class FloatingPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        applyPanelBehavior()
    }

    /// Hosting SwiftUI content can stomp window properties, so this is
    /// re-applied after the content view controller is attached.
    func applyPanelBehavior() {
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // dragging is explicit (WindowDragGesture on the flasks and cards) —
        // background-drag in a non-activating panel swallows slider drags
        isMovableByWindowBackground = false
    }

    /// Top-left corner to restore when content-driven resizes move the frame.
    private var pinnedTopLeft: NSPoint?

    // The content size must be set (explicitly, by the app delegate) before
    // positioning — placing the panel while it is momentarily zero-sized
    // parks it off the screen edge.
    func positionTopRight() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let topLeft = NSPoint(x: area.maxX - frame.width - 16, y: area.maxY - 16)
        setFrameTopLeftPoint(topLeft)
        pinnedTopLeft = topLeft
        delegate = self
        persistPosition() // so a stale saved point doesn't re-trigger fallback
    }

    /// Place the panel where the user last dragged it; fall back to the
    /// top-right default when nothing is saved or the saved spot is no longer
    /// on any screen (e.g. an external display was unplugged).
    func restorePosition() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "cm-pos-x") != nil {
            let topLeft = NSPoint(
                x: defaults.double(forKey: "cm-pos-x"),
                y: defaults.double(forKey: "cm-pos-y")
            )
            let restored = NSRect(
                x: topLeft.x, y: topLeft.y - frame.height,
                width: frame.width, height: frame.height
            )
            let visibleEnough = NSScreen.screens.contains { screen in
                let overlap = screen.visibleFrame.intersection(restored)
                return overlap.width >= 60 && overlap.height >= 40
            }
            if visibleEnough {
                setFrameTopLeftPoint(topLeft)
                pinnedTopLeft = topLeft
                delegate = self
                return
            }
        }
        positionTopRight()
    }
}

extension FloatingPanel {
    fileprivate func persistPosition() {
        UserDefaults.standard.set(frame.minX, forKey: "cm-pos-x")
        UserDefaults.standard.set(frame.maxY, forKey: "cm-pos-y")
    }
}

extension FloatingPanel: NSWindowDelegate {
    // Content growth resizes the window from its bottom-left origin, which
    // would push it downward-right; keep the top-left corner where the user
    // (or the initial placement) put it.
    func windowDidResize(_ notification: Notification) {
        guard let pinnedTopLeft else { return }
        setFrameTopLeftPoint(pinnedTopLeft)
    }

    func windowDidMove(_ notification: Notification) {
        pinnedTopLeft = NSPoint(x: frame.minX, y: frame.maxY)
        persistPosition()
    }
}
