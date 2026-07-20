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
    static let oauthBeta = "oauth-2025-04-20"
    static let keychainService = "Claude Code-credentials"
    static let refreshInterval: TimeInterval = 60          // seconds between polls
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

enum Keychain {
    static func readClaudeCredentials() -> Result<Credentials, String> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
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
        let json = try? JSONSerialization.jsonObject(with: data)
        guard let tokenAny = findValue(json, key: "accessToken"),
              let token = tokenAny as? String, !token.isEmpty else {
            return .failure("Couldn't find accessToken in credentials.")
        }
        var expires: Date? = nil
        if let expMs = asDouble(findValue(json, key: "expiresAt")) {
            // Stored as epoch milliseconds.
            expires = Date(timeIntervalSince1970: expMs / 1000.0)
        }
        return .success(Credentials(accessToken: token, expiresAt: expires))
    }
}

// MARK: - Usage model

struct Bucket {
    let utilization: Double     // 0–100
    let resetsAt: Date?
}

struct Usage {
    let session: Bucket?        // five_hour
    let weekly: Bucket?         // seven_day
    let weeklyOpus: Bucket?     // seven_day_opus
    let fetchedAt: Date
}

enum UsageError: Error { case http(Int, String), transport(String), parse(String) }

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
    req.timeoutInterval = 20
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
            return .failure(.http(http.statusCode, String(body.prefix(200))))
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

/// A compact two-bar gauge (left = session, right = weekly) for the menu bar.
func gaugeImage(session: Double?, weekly: Double?) -> NSImage {
    let size = NSSize(width: 16, height: 15)
    let img = NSImage(size: size)
    img.lockFocus()
    let barW: CGFloat = 5, gap: CGFloat = 3, padY: CGFloat = 1
    let usableH = size.height - padY * 2
    let bars: [(Double?, CGFloat)] = [(session, 1), (weekly, 1 + barW + gap)]
    for (pct, x) in bars {
        // Track
        let track = NSBezierPath(roundedRect: NSRect(x: x, y: padY, width: barW, height: usableH),
                                 xRadius: 1.5, yRadius: 1.5)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.4).setFill()
        track.fill()
        // Fill
        let p = max(0, min(100, pct ?? 0)) / 100.0
        let h = max(usableH * CGFloat(p), p > 0 ? 1.5 : 0)
        if h > 0 {
            let fill = NSBezierPath(roundedRect: NSRect(x: x, y: padY, width: barW, height: h),
                                    xRadius: 1.5, yRadius: 1.5)
            colorFor(pct ?? 0).setFill()
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
    private var timer: Timer?
    private var lastError: String?
    private var lastUsage: Usage?
    private var notifiedLevel: [String: Double] = ["Session": 0, "Weekly": 0]
    private var notifyEnabled = UserDefaults.standard.object(forKey: "notifyEnabled") as? Bool ?? true

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Claude …"
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Config.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func refresh() {
        switch Keychain.readClaudeCredentials() {
        case .failure(let msg):
            lastError = msg
            lastUsage = nil
            render()
        case .success(let creds):
            if let exp = creds.expiresAt, exp < Date() {
                lastError = "Token expired — run Claude Code once to refresh."
                render()
                return
            }
            Task {
                let result = await fetchUsage(creds)
                await MainActor.run {
                    switch result {
                    case .success(let u):
                        self.lastUsage = u
                        self.lastError = nil
                    case .failure(let e):
                        switch e {
                        case .http(401, _): self.lastError = "Auth rejected (401) — run Claude Code to refresh."
                        case .http(let c, let b): self.lastError = "HTTP \(c): \(b)"
                        case .transport(let m): self.lastError = "Network: \(m)"
                        case .parse(let m): self.lastError = m
                        }
                    }
                    self.render()
                }
            }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        if let u = lastUsage {
            let s = u.session?.utilization
            let w = u.weekly?.utilization
            button.image = gaugeImage(session: s, weekly: w)
            button.imagePosition = .imageLeading
            maybeNotify("Session", s)
            maybeNotify("Weekly", w)
            let title = NSMutableAttributedString()
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            func seg(_ label: String, _ pct: Double?) -> NSAttributedString {
                let text = pct == nil ? "\(label) —" : "\(label) \(Int(pct!.rounded()))%"
                return NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: colorFor(pct ?? 0),
                ])
            }
            title.append(seg("S", s))
            title.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            title.append(seg("W", w))
            button.attributedTitle = title
        } else {
            button.image = nil
            button.attributedTitle = NSAttributedString(string: "Claude ⚠︎", attributes: [
                .foregroundColor: NSColor.systemRed,
            ])
        }
        rebuildMenu()
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
            addRow("Updated \(fmt.string(from: u.fetchedAt))")
        } else if let err = lastError {
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
