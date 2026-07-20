import Foundation

struct FlaskInfo: Equatable {
    var usedPercentage: Double
    var resetsAt: Int?

    init?(_ json: Any?) {
        guard let o = json as? [String: Any] else { return nil }
        guard let pct = (o["used_percentage"] as? Double) ?? (o["used_percentage"] as? Int).map(Double.init)
        else { return nil }
        usedPercentage = pct
        resetsAt = o["resets_at"] as? Int
    }
}

struct SessionDetail: Equatable {
    var message = ""
    var command = ""
    var description = ""
    var file = ""
    var added = 0
    var removed = 0
    var target = ""
    var query = ""
    var url = ""
    var step = ""
    var name = ""
    var info = ""
    var mcp = false
    var plan = false

    init(_ json: Any?) {
        let o = json as? [String: Any] ?? [:]
        message = o["message"] as? String ?? ""
        command = o["command"] as? String ?? ""
        description = o["description"] as? String ?? ""
        file = o["file"] as? String ?? ""
        added = o["added"] as? Int ?? 0
        removed = o["removed"] as? Int ?? 0
        target = o["target"] as? String ?? ""
        query = o["query"] as? String ?? ""
        url = o["url"] as? String ?? ""
        step = o["step"] as? String ?? ""
        name = o["name"] as? String ?? ""
        info = o["info"] as? String ?? ""
        mcp = o["mcp"] as? Bool ?? false
        plan = o["plan"] as? Bool ?? false
    }
}

struct MonitorSession: Identifiable, Equatable {
    var id: String
    var title: String
    var model: String?
    var effort: String?
    var contextPct: Int?
    var state: String
    var detail: SessionDetail
    var lastAction: String?
    var updatedAt: Int // epoch ms
    var stale: Bool
}

/// Continuous-run stopwatch per session: resets when it goes inactive→active,
/// pauses while waiting for permission, freezes on done/interrupted.
struct Stopwatch: Equatable {
    var prevState: String
    var runMs: Int?
    var runningSince: Int?

    func text(now: Int) -> String {
        guard let runMs else { return "" }
        let total = (runMs + (runningSince.map { now - $0 } ?? 0)) / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let mm = String(format: "%02d", m), ss = String(format: "%02d", s)
        return h > 0 ? "\(h):\(mm):\(ss)" : "\(m):\(ss)"
    }
}

private let hideAfterMs = 6 * 60 * 60 * 1000 // drop sessions idle > 6h
private let staleAfterMs = 10 * 60 * 1000    // dim sessions idle > 10min
private let runStates: Set<String> = [
    "thinking", "bash", "editing", "reading", "tool", "web", "planning", "compacting",
]
// States where the session is actively working — none of these transition on
// a user interrupt / permission denial (no hook fires), so they're the ones
// reconciled against the transcript.
private let busyStates: Set<String> = [
    "thinking", "bash", "editing", "reading", "tool", "permission",
]

func stopwatchClass(_ state: String) -> String {
    if state == "permission" { return "pause" }
    return runStates.contains(state) ? "run" : "off"
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published var fiveHour: FlaskInfo?
    @Published var sevenDay: FlaskInfo?
    @Published var fable: FlaskInfo?
    @Published var sessions: [MonitorSession] = []
    @Published var monitorAvailable = false
    @Published var alarmActive = false
    @Published var stopwatches: [String: Stopwatch] = [:]

    let synth = ToneSynth()
    private var timer: Timer?
    private var alarmKey: String?
    private var ackedKey: String?

    private var monitorDir: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_MONITOR_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/monitor")
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Any click acknowledges the current set of unanswered calls (keyed by
    /// session+timestamp so new calls ring again) without hiding the card.
    func acknowledge() {
        guard alarmKey != nil else { return }
        ackedKey = alarmKey
        updateAlarm()
    }

    private func refresh() {
        let fm = FileManager.default
        monitorAvailable = fm.fileExists(atPath: monitorDir.path)

        if let limits = readJSONObject(monitorDir.appendingPathComponent("limits.json")) {
            setIfChanged(&fiveHour, FlaskInfo(limits["five_hour"]))
            setIfChanged(&sevenDay, FlaskInfo(limits["seven_day"]))
            setIfChanged(&fable, FlaskInfo(limits["seven_day_fable"]))
        }

        let now = nowMs()
        var visible: [MonitorSession] = []
        let files = (try? fm.contentsOfDirectory(
            at: monitorDir.appendingPathComponent("sessions"), includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.pathExtension == "json" {
            guard
                let s = readJSONObject(file),
                let id = s["session_id"] as? String,
                s["ended"] as? Bool != true,
                let rawState = s["state"] as? String,
                rawState != "idle", // placeholder sessions that never got a prompt
                rawState != "ended"
            else { continue }
            let updatedAt = s["updated_at"] as? Int ?? 0
            guard now - updatedAt < hideAfterMs else { continue }

            let stale = now - updatedAt > staleAfterMs
            var state = rawState
            // a busy session whose transcript ends on an interrupt marker was
            // interrupted or had a tool denied — surface that instead of the
            // frozen "busy" state
            if busyStates.contains(state),
               let tp = s["transcript_path"] as? String, endsWithInterrupt(tp)
            {
                state = "interrupted"
            }
            if stale && (state == "thinking" || state == "bash") { state = "waiting" }

            visible.append(MonitorSession(
                id: id,
                title: s["title"] as? String ?? String(id.prefix(8)),
                model: s["model"] as? String,
                effort: s["effort"] as? String,
                contextPct: s["context_pct"] as? Int,
                state: state,
                detail: SessionDetail(s["detail"]),
                lastAction: s["last_action"] as? String,
                updatedAt: updatedAt,
                stale: stale
            ))
        }
        visible.sort { $0.updatedAt > $1.updatedAt }

        updateStopwatches(visible, now: now)
        if visible != sessions { sessions = visible }
        updateAlarm()
    }

    private func updateStopwatches(_ visible: [MonitorSession], now: Int) {
        var next: [String: Stopwatch] = [:]
        for s in visible {
            let cls = stopwatchClass(s.state)
            if var w = stopwatches[s.id] {
                let prevCls = stopwatchClass(w.prevState)
                if s.state == "done" && w.prevState != "done" && !s.stale { synth.ding() }
                if cls != prevCls {
                    if prevCls == "run" {
                        w.runMs = (w.runMs ?? 0) + now - (w.runningSince ?? now) // pause or freeze
                        w.runningSince = nil
                    }
                    if cls == "run" {
                        if prevCls == "off" { w.runMs = 0 } // fresh run, not a resume
                        w.runningSince = now
                    } else if cls == "pause", prevCls == "off" {
                        w.runMs = 0 // permission arrived without a visible active state first
                    }
                }
                w.prevState = s.state
                next[s.id] = w
            } else {
                // seeded with the current state so a card appearing already
                // "done" (e.g. widget startup) doesn't chime; the stopwatch
                // starts mid-run for sessions that are already active
                next[s.id] = Stopwatch(
                    prevState: s.state,
                    runMs: cls == "off" ? nil : 0,
                    runningSince: cls == "run" ? now : nil
                )
            }
        }
        // publish only real changes — an unconditional write invalidates the
        // whole view tree every poll tick
        if next != stopwatches { stopwatches = next }
    }

    // ring + vibrate while any session waits for approval
    private func updateAlarm() {
        let now = nowMs()
        let calling = sessions.filter { $0.state == "permission" && now - $0.updatedAt < staleAfterMs }
        if calling.isEmpty {
            alarmKey = nil
            ackedKey = nil
        } else {
            alarmKey = calling.map { "\($0.id):\($0.updatedAt)" }.sorted().joined(separator: "|")
        }
        let active = alarmKey != nil && alarmKey != ackedKey
        if active != alarmActive { alarmActive = active }
        synth.setRinging(active)
    }

    private func setIfChanged(_ slot: inout FlaskInfo?, _ value: FlaskInfo?) {
        if slot != value, value != nil { slot = value }
    }
}

/// True when the last entry of the transcript is a "[Request interrupted by
/// user]" / "…for tool use" marker — the tail of an interrupted turn.
/// Cached on the transcript's mtime: this runs every poll tick for every busy
/// session, and re-reading an unchanged tail is pure waste.
private var interruptCache: [String: (mtime: Date, result: Bool)] = [:]

private func endsWithInterrupt(_ path: String) -> Bool {
    let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        .flatMap { $0 } ?? .distantPast
    if let cached = interruptCache[path], cached.mtime == mtime {
        return cached.result
    }
    let result = readTailForInterrupt(path)
    interruptCache[path] = (mtime, result)
    return result
}

private func readTailForInterrupt(_ path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let len = min(size, 65_536)
    try? handle.seek(toOffset: size - len)
    guard
        let data = try? handle.readToEnd(),
        let text = String(data: data, encoding: .utf8),
        // last non-empty line is the newest entry
        let line = text.split(separator: "\n").reversed().first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }),
        let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
        entry["type"] as? String == "user"
    else { return false }
    let content = (entry["message"] as? [String: Any])?["content"]
    let message: String
    if let s = content as? String {
        message = s
    } else if let parts = content as? [[String: Any]] {
        message = parts.compactMap { $0["text"] as? String }.first ?? ""
    } else {
        return false
    }
    return message.hasPrefix("[Request interrupted by user")
}
