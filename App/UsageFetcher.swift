import Foundation
import Security

// Fetches rate limits from Anthropic's OAuth usage endpoint and writes
// limits.json — the same job as `claudehud-emitter usage`, but run inside the
// long-lived app so the keychain token is read ONCE and cached in memory.
//
// The token is keychain-only on macOS, and the app is ad-hoc signed (its
// signature can't reliably persist an "Always Allow"). The old design spawned
// a fresh emitter process for every refresh, and each fresh process re-read
// the keychain — so every wake-from-sleep prompted for keychain access.
// Caching the token here means the keychain is touched about once per launch.
final class UsageFetcher {
    static let shared = UsageFetcher()

    private let queue = DispatchQueue(label: "se.matalve.ClaudeHUD.usage")
    private var cachedToken: String?
    private var cachedTokenExpiry: Double = 0 // epoch ms; 0 = unknown

    // Refresh limits.json if the last OAuth fetch is stale. Safe to call from
    // the main thread; the work runs on a background queue.
    func refresh() {
        queue.async { [weak self] in self?.fetchIfStale() }
    }

    private func fetchIfStale() {
        if let limits = readJSONObject(Monitor.limitsFile),
           nowMs() - (limits["oauth_updated_at"] as? Int ?? 0) < 60_000 {
            return
        }
        guard let token = token() else { return }

        guard let data = fetchUsage(token: token) else { return }
        if data.isEmpty {
            // 401/expired — drop the cached token so the next refresh re-reads
            cachedToken = nil
            return
        }
        writeLimits(from: data)
    }

    // Cached token, read from the keychain only when missing or expired.
    private func token() -> String? {
        if let t = cachedToken, cachedTokenExpiry == 0 || cachedTokenExpiry > Double(nowMs()) {
            return t
        }
        guard let creds = keychainCredentials() else { return nil }
        let oauth = creds["claudeAiOauth"] as? [String: Any] ?? creds
        guard let token = oauth["accessToken"] as? String else { return nil }
        let expiry = oauth["expiresAt"] as? Double ?? 0
        if expiry != 0, expiry < Double(nowMs()) { return nil }
        cachedToken = token
        cachedTokenExpiry = expiry
        return token
    }

    private func keychainCredentials() -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return obj
    }

    // Returns the parsed JSON, an empty dict on 401 (token invalid), or nil on
    // any other failure (don't disturb the cached token then).
    private func fetchUsage(token: String) -> [String: Any]? {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        var result: [String: Any]?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 { result = [:]; return }
            guard (200..<300).contains(http.statusCode),
                  let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }
            result = obj
        }.resume()
        done.wait()
        return result
    }

    private func writeLimits(from data: [String: Any]) {
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

    private func convertWindow(_ value: Any?) -> Any {
        guard let w = value as? [String: Any], let used = w["utilization"] as? Double else {
            return NSNull()
        }
        return ["used_percentage": used, "resets_at": epochSeconds(w["resets_at"])]
    }

    private func epochSeconds(_ value: Any?) -> Any {
        guard let s = value as? String else { return NSNull() }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return Int(d.timeIntervalSince1970.rounded()) }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return Int(d.timeIntervalSince1970.rounded()) }
        return NSNull()
    }
}
