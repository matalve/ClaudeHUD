import Foundation

// Shared paths and JSON plumbing for the emitter subcommands.
// State layout matches Simple-Claude-Widget's emitter:
//   ~/.claude/monitor/limits.json           (flask data)
//   ~/.claude/monitor/sessions/<id>.json    (tracker data)

enum Monitor {
    static let claudeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")
    static let dir = claudeDir.appendingPathComponent("monitor")
    static let sessionsDir = dir.appendingPathComponent("sessions")
    static let limitsFile = dir.appendingPathComponent("limits.json")

    static func sessionFile(_ id: String) -> URL {
        sessionsDir.appendingPathComponent(id + ".json")
    }
}

func nowMs() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
}

func readJSONObject(_ url: URL) -> [String: Any]? {
    guard
        let data = try? Data(contentsOf: url),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj
}

// .atomic is write-to-temp + rename, which is what the widget's poller
// depends on — it must never observe a half-written file.
func atomicWriteJSON(_ obj: [String: Any], to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try? data.write(to: url, options: .atomic)
}

func readStdinJSON() -> [String: Any]? {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func truncate(_ value: Any?, _ n: Int) -> String {
    guard let s = value as? String else { return "" }
    let collapsed = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if collapsed.count > n {
        return String(collapsed.prefix(n - 1)) + "…"
    }
    return collapsed
}

func countLines(_ value: Any?) -> Int {
    guard let s = value as? String, !s.isEmpty else { return 0 }
    return s.components(separatedBy: "\n").count
}

// claude-opus-4-8 -> "Opus 4.8", claude-fable-5 -> "Fable 5",
// claude-haiku-4-5-20251001 -> "Haiku 4.5"
func prettyModel(_ id: String) -> String {
    var stripped = id.replacingOccurrences(of: "^claude-", with: "", options: .regularExpression)
    stripped = stripped.replacingOccurrences(of: "-\\d{8,}$", with: "", options: .regularExpression)
    var parts = stripped.split(separator: "-").map(String.init)
    guard !parts.isEmpty else { return id }
    let name = parts.removeFirst()
    let version = parts.joined(separator: ".")
    return name.prefix(1).uppercased() + name.dropFirst() + (version.isEmpty ? "" : " " + version)
}

// Claude Code names each session (the title shown in its own UI) and records
// it in the transcript as a "custom-title" entry. That beats any name we
// could derive: a session started in the home directory would otherwise be
// named after that directory, i.e. the account name.
func detectTitle(_ transcriptPath: Any?) -> String? {
    forEachTranscriptEntry(transcriptPath) { obj in
        guard obj["type"] as? String == "custom-title",
              let title = obj["customTitle"] as? String,
              !title.isEmpty
        else { return nil }
        return title
    }
}

// Falls back to the enclosing git repository's name, so a session working in
// a subdirectory still shows the project rather than the subdirectory.
func gitRepoName(_ cwd: Any?) -> String? {
    guard let start = cwd as? String, !start.isEmpty else { return nil }
    var dir = URL(fileURLWithPath: start)
    for _ in 0..<25 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            return dir.lastPathComponent
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    return nil
}

// Walks transcript entries newest-first, returning the first non-nil result.
private func forEachTranscriptEntry(
    _ transcriptPath: Any?, _ pick: ([String: Any]) -> String?
) -> String? {
    guard let path = transcriptPath as? String,
          let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let len = min(size, 131_072)
    try? handle.seek(toOffset: size - len)
    guard let data = try? handle.readToEnd() else { return nil }
    // Decode leniently: the fixed-size tail cut can land mid-character, and
    // strict UTF-8 decoding would then fail and lose everything.
    let text = String(decoding: data, as: UTF8.self)
    for line in text.split(separator: "\n").reversed() {
        guard
            let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let found = pick(obj)
        else { continue }
        return found
    }
    return nil
}

// The statusline (which would carry the model name) never runs under the
// VS Code extension, but transcripts record the model of every assistant
// message — read the tail of the file and take the most recent one.
func detectModel(_ transcriptPath: Any?) -> String? {
    // Take the main agent's latest model, so a subagent running a different
    // model doesn't hijack the card.
    forEachTranscriptEntry(transcriptPath) { obj in
        guard obj["type"] as? String == "assistant",
              obj["isSidechain"] as? Bool != true,
              let model = (obj["message"] as? [String: Any])?["model"] as? String
        else { return nil }
        return prettyModel(model)
    }
}
