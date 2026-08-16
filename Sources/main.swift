// ClaudeUsageBar — a macOS status-bar indicator for Claude session & weekly limits.
//
// Reads the OAuth token that Claude Code stores in your macOS Keychain
// ("Claude Code-credentials") and calls the same endpoint the CLI's /usage
// panel uses:  GET https://api.anthropic.com/api/oauth/usage
//
// No third-party dependencies. AppKit + Foundation + Security only.

import AppKit
import Foundation
import ServiceManagement
import UserNotifications

// MARK: - Config

enum Config {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"   // Claude Code OAuth client
    static let refreshLead: TimeInterval = 120     // refresh this many seconds before expiry
    static let oauthBeta = "oauth-2025-04-20"
    static let keychainService = "Claude Code-credentials"
    // The /api/oauth/usage endpoint is itself rate-limited, so poll gently.
    // Countdowns still tick every displayTick locally (no network) because
    // resets_at is an absolute time — utilization changes slowly anyway.
    static let refreshInterval: TimeInterval = 300         // base seconds between NETWORK polls
    static let displayTick: TimeInterval = 60              // local re-render cadence (no network)
    static let maxBackoff: TimeInterval = 1800             // cap error backoff at 30 min
    static let requestTimeout: TimeInterval = 15
    static let warnThreshold = 70.0                        // % -> orange
    static let critThreshold = 90.0                        // % -> red
    static let notifyThresholds = [80.0, 90.0, 100.0]      // alert when crossed upward
}

// MARK: - Recursive JSON helpers
// The exact nesting of the token blob and the usage response can shift between
// versions, so we search the decoded tree by key instead of hard-coding paths.

func findValue(_ obj: Any?, key: String) -> Any? {
    guard let obj = obj else { return nil }
    if let dict = obj as? [String: Any] {
        if let v = dict[key] { return v }
        for (_, v) in dict {
            if let found = findValue(v, key: key) { return found }
        }
    } else if let arr = obj as? [Any] {
        for v in arr {
            if let found = findValue(v, key: key) { return found }
        }
    }
    return nil
}

func findDict(_ obj: Any?, key: String) -> [String: Any]? {
    findValue(obj, key: key) as? [String: Any]
}

func asDouble(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

// MARK: - Keychain

extension String: @retroactive Error {}   // lets us use Result<_, String> for simple messages

struct Credentials {
    let accessToken: String
    let expiresAt: Date?
}

/// The full credential blob, kept so we can refresh the token and write it back.
struct StoredCreds {
    var raw: [String: Any]       // full top-level JSON object as stored
    var innerKey: String?        // "claudeAiOauth" wrapper key, or nil if fields are top-level
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: [String]
}

struct RefreshResult {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
}

enum Keychain {
    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Config.keychainService]
    }

    static func read() -> Result<StoredCreds, String> {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return .failure("Not signed in — no Claude Code credentials in Keychain.")
        }
        if status == errSecUserCanceled || status == errSecAuthFailed {
            return .failure("Keychain access denied. Click “Always Allow” when prompted.")
        }
        guard status == errSecSuccess, let data = item as? Data else {
            return .failure("Keychain error (\(status)).")
        }
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure("Couldn't parse credentials.")
        }
        var inner = top
        var innerKey: String? = nil
        if let wrapped = top["claudeAiOauth"] as? [String: Any] {
            inner = wrapped; innerKey = "claudeAiOauth"
        }
        guard let token = inner["accessToken"] as? String, !token.isEmpty else {
            return .failure("Couldn't find accessToken in credentials.")
        }
        var expires: Date? = nil
        if let expMs = asDouble(inner["expiresAt"]) {
            expires = Date(timeIntervalSince1970: expMs / 1000.0)   // stored as epoch ms
        }
        return .success(StoredCreds(
            raw: top, innerKey: innerKey,
            accessToken: token,
            refreshToken: inner["refreshToken"] as? String,
            expiresAt: expires,
            scopes: (inner["scopes"] as? [String]) ?? []))
    }

    /// Write refreshed tokens back into the same item (value-only update preserves
    /// the ACL, so both this app and Claude Code stay authorized and in sync).
    @discardableResult
    static func write(_ creds: StoredCreds) -> Bool {
        var top = creds.raw
        var inner: [String: Any] = creds.innerKey.flatMap { top[$0] as? [String: Any] } ?? top
        inner["accessToken"] = creds.accessToken
        if let rt = creds.refreshToken { inner["refreshToken"] = rt }
        if let e = creds.expiresAt { inner["expiresAt"] = e.timeIntervalSince1970 * 1000.0 }
        if let k = creds.innerKey { top[k] = inner } else { top = inner }
        guard let data = try? JSONSerialization.data(withJSONObject: top) else { return false }
        let status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        return status == errSecSuccess
    }

    /// Exchange the refresh token for a fresh access token (OAuth refresh grant).
    static func refresh(_ creds: StoredCreds) async -> Result<RefreshResult, String> {
        guard let rt = creds.refreshToken, !rt.isEmpty else {
            return .failure("no refresh token stored")
        }
        var req = URLRequest(url: Config.tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = Config.requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": rt,
            "client_id": Config.clientID,
        ]
        if !creds.scopes.isEmpty { body["scope"] = creds.scopes.joined(separator: " ") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failure("no HTTP response") }
            guard http.statusCode == 200 else {
                let b = String(data: data, encoding: .utf8) ?? ""
                return .failure("token endpoint HTTP \(http.statusCode): \(String(b.prefix(120)))")
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let newAT = json["access_token"] as? String, !newAT.isEmpty else {
                return .failure("malformed token response")
            }
            var expires: Date? = nil
            if let secs = asDouble(json["expires_in"]) {
                expires = Date(timeIntervalSinceNow: secs)
            } else if let ms = asDouble(json["expires_at"]) {
                expires = Date(timeIntervalSince1970: ms > 1e12 ? ms / 1000.0 : ms)
            }
            return .success(RefreshResult(accessToken: newAT,
                                          refreshToken: json["refresh_token"] as? String,
                                          expiresAt: expires))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

// MARK: - Usage model

struct Bucket: Codable {
    let utilization: Double     // 0–100
    let resetsAt: Date?
}

struct Usage: Codable {
    let session: Bucket?        // five_hour
    let weekly: Bucket?         // seven_day
    let weeklyOpus: Bucket?     // seven_day_opus
    let fetchedAt: Date
}

/// Persist the last successful reading so it survives relaunches — a cold start
/// that immediately gets rate-limited can still show the last known values.
enum Store {
    static let key = "lastUsage.v1"
    static func save(_ u: Usage) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(u) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func load() -> Usage? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Usage.self, from: d)
    }
}

enum UsageError: Error {
    case http(Int, String, retryAfter: TimeInterval?)
    case transport(String)
    case parse(String)
}

/// Parse a Retry-After header (delta seconds or HTTP date) into seconds from now.
func parseRetryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
    guard let v = http.value(forHTTPHeaderField: "Retry-After")?
        .trimmingCharacters(in: .whitespaces) else { return nil }
    if let secs = Double(v) { return max(0, secs) }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "GMT")
    fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let d = fmt.date(from: v) { return max(0, d.timeIntervalSinceNow) }
    return nil
}

func parseBucket(_ dict: [String: Any]?) -> Bucket? {
    guard let dict = dict else { return nil }
    // utilization is a percent; some payloads call it "percent".
    let util = asDouble(dict["utilization"]) ?? asDouble(dict["percent"])
    guard let u = util else { return nil }
    var reset: Date? = nil
    if let r = dict["resets_at"] ?? dict["reset_at"] ?? dict["resetsAt"] {
        if let epoch = asDouble(r) {
            // Heuristic: ms vs s.
            reset = Date(timeIntervalSince1970: epoch > 1e12 ? epoch / 1000.0 : epoch)
        } else if let s = r as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            reset = iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
    }
    return Bucket(utilization: u, resetsAt: reset)
}

func fetchUsage(_ creds: Credentials) async -> Result<Usage, UsageError> {
    var req = URLRequest(url: Config.usageURL)
    req.httpMethod = "GET"
    req.timeoutInterval = Config.requestTimeout
    req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
    req.setValue(Config.oauthBeta, forHTTPHeaderField: "anthropic-beta")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("ClaudeUsageBar/1.0", forHTTPHeaderField: "User-Agent")

    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            return .failure(.transport("No HTTP response"))
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            return .failure(.http(http.statusCode, String(body.prefix(200)),
                                  retryAfter: parseRetryAfter(http)))
        }
        let json = try? JSONSerialization.jsonObject(with: data)
        let usage = Usage(
            session: parseBucket(findDict(json, key: "five_hour")),
            weekly: parseBucket(findDict(json, key: "seven_day")),
            weeklyOpus: parseBucket(findDict(json, key: "seven_day_opus")),
            fetchedAt: Date()
        )
        if usage.session == nil && usage.weekly == nil {
            let body = String(data: data, encoding: .utf8) ?? ""
            return .failure(.parse("Unrecognized usage payload: \(String(body.prefix(200)))"))
        }
        return .success(usage)
    } catch {
        return .failure(.transport(error.localizedDescription))
    }
}

// MARK: - Formatting

func relativeReset(_ date: Date?) -> String {
    guard let date = date else { return "" }
    let secs = date.timeIntervalSinceNow
    if secs <= 0 { return "resetting…" }
    let h = Int(secs) / 3600
    let m = (Int(secs) % 3600) / 60
    if h >= 24 { let d = h / 24; return "resets in \(d)d \(h % 24)h" }
    if h > 0 { return "resets in \(h)h \(m)m" }
    return "resets in \(m)m"
}

func colorFor(_ pct: Double) -> NSColor {
    if pct >= Config.critThreshold { return .systemRed }
    if pct >= Config.warnThreshold { return .systemOrange }
    return .labelColor
}

/// Gauge fill color. Unlike `colorFor`, the normal range uses an opaque green
/// instead of the adaptive `labelColor` — the gauge is a baked bitmap that
/// doesn't track the menu-bar appearance, so an adaptive color would bake to
/// black and disappear on a dark menu bar.
func gaugeColor(_ pct: Double) -> NSColor {
    if pct >= Config.critThreshold { return .systemRed }
    if pct >= Config.warnThreshold { return .systemOrange }
    return .systemGreen
}

/// Compact reset countdown for the menu bar, e.g. "1h20m", "2d3h", "45m".
func shortCountdown(_ date: Date?) -> String? {
    guard let date = date else { return nil }
    var secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "now" }
    let d = secs / 86400; secs %= 86400
    let h = secs / 3600;  secs %= 3600
    let m = secs / 60
    if d > 0 { return "\(d)d\(h)h" }
    if h > 0 { return "\(h)h\(m)m" }
    return "\(m)m"
}

/// A compact two-bar gauge (left = session, right = weekly) for the menu bar.
func gaugeImage(session: Double?, weekly: Double?) -> NSImage {
    let size = NSSize(width: 16, height: 15)
    let img = NSImage(size: size)
    img.lockFocus()
    let barW: CGFloat = 5, gap: CGFloat = 3, padY: CGFloat = 1
    let usableH = size.height - padY * 2
    let bars: [(Double?, CGFloat)] = [(session, 1), (weekly, 1 + barW + gap)]
    for (pct, x) in bars {
        // Track — a fixed neutral gray, visible on both light and dark menu bars.
        let track = NSBezierPath(roundedRect: NSRect(x: x, y: padY, width: barW, height: usableH),
                                 xRadius: 1.5, yRadius: 1.5)
        NSColor(white: 0.55, alpha: 0.55).setFill()
        track.fill()
        // Fill
        let p = max(0, min(100, pct ?? 0)) / 100.0
        let h = max(usableH * CGFloat(p), p > 0 ? 1.5 : 0)
        if h > 0 {
            let fill = NSBezierPath(roundedRect: NSRect(x: x, y: padY, width: barW, height: h),
                                    xRadius: 1.5, yRadius: 1.5)
            gaugeColor(pct ?? 0).setFill()
            fill.fill()
        }
    }
    img.unlockFocus()
    img.isTemplate = false
    return img
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var displayTimer: Timer?
    private var lastUsage: Usage?
    private var noDataError: String?       // nothing to show yet -> blank bar
    private var transientError: String?    // have stale data -> keep showing it, warn in menu
    private var backoff: TimeInterval = Config.refreshInterval
    private var nextFetch = Date()         // when the next network poll is due
    private var fetching = false
    private var notifiedLevel: [String: Double] = ["Session": 0, "Weekly": 0]
    private var notifyEnabled = UserDefaults.standard.object(forKey: "notifyEnabled") as? Bool ?? true

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Claude …"
        // Restore the last reading so the bar shows values immediately, even offline.
        lastUsage = Store.load()
        primeNotifyState()
        render()
        performFetch()
        // One light timer: re-render locally every tick (countdowns), fetch only when due.
        displayTimer = Timer.scheduledTimer(withTimeInterval: Config.displayTick, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        render()   // countdowns recompute from absolute resets_at — no network needed
        if !fetching && Date() >= nextFetch { performFetch() }
    }

    /// Menu "Refresh Now": clear backoff and poll immediately.
    @objc func refresh() {
        backoff = Config.refreshInterval
        nextFetch = Date()
        performFetch()
    }

    private func scheduleNext(after secs: TimeInterval) {
        nextFetch = Date().addingTimeInterval(max(secs, 5))
    }

    private func performFetch() {
        guard !fetching else { return }
        switch Keychain.read() {
        case .failure(let msg):
            setError(msg)
            scheduleNext(after: Config.refreshInterval)
            render()
        case .success(let creds):
            fetching = true
            Task {
                let result = await self.fetchRefreshing(creds)
                await MainActor.run {
                    self.fetching = false
                    switch result {
                    case .success(let u):
                        self.lastUsage = u
                        Store.save(u)
                        self.maybeNotify("Session", u.session?.utilization)
                        self.maybeNotify("Weekly", u.weekly?.utilization)
                        self.noDataError = nil
                        self.transientError = nil
                        self.backoff = Config.refreshInterval
                        self.scheduleNext(after: Config.refreshInterval)
                    case .failure(let e):
                        self.handleFetchError(e)
                    }
                    self.render()
                }
            }
        }
    }

    /// Fetch usage, transparently refreshing the OAuth token (and writing it back to
    /// the Keychain) when it's expired or the API returns 401 — no manual `claude` run.
    private func fetchRefreshing(_ initial: StoredCreds) async -> Result<Usage, UsageError> {
        var creds = initial

        func applyRefresh() async -> String? {   // returns error message, or nil on success
            switch await Keychain.refresh(creds) {
            case .success(let r):
                creds.accessToken = r.accessToken
                if let rt = r.refreshToken { creds.refreshToken = rt }
                creds.expiresAt = r.expiresAt
                Keychain.write(creds)             // keep Claude Code in sync (rotating tokens)
                return nil
            case .failure(let m):
                return m
            }
        }

        // Proactive refresh if the token is expired or about to expire.
        if let exp = creds.expiresAt, exp < Date().addingTimeInterval(Config.refreshLead) {
            if let m = await applyRefresh() {
                return .failure(.http(401, reauthMessage(m), retryAfter: nil))
            }
        }

        let first = await fetchUsage(Credentials(accessToken: creds.accessToken, expiresAt: creds.expiresAt))
        if case .failure(.http(401, _, _)) = first {
            // Access token rejected — refresh once and retry.
            if let m = await applyRefresh() {
                return .failure(.http(401, reauthMessage(m), retryAfter: nil))
            }
            return await fetchUsage(Credentials(accessToken: creds.accessToken, expiresAt: creds.expiresAt))
        }
        return first
    }

    private func reauthMessage(_ detail: String) -> String {
        "Sign-in expired — run Claude Code once to re-authenticate. (\(detail))"
    }

    /// Route an error to blank-bar vs keep-stale, and decide the next retry delay.
    private func handleFetchError(_ e: UsageError) {
        var msg: String
        var wait: TimeInterval
        switch e {
        case .http(401, let b, _):
            msg = b.isEmpty ? "Sign-in expired — run Claude Code once to re-authenticate." : b
            wait = Config.refreshInterval           // don't hammer; refresh already attempted
        case .http(429, _, let ra):
            msg = "Rate limited — backing off."
            wait = max(ra ?? 0, min(backoff, Config.maxBackoff))
            backoff = min(backoff * 2, Config.maxBackoff)
        case .http(let c, let b, let ra):
            msg = "HTTP \(c): \(b)"
            wait = max(ra ?? 0, min(backoff, Config.maxBackoff))
            backoff = min(backoff * 2, Config.maxBackoff)
        case .transport(let m):
            msg = "Network: \(m)"
            wait = min(backoff, Config.maxBackoff)
            backoff = min(backoff * 2, Config.maxBackoff)
        case .parse(let m):
            msg = m
            wait = Config.refreshInterval
        }
        setError(msg)
        scheduleNext(after: wait)
    }

    /// Keep showing stale data if we have it; otherwise the bar goes to ⚠︎.
    private func setError(_ msg: String) {
        if lastUsage != nil { transientError = msg; noDataError = nil }
        else { noDataError = msg; transientError = nil }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        if let u = lastUsage {
            let s = u.session?.utilization
            let w = u.weekly?.utilization
            button.image = gaugeImage(session: s, weekly: w)
            button.imagePosition = .imageLeading
            let title = NSMutableAttributedString()
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            func seg(_ label: String, _ bucket: Bucket?) -> NSAttributedString {
                let out = NSMutableAttributedString()
                let pct = bucket?.utilization
                let head = pct == nil ? "\(label) —" : "\(label) \(Int(pct!.rounded()))%"
                out.append(NSAttributedString(string: head, attributes: [
                    .font: font,
                    .foregroundColor: colorFor(pct ?? 0),
                ]))
                if let cd = shortCountdown(bucket?.resetsAt) {
                    // Opaque adaptive color + lighter weight/size: legible in light *and*
                    // dark menu bars (secondaryLabelColor is translucent and washes out).
                    let cdFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1.5,
                                                                  weight: .regular)
                    out.append(NSAttributedString(string: " \(cd)", attributes: [
                        .font: cdFont,
                        .foregroundColor: NSColor.labelColor,
                    ]))
                }
                return out
            }
            title.append(seg("S", u.session))
            title.append(NSAttributedString(string: "   ", attributes: [.font: font]))
            title.append(seg("W", u.weekly))
            button.attributedTitle = title
        } else {
            button.image = nil
            button.attributedTitle = NSAttributedString(string: "Claude ⚠︎", attributes: [
                .foregroundColor: NSColor.systemRed,
            ])
        }
        rebuildMenu()
    }

    /// "just now" / "3m ago" / "2h ago" for the freshness line.
    private func shortAgo(_ date: Date) -> String {
        let s = Int(max(0, Date().timeIntervalSince(date)))
        if s < 45 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    /// Seed notification levels from restored data so we don't re-alert on launch.
    private func primeNotifyState() {
        func level(_ b: Bucket?) -> Double {
            Config.notifyThresholds.filter { (b?.utilization ?? 0) >= $0 }.max() ?? 0
        }
        notifiedLevel["Session"] = level(lastUsage?.session)
        notifiedLevel["Weekly"] = level(lastUsage?.weekly)
    }

    /// Fire a notification when a bucket crosses a threshold upward; reset after the window resets.
    private func maybeNotify(_ name: String, _ pct: Double?) {
        guard notifyEnabled, let pct = pct else { return }
        let prev = notifiedLevel[name] ?? 0
        let crossed = Config.notifyThresholds.filter { pct >= $0 }.max() ?? 0
        if crossed > prev {
            let content = UNMutableNotificationContent()
            content.title = "Claude \(name) usage \(Int(crossed))%"
            content.body = "\(name) limit is at \(Int(pct.rounded()))%."
            content.sound = .default
            let req = UNNotificationRequest(identifier: "\(name)-\(Int(crossed))-\(Int(pct))",
                                            content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
            notifiedLevel[name] = crossed
        } else if pct < (Config.notifyThresholds.first ?? 80) {
            notifiedLevel[name] = 0     // window reset — allow alerts again
        }
    }

    @objc func toggleNotify() {
        notifyEnabled.toggle()
        UserDefaults.standard.set(notifyEnabled, forKey: "notifyEnabled")
        rebuildMenu()
    }

    @objc func toggleLoginItem() {
        if #available(macOS 13.0, *) {
            let svc = SMAppService.mainApp
            do {
                if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
            } catch {
                NSLog("Login item toggle failed: \(error)")
            }
            rebuildMenu()
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        func addRow(_ text: String, color: NSColor? = nil) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            if let c = color {
                item.attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: c])
            }
            menu.addItem(item)
        }

        if let u = lastUsage {
            if let b = u.session {
                addRow("Session (5h):  \(Int(b.utilization.rounded()))%", color: colorFor(b.utilization))
                if let r = relativeResetLine(b.resetsAt) { addRow("     \(r)") }
            }
            if let b = u.weekly {
                addRow("Weekly (7d):  \(Int(b.utilization.rounded()))%", color: colorFor(b.utilization))
                if let r = relativeResetLine(b.resetsAt) { addRow("     \(r)") }
            }
            if let b = u.weeklyOpus {
                addRow("Weekly Opus:  \(Int(b.utilization.rounded()))%", color: colorFor(b.utilization))
            }
            menu.addItem(.separator())
            let fmt = DateFormatter(); fmt.timeStyle = .medium
            addRow("Updated \(fmt.string(from: u.fetchedAt))  (\(shortAgo(u.fetchedAt)))")
            if let err = transientError {
                let retry = shortCountdown(nextFetch).map { " · retrying in \($0)" } ?? ""
                addRow("⚠︎ \(err)\(retry)", color: .systemOrange)
            }
        } else if let err = noDataError {
            addRow("⚠︎ \(err)", color: .systemRed)
        } else {
            addRow("Loading…")
        }

        menu.addItem(.separator())

        let notifyItem = NSMenuItem(title: "Notify at 80% / 90%", action: #selector(toggleNotify), keyEquivalent: "")
        notifyItem.target = self
        notifyItem.state = notifyEnabled ? .on : .off
        menu.addItem(notifyItem)

        if #available(macOS 13.0, *) {
            let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
            loginItem.target = self
            loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            menu.addItem(loginItem)
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func relativeResetLine(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        let rel = relativeReset(date)
        let fmt = DateFormatter(); fmt.dateFormat = "EEE HH:mm"
        return "\(rel)  (\(fmt.string(from: date)))"
    }

    @objc func quit() { NSApplication.shared.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
