import Foundation

// Port of Simple-Claude-Widget's emitter/hook.js: reads the hook payload on
// stdin and updates the per-session state file the widget polls.

private let staleMs = 24 * 60 * 60 * 1000 // prune session files older than a day

// Map a tool invocation to a display state.
private func toolState(_ toolName: String?, _ input: [String: Any])
    -> (state: String, detail: [String: Any])
{
    switch toolName {
    case "AskUserQuestion":
        // Claude is asking the user something — that's an incoming call.
        let questions = (input["questions"] as? [[String: Any]] ?? [])
            .compactMap { $0["question"] as? String }
            .joined(separator: " / ")
        let message = truncate(questions, 140)
        return ("permission", ["message": message.isEmpty ? "Claude has a question" : message])
    case "Bash":
        return ("bash", [
            "command": truncate(input["command"], 120),
            "description": truncate(input["description"], 80),
        ])
    case "Edit":
        return ("editing", [
            "file": basename(input["file_path"]),
            "added": countLines(input["new_string"]),
            "removed": countLines(input["old_string"]),
        ])
    case "Write":
        return ("editing", [
            "file": basename(input["file_path"]),
            "added": countLines(input["content"]),
            "removed": 0,
        ])
    case "NotebookEdit":
        return ("editing", [
            "file": basename(input["notebook_path"]),
            "added": countLines(input["new_source"]),
            "removed": 0,
        ])
    case "Read", "Glob", "Grep":
        let target = (input["file_path"] ?? input["pattern"]) as? String ?? ""
        return ("reading", ["target": truncate((target as NSString).lastPathComponent, 60)])
    case "WebSearch":
        return ("web", ["query": truncate(input["query"], 80)])
    case "WebFetch":
        return ("web", ["url": truncate(input["url"], 80)])
    case "TodoWrite":
        // surface the step Claude is currently on, not the whole list
        let todos = input["todos"] as? [[String: Any]] ?? []
        let active = todos.first { $0["status"] as? String == "in_progress" }
            ?? todos.first { $0["status"] as? String != "completed" }
        let step = (active?["activeForm"] ?? active?["content"]) as? String ?? ""
        return ("planning", ["step": truncate(step, 90)])
    case "ExitPlanMode":
        // a finished plan is blocking on the user — ring it like a permission
        return ("permission", ["plan": true, "message": truncate(input["plan"], 140)])
    case "Agent", "Task":
        return ("tool", ["name": "Subagent", "info": truncate(input["description"], 60)])
    default:
        // MCP tools arrive as mcp__<server>__<tool>; show them as "server: tool"
        if let name = toolName, name.hasPrefix("mcp__") {
            let parts = name.split(separator: "__", omittingEmptySubsequences: false).map(String.init)
            let server = parts.count > 1 ? parts[1] : ""
            let tool = parts.count > 2 ? parts[2...].joined(separator: "__") : ""
            return ("tool", [
                "name": server.isEmpty ? name : "\(server): \(tool)",
                "info": "",
                "mcp": true,
            ])
        }
        return ("tool", ["name": toolName ?? "", "info": ""])
    }
}

private func basename(_ value: Any?) -> String {
    ((value as? String ?? "?") as NSString).lastPathComponent
}

// One-line recap of the current state, kept as "last action" once it finishes.
private func summarize(_ s: [String: Any]) -> String {
    let d = s["detail"] as? [String: Any] ?? [:]
    switch s["state"] as? String {
    case "bash":
        return "$ " + (d["command"] as? String ?? "")
    case "editing":
        return "✎ \(d["file"] as? String ?? "") +\(d["added"] as? Int ?? 0) −\(d["removed"] as? Int ?? 0)"
    case "reading":
        return "read " + (d["target"] as? String ?? "")
    case "web":
        if let q = d["query"] as? String, !q.isEmpty { return "searched " + q }
        return "fetched " + (d["url"] as? String ?? "")
    case "planning":
        if let step = d["step"] as? String, !step.isEmpty { return "📋 " + step }
        return "planning"
    case "tool":
        return d["name"] as? String ?? ""
    default:
        return s["last_action"] as? String ?? ""
    }
}

private func pruneStale() {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(
        at: Monitor.sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]
    ) else { return }
    let cutoff = Date().addingTimeInterval(-Double(staleMs) / 1000)
    for file in entries {
        if let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate, mtime < cutoff
        {
            try? fm.removeItem(at: file)
        }
    }
}

func selfExecutable() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .absoluteURL
}

func runHook() {
    guard let p = readStdinJSON(), let id = p["session_id"] as? String else { return }

    var s = readJSONObject(Monitor.sessionFile(id)) ?? [:]
    s["session_id"] = id
    if let cwd = p["cwd"] as? String { s["cwd"] = cwd }
    // needed by the widget to tail the transcript for interrupt markers — no
    // hook fires on user interrupt or permission denial, so the trailing
    // "[Request interrupted by user]" entry is the only signal
    if let tp = p["transcript_path"] as? String { s["transcript_path"] = tp }
    if let effort = (p["effort"] as? [String: Any])?["level"] as? String { s["effort"] = effort }
    s["updated_at"] = nowMs()

    let mainAgent = p["agent_id"] == nil || p["agent_type"] as? String == "main"

    switch p["hook_event_name"] as? String {
    case "SessionStart":
        let fallback = basename(p["cwd"])
        s["title"] = (p["session_title"] as? String)
            ?? (s["title"] as? String)
            ?? (fallback.isEmpty ? "session" : fallback)
        if let model = p["model"] as? String {
            s["model"] = prettyModel(model)
        } else if let model = (p["model"] as? [String: Any])?["display_name"] as? String {
            s["model"] = model
        }
        // Switching conversations in VS Code spawns placeholder sessions that
        // may never receive a prompt — start hidden ('idle') and only surface
        // on real activity. A mid-conversation restart (compact/resume) keeps
        // the live card as-is.
        if s["state"] == nil || s["state"] as? String == "idle" || s["ended"] as? Bool == true {
            s["state"] = "idle"
            s["detail"] = [String: Any]()
        }
        s["ended"] = false
        pruneStale()
    case "UserPromptSubmit":
        s["state"] = "thinking"
        s["detail"] = [String: Any]()
        if s["model"] == nil, let model = detectModel(s["transcript_path"]) { s["model"] = model }
    case "PreToolUse":
        // Ignore subagent tool churn so the tracker reflects the main agent.
        if mainAgent {
            let (state, detail) = toolState(p["tool_name"] as? String, p["tool_input"] as? [String: Any] ?? [:])
            s["state"] = state
            s["detail"] = detail
        }
    case "PostToolUse":
        if mainAgent {
            s["last_action"] = summarize(s)
            s["state"] = "thinking"
            s["detail"] = [String: Any]()
        }
    case "PermissionRequest":
        // Fires when a permission prompt is about to be shown — the reliable
        // "Claude is calling" signal (Notification doesn't fire in VS Code).
        let ti = p["tool_input"] as? [String: Any] ?? [:]
        let what = (ti["command"] ?? ti["file_path"] ?? ti["description"]) as? String ?? ""
        let message = truncate(
            [p["tool_name"] as? String, what.isEmpty ? nil : what]
                .compactMap { $0 }.joined(separator: ": "),
            140
        )
        s["state"] = "permission"
        s["detail"] = ["message": message.isEmpty ? "approval needed" : message]
    case "Notification":
        if p["notification_type"] as? String == "permission_prompt" {
            s["state"] = "permission"
            s["detail"] = ["message": truncate(p["message"], 120)]
        } else {
            s["state"] = "waiting"
            s["detail"] = ["message": truncate(p["message"], 120)]
        }
    case "Stop":
        s["state"] = "done"
        s["detail"] = ["message": truncate(p["last_assistant_message"], 100)]
        if let model = detectModel(s["transcript_path"]) { s["model"] = model }
    case "PreCompact":
        // compaction can stall a turn for a while — say so instead of looking hung
        s["state"] = "compacting"
        s["detail"] = [String: Any]()
    case "SessionEnd":
        s["ended"] = true
        s["state"] = "ended"
    default:
        break
    }

    atomicWriteJSON(s, to: Monitor.sessionFile(id))
    // Rate limits are refreshed by the app (UsageFetcher), which caches the
    // keychain token — hooks no longer spawn a usage fetch, so the emitter
    // never touches the keychain.
}
