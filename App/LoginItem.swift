import Foundation
import ServiceManagement

// Runs the app at login via a per-user LaunchAgent plist.
//
// SMAppService (the modern API) is unreliable for an ad-hoc-signed app: it
// identifies the app by its code signature, but an ad-hoc signature changes
// on every build, so a registration made by one build stops matching the
// installed copy — the status reads "not registered" and the toggle can't
// track it. A LaunchAgent keyed on the install path is signature-independent
// and reliable. It's a per-user agent, so it only affects this user account;
// other users are unaffected.
enum LoginItem {
    private static let label = "se.matalve.ClaudeHUD"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        on ? enable() : disable()
    }

    private static func enable() -> Bool {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
            return false
        }
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: agent, format: .xml, options: 0
            )
            try data.write(to: plistURL, options: .atomic)
            return true
        } catch {
            NSLog("ClaudeHUD login item enable failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func disable() -> Bool {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: plistURL)
            return true
        } catch {
            NSLog("ClaudeHUD login item disable failed: \(error.localizedDescription)")
            return false
        }
    }

    // Clear any leftover SMAppService registration from the previous version
    // of this feature, once, so login doesn't fire twice.
    static func migrateFromSMAppService() {
        let key = "cm-migrated-loginitem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        try? SMAppService.mainApp.unregister()
        UserDefaults.standard.set(true, forKey: key)
    }
}
