import Foundation
import Security

// Port of emitter/usage.js. The statusline never runs under the VS Code
// extension, so hooks spawn this (throttled) to keep limits.json fresh. Uses
// the same OAuth usage endpoint as community usage monitors — undocumented,
// may break on Anthropic changes.
//
// macOS difference from the original: Claude Code stores its OAuth token in
// the login keychain, not ~/.claude/.credentials.json — read the keychain
// first (the OS shows an approval prompt on first access) and fall back to
// the credentials file.

private let maxAgeMs = 60_000

private func isFresh() -> Bool {
    // keyed on our own stamp: the statusline bumps updated_at but can't
    // refresh the fable window, which only this fetcher provides
    guard let limits = readJSONObject(Monitor.limitsFile) else { return false }
    return nowMs() - (limits["oauth_updated_at"] as? Int ?? 0) < maxAgeMs
}

private func credentialsJSON() -> [String: Any]? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
       let data = item as? Data,
       let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    {
        return obj
    }
    return readJSONObject(Monitor.claudeDir.appendingPathComponent(".credentials.json"))
}

private func fetchUsage(token: String) -> [String: Any]? {
    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

    var result: [String: Any]?
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        defer { done.signal() }
        guard
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        result = obj
    }.resume()
    done.wait()
    return result
}

private func epochSeconds(_ value: Any?) -> Any {
    guard let s = value as? String else { return NSNull() }
    let iso = ISO8601DateFormatter()
    if let d = iso.date(from: s) { return Int(d.timeIntervalSince1970.rounded()) }
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: s) { return Int(d.timeIntervalSince1970.rounded()) }
    return NSNull()
}

private func convertWindow(_ value: Any?) -> Any {
    guard let w = value as? [String: Any], let used = w["utilization"] as? Double else {
        return NSNull()
    }
    return ["used_percentage": used, "resets_at": epochSeconds(w["resets_at"])]
}

func runUsage() {
    if isFresh() { return }

    guard let creds = credentialsJSON() else { return }
    let oauth = creds["claudeAiOauth"] as? [String: Any] ?? creds
    guard let token = oauth["accessToken"] as? String else { return }
    if let expires = oauth["expiresAt"] as? Double, expires < Double(nowMs()) { return }

    guard let data = fetchUsage(token: token) else { return }

    // The weekly Fable limit only appears in the limits[] array, as a
    // model-scoped weekly window.
    let fable = (data["limits"] as? [[String: Any]] ?? []).first { limit in
        guard limit["kind"] as? String == "weekly_scoped" else { return false }
        let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
        return model?.range(of: "fable", options: .caseInsensitive) != nil
    }

    var out: [String: Any] = [
        "five_hour": convertWindow(data["five_hour"]),
        "seven_day": convertWindow(data["seven_day"]),
        "seven_day_fable": NSNull(),
        "source": "oauth",
        "updated_at": nowMs(),
        // the statusline refreshes updated_at without fable data; hooks use
        // this stamp to know when a new OAuth fetch is due
        "oauth_updated_at": nowMs(),
    ]
    if let fable, let pct = fable["percent"] as? Double {
        out["seven_day_fable"] = [
            "used_percentage": pct,
            "resets_at": epochSeconds(fable["resets_at"]),
        ]
    }
    if out["five_hour"] is NSNull && out["seven_day"] is NSNull { return }

    atomicWriteJSON(out, to: Monitor.limitsFile)
}
