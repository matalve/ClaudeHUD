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

// The statusline (which would carry the model name) never runs under the
// VS Code extension, but transcripts record the model of every assistant
// message — read the tail of the file and take the most recent one.
func detectModel(_ transcriptPath: Any?) -> String? {
    guard let path = transcriptPath as? String,
          let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let len = min(size, 131_072)
    try? handle.seek(toOffset: size - len)
    guard
        let data = try? handle.readToEnd(),
        let text = String(data: data, encoding: .utf8),
        let regex = try? NSRegularExpression(pattern: "\"model\"\\s*:\\s*\"(claude-[^\"]+)\"")
    else { return nil }
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    guard let last = matches.last, let range = Range(last.range(at: 1), in: text) else { return nil }
    return prettyModel(String(text[range]))
}
