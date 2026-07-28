// ClaudeUsageBar — a macOS menu-bar widget showing your Claude (Max plan) usage.
//
// Primary numbers come from Anthropic's /api/oauth/usage endpoint, fetched
// read-only via usage_agent.py using the Claude Code CLI's existing token
// (never refreshed here, so the CLI login is never disturbed).
//
// Which metric the menu bar shows is user-selectable (click the widget →
// "Show in menu bar"). Default is the 5-hour session window. A local cost/token
// ESTIMATE from ~/.claude transcripts is shown as a bonus.

import AppKit
import Foundation

// ------------------------------------------------------------------ Config
let PYTHON = "/usr/bin/python3"
// The /api/oauth/usage endpoint is meant for on-demand viewing and rate-limits
// aggressive polling (HTTP 429). 5-min aligned is a safe cadence; a 429 triggers
// adaptive backoff below and never greys the bar (the numbers are still recent).
let POLL_ALIGN_MINUTES = 5    // refresh at :00 :05 :10 … aligned to the hour
let RATE_LIMIT_BACKOFF: TimeInterval = 15 * 60   // wait this long after a 429

// usage_agent.py is copied into the app's Resources by build.sh — no hardcoded
// user paths. Falls back to a copy beside the executable for dev runs.
let AGENT_PATH: String = {
    if let p = Bundle.main.path(forResource: "usage_agent", ofType: "py") { return p }
    return Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources/usage_agent.py").path
}()

// ------------------------------------------------------------------ Real usage
struct Limit {
    let kind: String, label: String, short: String, severity: String
    let percent: Double
    let resetsAt: Date?
    let isActive: Bool
}
struct RealUsage {
    var ok = false, stale = false
    var authExpired = false   // signed out -> dim the bar
    var transient = false     // fetch failed (e.g. 429) but token valid -> keep colors
    var reason: String? = nil
    var fetchedAt: Date? = nil
    var limits: [Limit] = []
    var creditsUsed: Double? = nil, creditsLimit: Double? = nil, creditsPct: Int? = nil
    var rateLimited: Bool { transient && (reason?.contains("rate") ?? false) }
}

let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
}()
let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
}()
func parseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    return isoFrac.date(from: s) ?? isoPlain.date(from: s)
}

func runAgent() -> RealUsage {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: PYTHON)
    p.arguments = [AGENT_PATH]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    var out = RealUsage()
    do {
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            out.reason = "no_output"; return out
        }
        out.ok = (o["ok"] as? Bool) ?? false
        out.stale = (o["stale"] as? Bool) ?? false
        out.authExpired = (o["auth_expired"] as? Bool) ?? false
        out.transient = (o["transient"] as? Bool) ?? false
        out.reason = o["reason"] as? String
        if let ts = o["fetched_at"] as? Double { out.fetchedAt = Date(timeIntervalSince1970: ts) }
        if let ts = o["fetched_at"] as? Int { out.fetchedAt = Date(timeIntervalSince1970: Double(ts)) }
        if let arr = o["limits"] as? [[String: Any]] {
            out.limits = arr.compactMap { d in
                let pct: Double? = (d["percent"] as? Double) ?? (d["percent"] as? Int).map(Double.init)
                guard let pct = pct else { return nil }
                return Limit(kind: d["kind"] as? String ?? "",
                             label: d["label"] as? String ?? "",
                             short: d["short"] as? String ?? "",
                             severity: d["severity"] as? String ?? "normal",
                             percent: pct,
                             resetsAt: parseISO(d["resets_at"] as? String),
                             isActive: d["is_active"] as? Bool ?? false)
            }
        }
        if let c = o["credits"] as? [String: Any] {
            out.creditsUsed = c["used"] as? Double
            out.creditsLimit = c["limit"] as? Double
            out.creditsPct = c["percent"] as? Int
        }
    } catch {
        out.reason = "spawn_error"
    }
    return out
}

// ------------------------------------------------------------------ Local estimate
struct Entry { let date: Date; let model: String; let input, c5, c1, cRead, output: Int
    var total: Int { input + c5 + c1 + cRead + output } }

func basePrice(_ model: String) -> (Double, Double) {
    let m = model.lowercased()
    if m.contains("opus") { return (15, 75) }
    if m.contains("sonnet") { return (3, 15) }
    if m.contains("haiku") { return (1, 5) }
    return (3, 15)
}
func costOf(_ e: Entry) -> Double {
    let (i, o) = basePrice(e.model); let im = i/1e6, om = o/1e6
    return Double(e.input)*im + Double(e.c5)*im*1.25 + Double(e.c1)*im*2.0 + Double(e.cRead)*im*0.1 + Double(e.output)*om
}

final class LocalScanner {
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private var cache: [String: (Int, Date, [Entry])] = [:]
    func scan() -> [Entry] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var alive = Set<String>(); var all: [Entry] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let path = url.path; alive.insert(path)
            let a = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = a?.fileSize ?? -1; let m = a?.contentModificationDate ?? .distantPast
            if let c = cache[path], c.0 == size, c.1 == m { all += c.2; continue }
            let parsed = parse(url); cache[path] = (size, m, parsed); all += parsed
        }
        for k in cache.keys where !alive.contains(k) { cache.removeValue(forKey: k) }
        return all
    }
    private func parse(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [Entry] = []; var seen = Set<String>()
        text.enumerateLines { line, _ in
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let msg = o["message"] as? [String: Any],
                  let u = msg["usage"] as? [String: Any] else { return }
            let model = (msg["model"] as? String) ?? ""
            if model.isEmpty || model.contains("synthetic") { return }
            let key = ((msg["id"] as? String) ?? "") + ":" + ((o["requestId"] as? String) ?? "")
            if key != ":" { if seen.contains(key) { return }; seen.insert(key) }
            var c5 = 0, c1 = 0
            if let cc = u["cache_creation"] as? [String: Any] {
                c5 = (cc["ephemeral_5m_input_tokens"] as? Int) ?? 0
                c1 = (cc["ephemeral_1h_input_tokens"] as? Int) ?? 0
            } else { c5 = (u["cache_creation_input_tokens"] as? Int) ?? 0 }
            guard let ts = o["timestamp"] as? String, let date = parseISO(ts) else { return }
            out.append(Entry(date: date, model: model,
                             input: (u["input_tokens"] as? Int) ?? 0, c5: c5, c1: c1,
                             cRead: (u["cache_read_input_tokens"] as? Int) ?? 0,
                             output: (u["output_tokens"] as? Int) ?? 0))
        }
        return out
    }
}

// ------------------------------------------------------------------ Formatting
func fmtTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.2fM", Double(n)/1e6) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n)/1e3) }
    return "\(n)"
}
func fmtCost(_ x: Double) -> String { String(format: "$%.2f", x) }

func countdown(to date: Date?) -> String {
    guard let date = date else { return "—" }
    let s = Int(date.timeIntervalSinceNow)
    if s <= 0 { return "resetting…" }
    let d = s/86400, h = (s%86400)/3600, m = (s%3600)/60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

/// Color the number by how much of the limit is used:
///   0–33% green · 33–66% yellow · 66–90% orange · >90% red
func color(forPct pct: Double) -> NSColor {
    switch pct {
    case ..<33:  return .systemGreen
    case ..<66:  return .systemYellow
    case ..<90:  return .systemOrange
    default:     return .systemRed
    }
}

/// The status-bar button ignores attributedTitle color, so we render the text
/// into a NON-template image (template images get force-tinted monochrome).
/// Resolution-independent drawingHandler => crisp on Retina.
func menuBarImage(_ text: String, color: NSColor) -> NSImage {
    let font = NSFont.menuBarFont(ofSize: 0)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    var size = (text as NSString).size(withAttributes: attrs)
    size.width = ceil(size.width) + 2
    size.height = ceil(size.height)
    let img = NSImage(size: size, flipped: false) { _ in
        (text as NSString).draw(at: NSPoint(x: 1, y: 0), withAttributes: attrs)
        return true
    }
    img.isTemplate = false   // keep our colors; don't let the system tint it
    return img
}

// ------------------------------------------------------------------ Prefs
let METRIC_KEY = "menuBarMetric"
let METRIC_OPTIONS: [(id: String, label: String)] = [
    ("session",        "5-hour session"),
    ("weekly_all",     "7-day (all models)"),
    ("weekly_scoped",  "7-day (scoped / binding model)"),
    ("auto",           "Most-constraining (auto)"),
    ("cost",           "Today's cost (local estimate)"),
]

struct LocalTotals { var todayCost = 0.0; var todayTok = 0; var w5Cost = 0.0; var w5Tok = 0 }

// ------------------------------------------------------------------ App
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let scanner = LocalScanner()
    private var pollTimer: Timer?
    private var real = RealUsage()
    private var locals = LocalTotals()

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.register(defaults: [METRIC_KEY: "session"])   // default = 5-hour session
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✦ …"
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        poll()                 // immediate, so we don't sit on "…"
        scheduleAlignedPoll()  // then lock onto :00/:10/:20/:30/:40/:50
        // Re-align after the machine wakes from sleep (timers don't fire while asleep).
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func wake() { poll(); scheduleAlignedPoll() }

    /// Schedule the next poll at the next clock boundary that is a multiple of
    /// POLL_ALIGN_MINUTES past the hour, then re-arm from there.
    private func scheduleAlignedPoll() {
        pollTimer?.invalidate()
        let cal = Calendar.current
        let now = Date()
        let c = cal.dateComponents([.minute, .second, .nanosecond], from: now)
        let minute = c.minute ?? 0, second = c.second ?? 0
        let minsToNext = POLL_ALIGN_MINUTES - (minute % POLL_ALIGN_MINUTES)
        var secs = Double(minsToNext * 60 - second) - Double(c.nanosecond ?? 0) / 1e9
        if secs < 1 { secs += Double(POLL_ALIGN_MINUTES * 60) }   // guard the exact-boundary case
        let t = Timer(timeInterval: secs, repeats: false) { [weak self] _ in
            self?.poll()
            self?.scheduleAlignedPoll()
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private var metric: String { UserDefaults.standard.string(forKey: METRIC_KEY) ?? "session" }
    private var backoffUntil: Date?

    /// "Refresh now" — clear any backoff and fetch immediately.
    @objc private func forceRefresh() { backoffUntil = nil; poll() }

    @objc private func poll() {
        // Skip the network hit while backing off from a 429; still refresh locals.
        let fetchReal = backoffUntil.map { Date() >= $0 } ?? true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let r: RealUsage? = fetchReal ? runAgent() : nil
            let entries = self.scanner.scan()
            var lt = LocalTotals()
            let now = Date(); let cal = Calendar.current; let since5h = now.addingTimeInterval(-5*3600)
            for e in entries {
                let c = costOf(e)
                if cal.isDate(e.date, inSameDayAs: now) { lt.todayCost += c; lt.todayTok += e.total }
                if e.date >= since5h { lt.w5Cost += c; lt.w5Tok += e.total }
            }
            DispatchQueue.main.async {
                if let r = r {
                    self.real = r
                    if r.rateLimited { self.backoffUntil = Date().addingTimeInterval(RATE_LIMIT_BACKOFF) }
                    else if r.ok      { self.backoffUntil = nil }
                }
                self.locals = lt
                self.render()
            }
        }
    }

    private func limit(kind: String) -> Limit? {
        real.limits.filter { $0.kind == kind }.max(by: { $0.percent < $1.percent })
    }
    private func bindingLimit() -> Limit? { real.limits.max(by: { $0.percent < $1.percent }) }

    /// Colored menu-bar content via a non-template image (color actually shows).
    private func setBar(_ text: String, _ c: NSColor) {
        guard let btn = statusItem.button else { return }
        btn.image = menuBarImage(text, color: c)
        btn.imagePosition = .imageOnly
        btn.title = ""
    }
    /// Plain fallback (default color) for non-data states.
    private func setBarPlain(_ text: String) {
        guard let btn = statusItem.button else { return }
        btn.image = nil
        btn.title = text
    }

    private func render() {
        let choice = metric

        if choice == "cost" {
            setBar("✦ " + fmtCost(locals.todayCost), real.authExpired ? .tertiaryLabelColor : .labelColor)
            rebuildMenu(); return
        }

        // Pick the limit for the chosen metric; fall back to the binding limit if absent.
        let chosen: Limit? = {
            switch choice {
            case "session":       return limit(kind: "session")
            case "weekly_all":    return limit(kind: "weekly_all")
            case "weekly_scoped": return limit(kind: "weekly_scoped")
            default:              return bindingLimit()
            }
        }() ?? bindingLimit()

        if let lim = chosen {
            let warn = (lim.severity != "normal") ? "⚠ " : ""
            let dim = real.authExpired ? " ·" : ""   // dim only when signed out
            let title = String(format: "%@%@ %.0f%%%@", warn, lim.short, lim.percent, dim)
            setBar(title, real.authExpired ? .tertiaryLabelColor : color(forPct: lim.percent))
        } else if real.authExpired {
            setBarPlain("✦ login")
        } else {
            setBarPlain("✦ …")   // no cache yet (first run / transient) — neutral
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = statusItem.menu!
        menu.removeAllItems()
        header("Claude usage — Max plan", menu)
        menu.addItem(.separator())

        if real.limits.isEmpty {
            let msg: String
            if real.authExpired {
                msg = "Not signed in. Run  claude  →  /login  in a Terminal,\nthen this lights up automatically."
            } else if real.transient {
                msg = "Couldn’t reach the usage endpoint yet — will retry."
            } else {
                msg = "Loading…"
            }
            disabled(msg, menu)
        } else {
            for lim in real.limits.sorted(by: { $0.percent > $1.percent }) {
                let star = lim.isActive ? " ●" : ""
                headerColored(lim.label + star, color(forPct: lim.percent), menu)
                disabled(String(format: "   %.0f%% used   ·   resets in %@", lim.percent, countdown(to: lim.resetsAt)), menu)
            }
            if let used = real.creditsUsed, let lim = real.creditsLimit, lim > 0 {
                header("Extra-usage credits", menu)
                disabled(String(format: "   $%.2f of $%.2f", used, lim), menu)
            }
        }

        menu.addItem(.separator())
        header("Local estimate (from ~/.claude logs)", menu)
        disabled("   Today:  \(fmtCost(locals.todayCost))  ·  \(fmtTokens(locals.todayTok)) tok", menu)
        disabled("   Last 5h:  \(fmtCost(locals.w5Cost))  ·  \(fmtTokens(locals.w5Tok)) tok", menu)

        menu.addItem(.separator())

        // Selectable menu-bar metric.
        let showItem = NSMenuItem(title: "Show in menu bar", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for opt in METRIC_OPTIONS {
            let mi = NSMenuItem(title: opt.label, action: #selector(selectMetric(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = opt.id
            mi.state = (metric == opt.id) ? .on : .off
            sub.addItem(mi)
        }
        showItem.submenu = sub
        menu.addItem(showItem)

        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        let f = real.fetchedAt.map { tf.string(from: $0) }
        let status: String
        if real.ok, let f = f {
            status = "Live · updated \(f)"
        } else if real.authExpired {
            status = f.map { "Signed out · last \($0) · run /login" } ?? "Signed out · run  claude → /login"
        } else if real.transient {
            let why = real.rateLimited ? "rate-limited, backing off" : "offline"
            status = f.map { "Showing \($0) data · \(why)" } ?? "Waiting… · \(why)"
        } else {
            status = "Loading…"
        }
        disabled(status, menu)

        let r = NSMenuItem(title: "Refresh now", action: #selector(forceRefresh), keyEquivalent: "r"); r.target = self
        menu.addItem(r)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func selectMetric(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: METRIC_KEY)
        render()
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }   // refresh countdowns/checkmarks instantly

    // helpers
    private func header(_ t: String, _ menu: NSMenu) { headerColored(t, .secondaryLabelColor, menu) }
    private func headerColored(_ t: String, _ c: NSColor, _ menu: NSMenu) {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false
        i.attributedTitle = NSAttributedString(string: t, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: c])
        menu.addItem(i)
    }
    private func disabled(_ t: String, _ menu: NSMenu) {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false
        i.attributedTitle = NSAttributedString(string: t, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])
        menu.addItem(i)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
