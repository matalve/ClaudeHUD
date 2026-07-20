import ServiceManagement

// Registers the app as a macOS login item via SMAppService (macOS 13+), so
// the HUD comes back on its own after a restart. This is a per-user login
// item (stored in the current user's Background Task Management database), so
// it only launches for this user account — other users are unaffected.
enum LoginItem {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("ClaudeHUD login item toggle failed: \(error.localizedDescription)")
            return false
        }
    }

    // Opens System Settings › General › Login Items, where the OS may require
    // the user to approve a freshly added login item.
    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
