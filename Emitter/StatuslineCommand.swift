import Foundation

// Port of emitter/statusline.js. Claude Code pipes its statusline JSON here
// after every response. We:
//   1. persist rate limits to ~/.claude/monitor/limits.json  (flask data)
//   2. merge model/effort/context into the session state file (tracker data)
//   3. print a one-line statusline back to Claude Code

func runStatusline() {
    guard let p = readStdinJSON() else { return }

    let rl = p["rate_limits"] as? [String: Any] ?? [:]

    // --- 1. rate limits (global, last write wins) ---
    if rl["five_hour"] != nil || rl["seven_day"] != nil {
        // the statusline payload carries no model-scoped window — keep the
        // weekly Fable data the usage subcommand fetched instead of wiping it
        let prev = readJSONObject(Monitor.limitsFile) ?? [:]
        atomicWriteJSON([
            "five_hour": rl["five_hour"] ?? NSNull(),
            "seven_day": rl["seven_day"] ?? NSNull(),
            "seven_day_fable": rl["seven_day_fable"] ?? prev["seven_day_fable"] ?? NSNull(),
            "updated_at": nowMs(),
            "oauth_updated_at": prev["oauth_updated_at"] ?? 0,
        ], to: Monitor.limitsFile)
    }

    // --- 2. enrich session state ---
    if let id = p["session_id"] as? String {
        var s = readJSONObject(Monitor.sessionFile(id)) ?? [:]
        s["session_id"] = id
        if let model = (p["model"] as? [String: Any])?["display_name"] as? String {
            s["model"] = model
        }
        if let effort = (p["effort"] as? [String: Any])?["level"] as? String {
            s["effort"] = effort
        }
        if let ctx = (p["context_window"] as? [String: Any])?["used_percentage"] as? Double {
            s["context_pct"] = Int(ctx.rounded())
        }
        if s["title"] == nil,
           let projectDir = (p["workspace"] as? [String: Any])?["project_dir"] as? String
        {
            s["title"] = (projectDir as NSString).lastPathComponent
        }
        s["updated_at"] = nowMs()
        atomicWriteJSON(s, to: Monitor.sessionFile(id))
    }

    // --- 3. statusline text ---
    var parts: [String] = []
    if let model = (p["model"] as? [String: Any])?["display_name"] as? String { parts.append(model) }
    if let effort = (p["effort"] as? [String: Any])?["level"] as? String { parts.append(effort) }
    if let ctx = (p["context_window"] as? [String: Any])?["used_percentage"] as? Double {
        parts.append("ctx \(Int(ctx.rounded()))%")
    }
    if let pct = (rl["five_hour"] as? [String: Any])?["used_percentage"] as? Double {
        parts.append("5h \(Int(pct.rounded()))%")
    }
    if let pct = (rl["seven_day"] as? [String: Any])?["used_percentage"] as? Double {
        parts.append("7d \(Int(pct.rounded()))%")
    }
    print(parts.joined(separator: " | "), terminator: "")
}
