import Foundation

// Port of emitter/install.js: merges the hook + statusline wiring into
// ~/.claude/settings.json (SETTINGS env overrides, mainly for testing).
// Idempotent — re-run after moving the app. A backup is written first.

// Which hook events we wire, and how. Tool events match "*"; SessionEnd stays
// synchronous so the "ended" state is written before Claude Code exits.
private let events: [(name: String, matcher: String?, async: Bool)] = [
    ("SessionStart", nil, true),
    ("UserPromptSubmit", nil, true),
    ("PreToolUse", "*", true),
    ("PostToolUse", "*", true),
    ("PermissionRequest", "*", true),
    ("Notification", nil, true),
    ("PreCompact", nil, true),
    ("Stop", nil, true),
    ("SessionEnd", nil, false),
]

// A command belongs to ClaudeHUD if it invokes claudehud-emitter with the
// given subcommand — matches prior installs even if the app was moved.
private func isOurs(_ command: Any?, _ subcommand: String) -> Bool {
    guard let cmd = command as? String else { return false }
    return cmd.range(
        of: "claudehud-emitter\"?\\s+\(subcommand)\\b", options: .regularExpression
    ) != nil
}

func runInstall() {
    let settingsPath = ProcessInfo.processInfo.environment["SETTINGS"]
        ?? Monitor.claudeDir.appendingPathComponent("settings.json").path
    let settingsURL = URL(fileURLWithPath: settingsPath)

    var settings: [String: Any] = [:]
    if let data = try? Data(contentsOf: settingsURL), !data.isEmpty {
        guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            FileHandle.standardError.write(Data(
                "error: \(settingsPath) is not valid JSON. Fix it and re-run.\n".utf8
            ))
            exit(1)
        }
        settings = parsed
        let stamp = Int(Date().timeIntervalSince1970)
        try? FileManager.default.copyItem(
            at: settingsURL,
            to: URL(fileURLWithPath: "\(settingsPath).claudehud-backup-\(stamp)")
        )
    }

    let emitter = selfExecutable().path
    let hookCmd = "\"\(emitter)\" hook"
    let statusCmd = "\"\(emitter)\" statusline"

    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    for event in events {
        let groups = hooks[event.name] as? [[String: Any]] ?? []

        // Drop any prior ClaudeHUD entries, keeping the user's own hooks;
        // drop groups that become empty.
        var kept: [[String: Any]] = []
        for group in groups {
            guard let groupHooks = group["hooks"] as? [[String: Any]] else {
                kept.append(group)
                continue
            }
            let remaining = groupHooks.filter { !isOurs($0["command"], "hook") }
            if !remaining.isEmpty {
                var g = group
                g["hooks"] = remaining
                kept.append(g)
            }
        }

        // Add our fresh group.
        var hook: [String: Any] = ["type": "command", "command": hookCmd]
        if event.async { hook["async"] = true }
        var group: [String: Any] = ["hooks": [hook]]
        if let matcher = event.matcher { group["matcher"] = matcher }
        kept.append(group)

        hooks[event.name] = kept
    }
    settings["hooks"] = hooks

    // Statusline is a single slot and optional (rate limits also arrive via
    // the usage subcommand). Install it only if free or already ours — never
    // clobber a custom one.
    if let sl = settings["statusLine"] as? [String: Any] {
        if isOurs(sl["command"], "statusline") {
            settings["statusLine"] = ["type": "command", "command": statusCmd]
            print("statusline: updated")
        } else {
            print("statusline: left your existing one in place (skipped).")
            print("            to use ClaudeHUD's instead, set statusLine.command to:")
            print("              \(statusCmd)")
        }
    } else {
        settings["statusLine"] = ["type": "command", "command": statusCmd]
        print("statusline: installed")
    }

    guard let data = try? JSONSerialization.data(
        withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]
    ) else { exit(1) }
    try? (String(data: data, encoding: .utf8)! + "\n").write(
        to: settingsURL, atomically: true, encoding: .utf8
    )
    print("hooks: wired \(events.count) events -> claudehud-emitter hook")
    print("restart Claude Code sessions so the hooks load")
}
