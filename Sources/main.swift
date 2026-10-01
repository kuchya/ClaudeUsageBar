// ClaudeUsageBar — a macOS status-bar indicator for Claude session & weekly limits.
//
// Reads the OAuth token that Claude Code stores in your macOS Keychain
// ("Claude Code-credentials") and calls the same endpoint the CLI's /usage
// panel uses:  GET https://api.anthropic.com/api/oauth/usage
//
// No third-party dependencies. AppKit + Foundation + Security only.

import AppKit
import Foundation
import QuartzCore
import ServiceManagement
import UserNotifications

// MARK: - Config

enum Config {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
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

struct Bucket: Codable {
    let utilization: Double     // 0–100
    let resetsAt: Date?
}

struct ModelLimit: Codable { let name: String; let percent: Double; let resetsAt: Date? }
struct SurfaceShare: Codable { let name: String; let percent: Double }

struct Usage: Codable {
    let session: Bucket?            // five_hour
    let weekly: Bucket?             // seven_day
    let modelLimits: [ModelLimit]?  // per-model weekly caps (from limits[] scope.model)
    let breakdown: [SurfaceShare]?  // seven_day_breakdown rows (Claude Code / Chats / …)
    let overageCostUSD: Double?     // spend.used, when pay-per-use is active
    let fetchedAt: Date
}

/// Holds the last raw usage payload so the "Copy usage data" debug item can
/// surface it (handy for nailing fields like overage that vary by account).
enum DebugStore { static var lastUsageJSON: String? }

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

/// Where the usage readout appears: the menu bar, or the MacBook notch.
enum DisplayMode: String {
    case menuBar, notch
    static var current: DisplayMode {
        get { DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .menuBar }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "displayMode") }
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

/// Parse a timestamp that may be epoch seconds/ms or an ISO-8601 string with up
/// to microsecond precision and a "+00:00" offset (as the usage API returns).
func parseDate(_ v: Any?) -> Date? {
    if let epoch = asDouble(v) { return Date(timeIntervalSince1970: epoch > 1e12 ? epoch / 1000.0 : epoch) }
    guard let s = v as? String else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: s) { return d }
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: s) { return d }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
    for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX",
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"] {
        f.dateFormat = fmt
        if let d = f.date(from: s) { return d }
    }
    return nil
}

func parseBucket(_ dict: [String: Any]?) -> Bucket? {
    guard let dict = dict else { return nil }
    let util = asDouble(dict["utilization"]) ?? asDouble(dict["percent"])
    guard let u = util else { return nil }
    return Bucket(utilization: u, resetsAt: parseDate(dict["resets_at"] ?? dict["reset_at"] ?? dict["resetsAt"]))
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
        DebugStore.lastUsageJSON = String(data: data, encoding: .utf8)
        let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let usage = Usage(
            session: parseBucket(top?["five_hour"] as? [String: Any]),
            weekly: parseBucket(top?["seven_day"] as? [String: Any]),
            modelLimits: parseModelLimits(top),
            breakdown: parseBreakdown(top),
            overageCostUSD: parseSpendUSD(top),
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

/// Per-model weekly caps from `limits[]` entries that carry a `scope.model`.
func parseModelLimits(_ top: [String: Any]?) -> [ModelLimit]? {
    guard let limits = top?["limits"] as? [Any] else { return nil }
    var out: [ModelLimit] = []
    for case let l as [String: Any] in limits {
        guard let scope = l["scope"] as? [String: Any],
              let model = scope["model"] as? [String: Any],
              let name = model["display_name"] as? String else { continue }
        out.append(ModelLimit(name: name, percent: asDouble(l["percent"]) ?? 0, resetsAt: parseDate(l["resets_at"])))
    }
    return out.isEmpty ? nil : out
}

/// Weekly usage split by surface (Claude Code / Chats / …) from seven_day_breakdown.
func parseBreakdown(_ top: [String: Any]?) -> [SurfaceShare]? {
    guard let bd = top?["seven_day_breakdown"] as? [String: Any],
          let rows = bd["rows"] as? [Any] else { return nil }
    var out: [SurfaceShare] = []
    for case let r as [String: Any] in rows {
        if let name = r["display_name"] as? String, let pct = asDouble(r["percent"]) {
            out.append(SurfaceShare(name: name, percent: pct))
        }
    }
    return out.isEmpty ? nil : out
}

/// Pay-per-use spend in USD from the `spend` object — nil unless it's enabled or
/// money has actually been spent (so the "Overage" line only shows when relevant).
func parseSpendUSD(_ top: [String: Any]?) -> Double? {
    guard let spend = top?["spend"] as? [String: Any] else { return nil }
    let enabled = (spend["enabled"] as? Bool) ?? false
    var usd = 0.0
    if let used = spend["used"] as? [String: Any], let minor = asDouble(used["amount_minor"]) {
        usd = minor / pow(10.0, asDouble(used["exponent"]) ?? 2)
    }
    return (enabled || usd > 0) ? usd : nil
}

/// One-time lookup of the signed-in Claude account email (shown in the menu).
func fetchAccountEmail(_ token: String) async -> String? {
    var req = URLRequest(url: Config.profileURL)
    req.timeoutInterval = Config.requestTimeout
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(Config.oauthBeta, forHTTPHeaderField: "anthropic-beta")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    let json = try? JSONSerialization.jsonObject(with: data)
    return (findValue(json, key: "email") as? String)
        ?? (findValue(json, key: "email_address") as? String)
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

/// Text color for the notch panel (always dark background → normal range is near-white).
func notchColor(_ pct: Double) -> NSColor {
    if pct >= Config.critThreshold { return .systemRed }
    if pct >= Config.warnThreshold { return .systemOrange }
    return NSColor(white: 0.95, alpha: 1)
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

// MARK: - Notch view (vendored, no dependencies)

/// Draws a black, bottom-rounded panel that visually extends the MacBook notch,
/// showing a compact readout when idle and a detailed one on hover.
final class NotchView: NSView {
    var usage: Usage?
    var message: String?
    var expanded = false
    var notchInset: CGFloat = 32          // height of the real cutout; content is drawn below it
    var onClick: (() -> Void)?

    override var isFlipped: Bool { false }
    override func mouseDown(with e: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let r: CGFloat = 13
        // Panel: square top (flush with the screen edge), rounded bottom.
        let p = NSBezierPath()
        p.move(to: NSPoint(x: b.minX, y: b.maxY))
        p.line(to: NSPoint(x: b.maxX, y: b.maxY))
        p.line(to: NSPoint(x: b.maxX, y: b.minY + r))
        p.appendArc(withCenter: NSPoint(x: b.maxX - r, y: b.minY + r), radius: r,
                    startAngle: 0, endAngle: -90, clockwise: true)
        p.line(to: NSPoint(x: b.minX + r, y: b.minY))
        p.appendArc(withCenter: NSPoint(x: b.minX + r, y: b.minY + r), radius: r,
                    startAngle: -90, endAngle: -180, clockwise: true)
        p.close()
        NSColor.black.setFill()
        p.fill()

        // Content area sits below the physical cutout.
        let content = NSRect(x: b.minX, y: b.minY, width: b.width, height: b.maxY - notchInset - b.minY)
        guard let u = usage else {
            drawCentered(message ?? "Claude …", in: content,
                         font: .systemFont(ofSize: 11), color: NSColor(white: 0.7, alpha: 1))
            return
        }
        let s = u.session?.utilization, w = u.weekly?.utilization
        if expanded {
            let overage = u.overageCostUSD.flatMap { $0 > 0 ? $0 : nil }
            let rows = overage != nil ? 3 : 2
            let rh = content.height / CGFloat(rows)
            func zone(_ i: Int) -> NSRect {   // i = 0 is the top row
                NSRect(x: content.minX + 18, y: content.maxY - rh * CGFloat(i + 1),
                       width: content.width - 36, height: rh - 2)
            }
            drawRow("Session", s, u.session?.resetsAt, in: zone(0))
            drawRow("Weekly", w, u.weekly?.resetsAt, in: zone(1))
            if let o = overage {
                let line = NSMutableAttributedString(string: "Overage   ", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(white: 0.85, alpha: 1)])
                line.append(NSAttributedString(string: String(format: "$%.2f", o), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.systemOrange]))
                let z = zone(2)
                line.draw(at: NSPoint(x: z.minX, y: z.minY + (z.height - line.size().height) / 2))
            }
        } else {
            let img = gaugeImage(session: s, weekly: w)
            img.draw(in: NSRect(x: content.minX + 18, y: content.midY - 7.5, width: 16, height: 15))
            let f = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            let line = NSMutableAttributedString()
            line.append(seg("S", s, f))
            line.append(NSAttributedString(string: "   ", attributes: [.font: f]))
            line.append(seg("W", w, f))
            line.draw(at: NSPoint(x: content.minX + 42, y: content.midY - line.size().height / 2))
        }
    }

    private func seg(_ label: String, _ pct: Double?, _ font: NSFont) -> NSAttributedString {
        let text = pct == nil ? "\(label) —" : "\(label) \(Int(pct!.rounded()))%"
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: notchColor(pct ?? 0)])
    }
    private func drawRow(_ label: String, _ pct: Double?, _ reset: Date?, in rect: NSRect) {
        let row = NSMutableAttributedString()
        row.append(NSAttributedString(string: "\(label)   ", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(white: 0.85, alpha: 1)]))
        row.append(NSAttributedString(string: pct == nil ? "—" : "\(Int(pct!.rounded()))%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: notchColor(pct ?? 0)]))
        if let cd = shortCountdown(reset) {
            row.append(NSAttributedString(string: "    \(cd)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor(white: 0.6, alpha: 1)]))
        }
        row.draw(at: NSPoint(x: rect.minX, y: rect.minY + (rect.height - row.size().height) / 2))
    }
    private func drawCentered(_ s: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let sz = a.size()
        a.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
    }
}

/// Owns the borderless notch window with a Coucou-style three-state model:
/// `hidden` (nothing drawn — boringNotch keeps the idle notch), `peek` (compact,
/// on hover), `expanded` (full rows, after a short dwell or click). Hover is
/// detected with a passive global mouse monitor, so nothing is intercepted or
/// drawn until the cursor actually reaches the notch.
final class NotchController {
    enum State { case hidden, peek, expanded }

    private var window: NSPanel?
    let view = NotchView()
    private(set) var active = false
    private var state: State = .hidden
    private var dwell: Timer?
    private var globalMon: Any?
    private var localMon: Any?
    var onClick: (() -> Void)? { didSet { view.onClick = onClick } }

    // MARK: geometry
    private func screen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }
    private func inset(_ s: NSScreen) -> CGFloat { s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top : 0 }
    private func notchWidth(_ s: NSScreen) -> CGFloat {
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea, r.minX > l.maxX {
            return r.minX - l.maxX
        }
        return 200
    }
    private func frame(_ width: CGFloat, _ height: CGFloat, _ s: NSScreen) -> NSRect {
        NSRect(x: s.frame.midX - width / 2, y: s.frame.maxY - height, width: width, height: height)
    }
    /// The trigger zone while hidden: the notch cutout plus a little margin below.
    private func hiddenZone(_ s: NSScreen) -> NSRect {
        let w = notchWidth(s) + 16, h = inset(s) + 8
        return frame(w, h, s)
    }
    private func hiddenFrame(_ s: NSScreen) -> NSRect { frame(max(notchWidth(s), 120), max(inset(s), 2), s) }
    private func peekFrame(_ s: NSScreen) -> NSRect { frame(max(notchWidth(s), 196), inset(s) + 20, s) }
    private func expandedFrame(_ s: NSScreen) -> NSRect {
        let extra: CGFloat = (view.usage?.overageCostUSD ?? 0) > 0 ? 24 : 0   // room for overage row
        return frame(max(notchWidth(s) + 96, 300), inset(s) + 72 + extra, s)
    }

    // MARK: lifecycle
    func activate() {
        guard !active else { return }
        active = true
        buildWindow()
        globalMon = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.onMove() }
        localMon = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in self?.onMove(); return e }
    }
    func deactivate() {
        guard active else { return }
        active = false
        dwell?.invalidate(); dwell = nil
        [globalMon, localMon].forEach { if let m = $0 { NSEvent.removeMonitor(m) } }
        globalMon = nil; localMon = nil
        window?.orderOut(nil)
        state = .hidden
    }
    func reposition() { if active, state != .hidden { enter(state, animate: false) } }

    func update(_ u: Usage?, message: String?) {
        view.usage = u; view.message = message
        if state != .hidden {
            if state == .expanded, let s = screen() { setFrame(expandedFrame(s), true) }  // refit if overage appeared
            view.needsDisplay = true
        }
    }

    private func buildWindow() {
        guard window == nil, let s = screen() else { return }
        let w = NSPanel(contentRect: hiddenFrame(s), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.contentView = view
        window = w
    }

    // MARK: hover state machine
    private func onMove() {
        guard active, let s = screen() else { return }
        let p = NSEvent.mouseLocation
        switch state {
        case .hidden:
            if hiddenZone(s).contains(p) { enter(.peek) }
        case .peek, .expanded:
            let z = (window?.frame ?? .zero).insetBy(dx: -8, dy: -8)
            if !z.contains(p) { enter(.hidden) }
        }
    }

    private func enter(_ s: State, animate: Bool = true) {
        guard let scr = screen(), let w = window else { return }
        dwell?.invalidate(); dwell = nil
        state = s
        view.notchInset = inset(scr)
        switch s {
        case .hidden:
            view.expanded = false
            let go = { w.animator().setFrame(self.hiddenFrame(scr), display: true) }
            NSAnimationContext.runAnimationGroup({
                $0.duration = animate ? 0.13 : 0
                $0.timingFunction = CAMediaTimingFunction(name: .easeIn)
                go()
            }, completionHandler: { if self.state == .hidden { w.orderOut(nil) } })
        case .peek:
            view.expanded = false
            if !w.isVisible { w.setFrame(hiddenFrame(scr), display: false); w.orderFrontRegardless() }
            setFrame(peekFrame(scr), animate)
            dwell = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                if self?.state == .peek { self?.enter(.expanded) }
            }
        case .expanded:
            view.expanded = true
            w.orderFrontRegardless()
            setFrame(expandedFrame(scr), animate)
        }
        view.needsDisplay = true
    }

    private func setFrame(_ f: NSRect, _ animate: Bool) {
        guard let w = window else { return }
        if animate {
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0.22
                $0.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.35, 0.5, 1)  // gentle spring overshoot
                w.animator().setFrame(f, display: true)
            }
        } else {
            w.setFrame(f, display: true)
        }
    }
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
    private var accountEmail: String? = UserDefaults.standard.string(forKey: "accountEmail")
    private let notch = NotchController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Claude …"
        notch.onClick = { [weak self] in self?.showMenuFromNotch() }
        // Keep the notch panel correctly placed across display changes / notch moves.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            if DisplayMode.current == .notch { self?.notch.reposition() }
        }
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
        switch Keychain.readClaudeCredentials() {
        case .failure(let msg):
            setError(msg)
            scheduleNext(after: Config.refreshInterval)
            render()
        case .success(let creds):
            if let exp = creds.expiresAt, exp < Date() {
                setError("Token expired — run Claude Code once to refresh.")
                scheduleNext(after: Config.refreshInterval)
                render()
                return
            }
            fetching = true
            Task {
                let result = await fetchUsage(creds)
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
                        self.fetchEmailIfNeeded(creds.accessToken)
                    case .failure(let e):
                        self.handleFetchError(e)
                    }
                    self.render()
                }
            }
        }
    }

    /// Route an error to blank-bar vs keep-stale, and decide the next retry delay.
    private func handleFetchError(_ e: UsageError) {
        var msg: String
        var wait: TimeInterval
        switch e {
        case .http(401, _, _):
            msg = "Auth rejected (401) — run Claude Code to refresh."
            wait = Config.refreshInterval           // a keychain re-read next cycle may fix it
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

    /// Fetch the account email once and cache it (shown in the menu).
    private func fetchEmailIfNeeded(_ token: String) {
        guard accountEmail == nil else { return }
        Task {
            guard let email = await fetchAccountEmail(token) else { return }
            await MainActor.run {
                self.accountEmail = email
                UserDefaults.standard.set(email, forKey: "accountEmail")
                self.render()
            }
        }
    }

    @objc func copyDebug() {
        let text = DebugStore.lastUsageJSON ?? "No usage payload captured yet."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func render() {
        guard let button = statusItem.button else { return }

        if DisplayMode.current == .notch {
            // Notch owns the readout (hidden until you hover it); the status item
            // shrinks to just a clickable gauge icon so settings stay reachable.
            notch.activate()
            notch.update(lastUsage, message: transientError ?? noDataError)
            button.image = gaugeImage(session: lastUsage?.session?.utilization,
                                      weekly: lastUsage?.weekly?.utilization)
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            rebuildMenu()
            return
        }
        notch.deactivate()

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

    private func rebuildMenu() { statusItem.menu = makeMenu() }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        func addRow(_ text: String, color: NSColor? = nil) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            if let c = color {
                item.attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: c])
            }
            menu.addItem(item)
        }

        if let email = accountEmail {
            addRow(email, color: .secondaryLabelColor)
            menu.addItem(.separator())
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
            for m in (u.modelLimits ?? []) where m.percent > 0 {
                addRow("Weekly (\(m.name)):  \(Int(m.percent.rounded()))%", color: colorFor(m.percent))
            }
            if let cost = u.overageCostUSD {
                addRow(String(format: "Overage spend:  $%.2f", cost), color: .systemOrange)
            }
            if let bd = u.breakdown, bd.contains(where: { $0.percent > 0 }) {
                addRow("This week, by surface:")
                for s in bd where s.percent > 0 {
                    addRow("     \(s.name):  \(Int(s.percent.rounded()))%")
                }
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

        let notchItem = NSMenuItem(title: "Show in Notch", action: #selector(toggleDisplayMode), keyEquivalent: "")
        notchItem.target = self
        notchItem.state = DisplayMode.current == .notch ? .on : .off
        menu.addItem(notchItem)

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let copyItem = NSMenuItem(title: "Copy usage data (debug)", action: #selector(copyDebug), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc func toggleDisplayMode() {
        DisplayMode.current = (DisplayMode.current == .notch) ? .menuBar : .notch
        render()
    }

    /// Pop up the same menu from the notch panel, so settings stay reachable in notch mode.
    private func showMenuFromNotch() {
        let menu = makeMenu()
        if let v = notch.view.window?.contentView {
            menu.popUp(positioning: nil, at: NSPoint(x: v.bounds.midX, y: 0), in: v)
        }
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
