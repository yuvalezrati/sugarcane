// Sugarcane — your Dexcom glucose in the macOS menu bar.
//
// Reads from Dexcom Share, the service behind the Dexcom Follow app. On first launch
// each user signs in with their own Dexcom account; nothing is built into the app.
// The password is stored in that user's macOS Keychain, the username in their
// settings file.
//
// The menu bar shows the number and trend arrow, colored green (in range), yellow (high)
// or red (low). When an expected reading doesn't arrive it switches to "Signal loss".
// Click it for a panel with the details, a 1, 3 or 6 hour graph and stats for that period.
//
// Settings (units, thresholds, menu bar style) are changed from the panel's settings page.
// They live in ~/Library/Application Support/Sugarcane/config.json and are re-read on every refresh.
//
// Build the downloadable app:  ./scripts/build-app.sh   (makes dist/Sugarcane.app and dist/Sugarcane-<version>.pkg)
// Developer build + run:       ./scripts/dev-install.sh
// Requires macOS 12+. No dependencies beyond macOS itself.

import AppKit
import Foundation
import Security
import ServiceManagement

// MARK: - Config

struct Config: Codable, Equatable {
    var menuBarStyle = "number"       // "number" (colored 135 →), "dotNumber" (● 135 →) or "dot"
    var dexcomUsername = ""           // set by the sign-in window; the password lives in the Keychain
    var dexcomRegion = "ous"          // "us", "ous" (outside the US) or "jp"
    var units = "mg/dL"               // "mg/dL" or "mmol/L"
    var urgentLow = 55.0              // thresholds always in mg/dL
    var low = 70.0
    var high = 180.0
    var urgentHigh = 250.0
    var graphHours = 3                // set by the 1h / 3h / 6h switch in the panel

    init() {}

    // Missing keys fall back to defaults, so a partial or older file still works.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        menuBarStyle = try c.decodeIfPresent(String.self, forKey: .menuBarStyle) ?? d.menuBarStyle
        dexcomUsername = try c.decodeIfPresent(String.self, forKey: .dexcomUsername) ?? d.dexcomUsername
        dexcomRegion = try c.decodeIfPresent(String.self, forKey: .dexcomRegion) ?? d.dexcomRegion
        units = try c.decodeIfPresent(String.self, forKey: .units) ?? d.units
        urgentLow = try c.decodeIfPresent(Double.self, forKey: .urgentLow) ?? d.urgentLow
        low = try c.decodeIfPresent(Double.self, forKey: .low) ?? d.low
        high = try c.decodeIfPresent(Double.self, forKey: .high) ?? d.high
        urgentHigh = try c.decodeIfPresent(Double.self, forKey: .urgentHigh) ?? d.urgentHigh
        let hours = try c.decodeIfPresent(Int.self, forKey: .graphHours) ?? d.graphHours
        graphHours = GRAPH_HOUR_CHOICES.contains(hours) ? hours : d.graphHours
    }
}

let CONFIG_DIR = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Sugarcane", isDirectory: true)
let CONFIG_URL = CONFIG_DIR.appendingPathComponent("config.json")
// The app was called Subar, and GlucoseBar before that. Settings saved under an old
// name are copied over on first launch.
let LEGACY_CONFIG_URLS = ["Subar", "GlucoseBar"].map {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/\($0)/config.json")
}

let GRAPH_HOUR_CHOICES = [1, 3, 6]
let MENU_BAR_STYLES: [(name: String, label: String)] = [
    ("number", "Number"), ("dotNumber", "Dot and number"), ("dot", "Dot only"),
]

// MARK: - Fetch timing and signal loss
//
// The sensor sends a reading every 5 minutes. Instead of polling on a fixed timer,
// the app checks once right after the next reading is due (last reading + 5 min +
// a short upload allowance). If a check made after that moment finds nothing new,
// the status becomes "Signal loss", and the app retries after 30 s, 1, 2 and 4 min,
// then every 5 min until readings resume.

let READING_INTERVAL: TimeInterval = 300
let UPLOAD_GRACE: TimeInterval = 20
let LATE_RETRY_BASE: TimeInterval = 30
let MAX_FETCH_DELAY: TimeInterval = READING_INTERVAL + 60

// MARK: - Model

struct Reading {
    let date: Date
    let sgv: Double  // mg/dL
}

struct Snapshot {
    let readings: [Reading]  // newest first
    let direction: String?   // "Flat", "FortyFiveUp", …
}

// MARK: - Trends (same names, arrows and wording as pydexcom)

let TREND_ARROWS: [String: String] = [
    "DoubleUp": "↑↑", "SingleUp": "↑", "FortyFiveUp": "↗", "Flat": "→",
    "FortyFiveDown": "↘", "SingleDown": "↓", "DoubleDown": "↓↓",
    "NotComputable": "?", "RateOutOfRange": "-",
]

let TREND_DESCRIPTIONS: [String: String] = [
    "DoubleUp": "rising quickly", "SingleUp": "rising", "FortyFiveUp": "rising slightly",
    "Flat": "steady", "FortyFiveDown": "falling slightly", "SingleDown": "falling",
    "DoubleDown": "falling quickly", "NotComputable": "unable to determine trend",
    "RateOutOfRange": "trend unavailable",
]

// Older Dexcom responses send the trend as a number.
let TREND_BY_NUMBER = ["None", "DoubleUp", "SingleUp", "FortyFiveUp", "Flat",
                       "FortyFiveDown", "SingleDown", "DoubleDown", "NotComputable", "RateOutOfRange"]

func trendName(_ raw: Any?) -> String? {
    if let s = raw as? String { return s }
    if let n = raw as? NSNumber {
        let i = n.intValue
        return TREND_BY_NUMBER.indices.contains(i) ? TREND_BY_NUMBER[i] : nil
    }
    return nil
}

/// Same rate bands Dexcom uses (mg/dL per minute) — for the arrows of older readings.
func directionFromDelta(_ deltaPer5Min: Double) -> String {
    let rate = deltaPer5Min / 5.0
    if rate > 3 { return "DoubleUp" }
    if rate > 2 { return "SingleUp" }
    if rate > 1 { return "FortyFiveUp" }
    if rate >= -1 { return "Flat" }
    if rate >= -2 { return "FortyFiveDown" }
    if rate >= -3 { return "SingleDown" }
    return "DoubleDown"
}

// MARK: - Theme (the panel's molasses look; the menu bar keeps the system colors)

enum Theme {
    static let panel = NSColor(srgbRed: 0.141, green: 0.102, blue: 0.071, alpha: 1)       // molasses brown
    static let text = NSColor(srgbRed: 0.965, green: 0.918, blue: 0.847, alpha: 1)        // raw sugar
    static let secondary = NSColor(srgbRed: 0.753, green: 0.667, blue: 0.549, alpha: 1)
    static let accent = NSColor(srgbRed: 0.941, green: 0.706, blue: 0.271, alpha: 1)      // amber syrup; also "high"
    static let inRange = NSColor(srgbRed: 0.651, green: 0.812, blue: 0.353, alpha: 1)     // cane green
    static let low = NSColor(srgbRed: 1.0, green: 0.541, blue: 0.451, alpha: 1)
    static let tile = NSColor(srgbRed: 1.0, green: 0.863, blue: 0.627, alpha: 0.08)
    static let dark = NSAppearance(named: .darkAqua)

    static func color(_ v: Double, _ cfg: Config) -> NSColor {
        v < cfg.low ? low : v > cfg.high ? accent : inRange
    }
}

/// Root view of both panels: paints the whole popover, its arrow included, in the theme's brown.
final class PanelView: NSView {
    private weak var backdrop: NSView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let frame = window?.contentView?.superview, backdrop?.superview !== frame else { return }
        let view = NSView(frame: frame.bounds)
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.panel.cgColor
        view.autoresizingMask = [.width, .height]
        frame.addSubview(view, positioned: .below, relativeTo: nil)
        backdrop = view
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.panel.setFill()
        bounds.fill()
    }
}

// MARK: - Formatting helpers

func fmtBG(_ value: Double?, _ units: String) -> String {
    guard let value else { return "?" }
    if units == "mmol/L" { return String(format: "%.1f", value / 18.0) }
    return String(Int(value.rounded()))
}

func fmtDelta(_ delta: Double?, _ units: String) -> String {
    guard let delta else { return "" }
    if units == "mmol/L" { return String(format: "%+.1f", delta / 18.0) }
    return String(format: "%+d", Int(delta.rounded()))
}

func fmtAge(_ seconds: TimeInterval) -> String {
    let m = max(0, Int(seconds / 60))
    return m < 60 ? "\(m) min ago" : "\(m / 60)h \(m % 60)m ago"
}

func fmtClock(_ date: Date, seconds: Bool = false) -> String {
    let f = DateFormatter()
    f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
    return f.string(from: date)
}

/// Label for the dropdown and the color for the menu bar.
func rangeState(_ v: Double, _ cfg: Config) -> (String, NSColor) {
    if v < cfg.urgentLow { return ("URGENT LOW", .systemRed) }
    if v < cfg.low { return ("Low", .systemRed) }
    if v > cfg.urgentHigh { return ("URGENT HIGH", .systemYellow) }
    if v > cfg.high { return ("High", .systemYellow) }
    return ("In range", .systemGreen)
}

func dotImage(_ color: NSColor, hollow: Bool = false) -> NSImage {
    let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
        let d: CGFloat = 10
        let circle = NSRect(x: (rect.width - d) / 2, y: (rect.height - d) / 2, width: d, height: d)
        if hollow {
            let path = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
            path.lineWidth = 1.5
            color.setStroke()
            path.stroke()
        } else {
            color.setFill()
            NSBezierPath(ovalIn: circle).fill()
        }
        return true
    }
    image.isTemplate = false  // keep our colors instead of the menu bar's tint
    return image
}

/// The "no signal" antenna icon, tinted.
func signalLossImage(_ color: NSColor, pointSize: CGFloat) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    let image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right.slash",
                        accessibilityDescription: "Signal loss")?
        .withSymbolConfiguration(config)
    image?.isTemplate = false
    return image
}

// MARK: - Graph of the last 1, 3 or 6 hours (hover a dot to see that reading)

final class GraphView: NSView {
    struct Point {
        let date: Date
        let value: Double
        let arrow: String
        let color: NSColor
    }

    var points: [Point] = [] { didSet { needsDisplay = true } }
    var now = Date()
    var low = 70.0
    var high = 180.0
    var units = "mg/dL"
    var hours = 1               // how far back the graph goes
    var gapFrom: Date?          // signal loss: shade from the last reading up to now
    private var hovered: Int?

    private let inset: CGFloat = 6         // room for the dots at the edges
    private let readoutHeight: CGFloat = 22
    private let axisHeight: CGFloat = 18

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 140))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private var plot: NSRect {
        NSRect(x: inset, y: readoutHeight + 4, width: bounds.width - inset * 2,
               height: bounds.height - readoutHeight - axisHeight - 8)
    }

    private func x(_ date: Date) -> CGFloat {
        let f = 1 - min(max(now.timeIntervalSince(date) / (Double(hours) * 3600), 0), 1)
        return plot.minX + CGFloat(f) * plot.width
    }

    private func y(_ v: Double) -> CGFloat {
        let f = (300 - min(max(v, 40), 300)) / 260
        return plot.minY + CGFloat(f) * plot.height
    }

    override func mouseMoved(with event: NSEvent) {
        guard !points.isEmpty else { return }
        let p = convert(event.locationInWindow, from: nil)
        let nearest = points.indices.min { abs(x(points[$0].date) - p.x) < abs(x(points[$1].date) - p.x) }
        if nearest != hovered {
            hovered = nearest
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.secondary]

        // Edges of the target range
        for edge in [y(high), y(low)] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: edge))
            line.line(to: NSPoint(x: plot.maxX, y: edge))
            line.setLineDash([3, 4], count: 2, phase: 0)
            line.lineWidth = 1
            Theme.text.withAlphaComponent(0.25).setStroke()
            line.stroke()
        }

        // Signal-loss gap: hatching from the last reading to now
        if let gapFrom {
            let gx = min(x(gapFrom) + 4, plot.maxX)
            let gap = NSRect(x: gx, y: plot.minY - 4, width: plot.maxX - gx, height: plot.height + 8)
            if gap.width > 2 {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: gap).addClip()
                let hatch = NSBezierPath()
                var hx = gap.minX - gap.height
                while hx < gap.maxX {
                    hatch.move(to: NSPoint(x: hx, y: gap.maxY))
                    hatch.line(to: NSPoint(x: hx + gap.height, y: gap.minY))
                    hx += 6
                }
                hatch.lineWidth = 1.5
                Theme.secondary.withAlphaComponent(0.4).setStroke()
                hatch.stroke()
                NSGraphicsContext.restoreGraphicsState()
                if gap.width > 50 {
                    let label = NSAttributedString(string: "no signal", attributes: [
                        .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                        .foregroundColor: Theme.secondary])
                    label.draw(at: NSPoint(x: gap.midX - label.size().width / 2, y: gap.minY + 2))
                }
            }
        }

        // Axis labels
        NSAttributedString(string: hours == 1 ? "60 min ago" : "\(hours) h ago", attributes: secondary)
            .draw(at: NSPoint(x: plot.minX, y: bounds.height - axisHeight + 2))
        let nowLabel = NSAttributedString(string: "now", attributes: secondary)
        nowLabel.draw(at: NSPoint(x: plot.maxX - nowLabel.size().width, y: bounds.height - axisHeight + 2))

        guard let first = points.first, let lastPoint = points.last else {
            NSAttributedString(string: "No readings in this period", attributes: secondary)
                .draw(at: NSPoint(x: inset, y: 2))
            return
        }

        // Amber line with the area under it filled, like poured syrup
        let line = NSBezierPath()
        for (i, p) in points.enumerated() {
            let pt = NSPoint(x: x(p.date), y: y(p.value))
            if i == 0 { line.move(to: pt) } else { line.line(to: pt) }
        }
        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: x(lastPoint.date), y: plot.maxY))
        area.line(to: NSPoint(x: x(first.date), y: plot.maxY))
        area.close()
        Theme.accent.withAlphaComponent(0.16).setFill()
        area.fill()
        line.lineWidth = 2.5
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        Theme.accent.setStroke()
        line.stroke()

        // A dot on the hovered (or latest) reading, and its readout above the graph
        let selected = hovered ?? points.count - 1
        let p = points[selected]
        let r: CGFloat = 5
        let dot = NSBezierPath(ovalIn: NSRect(x: x(p.date) - r, y: y(p.value) - r, width: r * 2, height: r * 2))
        p.color.setFill()
        dot.fill()
        dot.lineWidth = 1.5
        Theme.text.setStroke()
        dot.stroke()

        let time = fmtClock(p.date)
        let latestLabel = gapFrom == nil ? "Latest" : "Last reading"
        NSAttributedString(string: selected == points.count - 1 ? "\(latestLabel) · \(time)" : time,
                           attributes: secondary)
            .draw(at: NSPoint(x: plot.minX, y: 3))
        let value = NSMutableAttributedString(string: fmtBG(p.value, units), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: p.color])
        value.append(NSAttributedString(string: " \(units) \(p.arrow)", attributes: secondary))
        value.draw(at: NSPoint(x: plot.maxX - value.size().width, y: 2))
    }
}

// MARK: - Keychain (each user's own Dexcom password)

enum Keychain {
    static let service = "Sugarcane.Dexcom"
    static let legacyServices = ["Subar.Dexcom", "GlucoseBar.Dexcom"]   // before the renames

    private static func query(_ account: String, service: String = Keychain.service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(_ account: String, service: String) -> String? {
        var q = query(account, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ password: String, account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> String? {
        if let password = read(account, service: service) { return password }
        // Move a password saved before the rename to the new name.
        for legacy in legacyServices {
            guard let old = read(account, service: legacy) else { continue }
            if save(old, account: account) {
                SecItemDelete(query(account, service: legacy) as CFDictionary)
            }
            return old
        }
        return nil
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
        for legacy in legacyServices {
            SecItemDelete(query(account, service: legacy) as CFDictionary)
        }
    }
}

// MARK: - Dexcom Share

struct DexcomRegion {
    let base: String
    let appId: String
    let label: String

    static let choices: [(name: String, label: String)] = [
        ("ous", "Outside the US"), ("us", "United States"), ("jp", "Japan"),
    ]

    // The application IDs are Dexcom's public Share app identifiers (the same ones
    // pydexcom uses), not anyone's credentials.
    static func named(_ name: String) -> DexcomRegion {
        switch name {
        case "us":
            return DexcomRegion(base: "https://share2.dexcom.com/ShareWebServices/Services",
                                appId: "d89443d2-327c-4a6f-89e5-496bbb0317db", label: "United States")
        case "jp":
            return DexcomRegion(base: "https://share.dexcom.jp/ShareWebServices/Services",
                                appId: "d8665ade-9673-4e27-9ff6-92db4ce13d13", label: "Japan")
        default:
            return DexcomRegion(base: "https://shareous1.dexcom.com/ShareWebServices/Services",
                                appId: "d89443d2-327c-4a6f-89e5-496bbb0317db", label: "Outside the US")
        }
    }
}

struct DexcomError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message.isEmpty ? code : message }

    var isSessionExpired: Bool { code == "SessionIdNotFound" || code == "SessionNotValid" }

    /// Wrong username/password or a locked account. Retrying these can get the
    /// Dexcom account locked, so the app pauses until the user signs in again.
    var isAuthFailure: Bool {
        code.contains("Password") || code.contains("AccountNotFound")
            || code.contains("MaxAttempts") || code == "InvalidCredentials"
    }
}

let DEXCOM_EMPTY_ID = "00000000-0000-0000-0000-000000000000"

/// "/Date(1696512000000)/" or "Date(1696512000000+0300)" -> Date
func parseDexcomDate(_ s: String?) -> Date? {
    guard let s, let open = s.firstIndex(of: "(") else { return nil }
    let digits = s[s.index(after: open)...].prefix { $0.isNumber }
    guard let ms = Double(digits) else { return nil }
    return Date(timeIntervalSince1970: ms / 1000)
}

@MainActor
final class DexcomClient {
    let username: String
    let regionName: String
    private let password: String
    private let region: DexcomRegion
    private var sessionId: String?

    init(username: String, password: String, regionName: String) {
        self.username = username
        self.password = password
        self.regionName = regionName
        self.region = DexcomRegion.named(regionName)
    }

    private func post(_ path: String, body: [String: Any], query: [String: String] = [:]) async throws -> Any {
        guard var comps = URLComponents(string: region.base + "/" + path) else {
            throw DexcomError(code: "BadURL", message: "Invalid Dexcom address")
        }
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { throw DexcomError(code: "BadURL", message: "Invalid Dexcom address") }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let dict = json as? [String: Any]
            throw DexcomError(code: dict?["Code"] as? String ?? "HTTP\(http.statusCode)",
                              message: dict?["Message"] as? String ?? "Dexcom returned HTTP \(http.statusCode)")
        }
        guard let json else { throw DexcomError(code: "BadResponse", message: "Unexpected response from Dexcom") }
        return json
    }

    /// Two-step Share login: username -> account ID -> session ID.
    func login() async throws {
        let account = try await post("General/AuthenticatePublisherAccount", body: [
            "accountName": username, "password": password, "applicationId": region.appId,
        ]) as? String
        guard let account, account != DEXCOM_EMPTY_ID else {
            throw DexcomError(code: "AccountNotFound", message: "Dexcom didn't recognize this account")
        }
        let session = try await post("General/LoginPublisherAccountById", body: [
            "accountId": account, "password": password, "applicationId": region.appId,
        ]) as? String
        guard let session, session != DEXCOM_EMPTY_ID else {
            throw DexcomError(code: "InvalidCredentials", message: "Dexcom rejected the sign-in")
        }
        sessionId = session
    }

    /// Latest readings, newest first. Logs in (again) when there's no valid session.
    func readings(minutes: Int = 365, maxCount: Int = 73) async throws -> Snapshot {
        if sessionId == nil { try await login() }
        do {
            return try await fetch(minutes: minutes, maxCount: maxCount)
        } catch let e as DexcomError where e.isSessionExpired {
            sessionId = nil
            try await login()
            return try await fetch(minutes: minutes, maxCount: maxCount)
        }
    }

    private func fetch(minutes: Int, maxCount: Int) async throws -> Snapshot {
        let raw = try await post("Publisher/ReadPublisherLatestGlucoseValues", body: [:], query: [
            "sessionId": sessionId ?? "", "minutes": String(minutes), "maxCount": String(maxCount),
        ])
        guard let list = raw as? [[String: Any]] else {
            throw DexcomError(code: "BadResponse", message: "Unexpected glucose data from Dexcom")
        }
        var rows: [(reading: Reading, trend: String?)] = []
        for item in list {
            guard let value = (item["Value"] as? NSNumber)?.doubleValue,
                  let date = parseDexcomDate((item["WT"] as? String) ?? (item["DT"] as? String))
            else { continue }
            rows.append((Reading(date: date, sgv: value), trendName(item["Trend"])))
        }
        rows.sort { $0.reading.date > $1.reading.date }
        return Snapshot(readings: rows.map { $0.reading }, direction: rows.first?.trend)
    }
}

// MARK: - Sign-in panel (drops down from the menu bar item)

@MainActor
final class LoginViewController: NSViewController {
    /// Called with the verified credentials and a client that already holds a session.
    var onSuccess: ((String, String, String, DexcomClient) -> Void)?
    var onQuit: (() -> Void)?

    private let initialUsername: String
    private let initialRegion: String
    private let userField = NSTextField()
    private let passField = NSSecureTextField()
    private let regionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let signInButton = NSButton(title: "Sign In", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit Sugarcane", target: nil, action: nil)
    private let contentWidth: CGFloat = 280

    init(username: String, region: String) {
        initialUsername = username
        initialRegion = region
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let title = NSTextField(labelWithString: "Sign in to Dexcom")
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let subtitle = wrapping("Use the same account as your Dexcom app.", size: 12)

        userField.placeholderString = "Username, email or phone"
        userField.stringValue = initialUsername
        passField.placeholderString = "Password"
        for field in [userField, passField] as [NSTextField] {
            field.font = .systemFont(ofSize: 13)
            field.controlSize = .large
        }
        passField.target = self
        passField.action = #selector(signIn)   // Return in the password field signs in

        let regionLabel = NSTextField(labelWithString: "Region")
        regionLabel.font = .systemFont(ofSize: 12)
        regionLabel.textColor = .secondaryLabelColor
        regionPopup.addItems(withTitles: DexcomRegion.choices.map { $0.label })
        if let idx = DexcomRegion.choices.firstIndex(where: { $0.name == initialRegion }) {
            regionPopup.selectItem(at: idx)
        }
        let regionRow = NSStackView(views: [regionLabel, regionPopup])
        regionRow.orientation = .horizontal
        regionRow.spacing = 8

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.preferredMaxLayoutWidth = contentWidth
        errorLabel.isHidden = true

        let hint = wrapping("Dexcom Share must be on in the Dexcom app, with at least one follower. "
                            + "Your password stays in this Mac's Keychain.", size: 11)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        signInButton.bezelStyle = .rounded
        signInButton.keyEquivalent = "\r"
        signInButton.target = self
        signInButton.action = #selector(signIn)
        quitButton.isBordered = false
        quitButton.font = .systemFont(ofSize: 12)
        quitButton.contentTintColor = .secondaryLabelColor
        quitButton.target = self
        quitButton.action = #selector(quit)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let buttons = NSStackView(views: [quitButton, spacer, spinner, signInButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, subtitle, userField, passField, regionRow,
                                        errorLabel, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.setCustomSpacing(2, after: title)
        stack.setCustomSpacing(12, after: subtitle)
        stack.setCustomSpacing(10, after: regionRow)
        stack.setCustomSpacing(14, after: hint)
        for v in [subtitle, userField, passField, errorLabel, hint, buttons] as [NSView] {
            v.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = PanelView()
        container.appearance = Theme.dark
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        updateSize()
    }

    private func wrapping(_ text: String, size: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = contentWidth
        return label
    }

    private func updateSize() {
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize   // the panel resizes to fit
    }

    func setError(_ text: String?) {
        _ = view   // make sure the view is built
        if let text {
            errorLabel.stringValue = text
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }
        updateSize()
    }

    func focus() {
        view.window?.makeFirstResponder(userField.stringValue.isEmpty ? userField : passField)
    }

    private func setBusy(_ busy: Bool) {
        for control in [userField, passField, regionPopup, signInButton] as [NSControl] {
            control.isEnabled = !busy
        }
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func quit() {
        onQuit?()
    }

    @objc private func signIn() {
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = passField.stringValue
        let regionName = DexcomRegion.choices[max(0, regionPopup.indexOfSelectedItem)].name
        guard !user.isEmpty, !pass.isEmpty else {
            setError("Enter your Dexcom username and password.")
            return
        }
        setError(nil)
        setBusy(true)
        let client = DexcomClient(username: user, password: pass, regionName: regionName)
        Task {
            do {
                try await client.login()   // only keep credentials Dexcom accepted
                self.setBusy(false)
                self.passField.stringValue = ""
                self.onSuccess?(user, pass, regionName, client)
            } catch let e as DexcomError where e.isAuthFailure {
                self.setBusy(false)
                self.setError("Dexcom didn't accept that username or password. "
                              + "Check them, and that the region matches your account.")
                self.view.window?.makeFirstResponder(self.passField)
            } catch {
                self.setBusy(false)
                self.setError("Couldn't reach Dexcom: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Dashboard panel (drops down from the menu bar item)

/// Everything the panel shows, worked out by the app delegate.
struct DashboardModel {
    var configError: String?
    var placeholder: String?          // shown instead of the reading while there's no data
    var value: String?
    var valueColor = Theme.text
    var arrow = ""
    var units = "mg/dL"
    var subtitle = ""
    var state = ""
    var stateColor = Theme.inRange
    var message: String?              // couldn't reach Dexcom
    var hint: String?                 // signal loss advice
    var points: [GraphView.Point] = []
    var now = Date()
    var hours = 3
    var low = 70.0
    var high = 180.0
    var gapFrom: Date?
    var average = "–"
    var inRange = "–"
    var lowShare = "–"
    var highShare = "–"
    var nextCheck = ""
    var account = ""
    var openAtLogin: Bool?            // nil when Open at Login isn't available
    var config = Config()             // what the settings page edits
}

/// The outlined "In range" / "High" / "Signal loss" label.
final class PillView: NSView {
    var text = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var color = Theme.inRange { didSet { needsDisplay = true } }

    private var attributed: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributed.size().width) + 20, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
        let s = attributed
        s.draw(at: NSPoint(x: (bounds.width - s.size().width) / 2, y: (bounds.height - s.size().height) / 2))
    }
}

/// One of the three stat boxes under the graph.
final class StatTile: NSView {
    private let valueLabel = NSTextField(labelWithString: "–")

    init(title: String) {
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = Theme.secondary
        let stack = NSStackView(views: [titleLabel, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Parts are drawn side by side, each in its own color.
    func set(_ parts: [(String, NSColor)]) {
        let s = NSMutableAttributedString()
        for (text, color) in parts {
            s.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold), .foregroundColor: color]))
        }
        valueLabel.attributedStringValue = s
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.tile.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// A threshold on the settings page: shown in the chosen units, kept in mg/dL.
final class ThresholdField: NSStackView {
    var onChange: (() -> Void)?
    private(set) var mgdl = 0.0
    private var units = "mg/dL"
    private let field = NSTextField()
    private let stepper = NSStepper()
    private var scale: Double { units == "mmol/L" ? 18.0 : 1.0 }

    init(title: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.alignment = .right
        field.target = self
        field.action = #selector(fieldChanged)
        field.widthAnchor.constraint(equalToConstant: 46).isActive = true
        field.setAccessibilityLabel(title)
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        stepper.controlSize = .small
        orientation = .horizontal
        spacing = 5
        [label, field, stepper].forEach(addArrangedSubview)
        setCustomSpacing(2, after: field)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ value: Double, units: String) {
        self.units = units
        mgdl = value
        stepper.minValue = 20 / scale
        stepper.maxValue = 400 / scale
        stepper.increment = units == "mmol/L" ? 0.1 : 1
        show()
    }

    private func show() {
        field.stringValue = fmtBG(mgdl, units)
        stepper.doubleValue = mgdl / scale
    }

    @objc private func fieldChanged() {
        if let typed = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")) {
            mgdl = min(max(typed, stepper.minValue), stepper.maxValue) * scale
        }
        show()
        onChange?()
    }

    @objc private func stepperChanged() {
        mgdl = stepper.doubleValue * scale
        show()
        onChange?()
    }
}

@MainActor
final class DashboardViewController: NSViewController {
    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?
    var onConfig: ((Config) -> Void)?
    var onSignOut: (() -> Void)?
    var onToggleOpenAtLogin: (() -> Void)?
    var onHours: ((Int) -> Void)?

    private var model = DashboardModel()
    private let contentWidth: CGFloat = 308
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let pill = PillView()
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let periodLabel = NSTextField(labelWithString: "")
    private let periodSwitch = NSSegmentedControl(labels: GRAPH_HOUR_CHOICES.map { "\($0)h" },
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let graph = GraphView(width: 308)
    private let averageTile = StatTile(title: "Average")
    private let inRangeTile = StatTile(title: "In range")
    private let outsideTile = StatTile(title: "Low · High")
    private let nextCheckLabel = NSTextField(labelWithString: "")
    private var dataViews: [NSView] = []

    // Settings page: replaces the reading and graph while it's open.
    private var showingSettings = false
    private var shownConfig: Config?
    private let rootStack = NSStackView()
    private let mainStack = NSStackView()
    private let settingsStack = NSStackView()
    private let unitsSwitch = NSSegmentedControl(labels: ["mg/dL", "mmol/L"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let stylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let lowField = ThresholdField(title: "Low")
    private let highField = ThresholdField(title: "High")
    private let urgentLowField = ThresholdField(title: "Urgent low")
    private let urgentHighField = ThresholdField(title: "Urgent high")
    private let settingsError = NSTextField(wrappingLabelWithString: "")
    private let openAtLoginBox = NSButton(checkboxWithTitle: "Open at Login", target: nil, action: nil)
    private let accountLabel = NSTextField(labelWithString: "")

    override func loadView() {
        for (label, color) in [(warningLabel, Theme.accent), (messageLabel, Theme.accent),
                               (hintLabel, Theme.secondary), (placeholderLabel, Theme.text)] {
            label.font = .systemFont(ofSize: label === placeholderLabel ? 13 : 11)
            label.textColor = color
            label.preferredMaxLayoutWidth = contentWidth
        }
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = Theme.secondary
        periodLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        periodLabel.textColor = Theme.secondary
        nextCheckLabel.font = .systemFont(ofSize: 11)
        nextCheckLabel.textColor = Theme.secondary

        let header = row([valueLabel, spacer(), pill])
        header.alignment = .centerY

        periodSwitch.controlSize = .small
        periodSwitch.selectedSegmentBezelColor = Theme.accent
        periodSwitch.target = self
        periodSwitch.action = #selector(periodChanged)
        let periodRow = row([periodLabel, spacer(), periodSwitch])

        let tiles = NSStackView(views: [averageTile, inRangeTile, outsideTile])
        tiles.orientation = .horizontal
        tiles.distribution = .fillEqually
        tiles.spacing = 8

        let divider = NSBox()
        divider.boxType = .separator

        let footer = row([nextCheckLabel, spacer(),
                          iconButton("arrow.clockwise", "Refresh", #selector(refresh)),
                          iconButton("slider.horizontal.3", "Settings", #selector(toggleSettings)),
                          iconButton("power", "Quit Sugarcane", #selector(quit))])

        dataViews = [header, subtitleLabel, periodRow, graph, tiles]
        fill(mainStack, [warningLabel, placeholderLabel, header, subtitleLabel, messageLabel,
                         hintLabel, periodRow, graph, tiles])
        mainStack.setCustomSpacing(2, after: header)
        mainStack.setCustomSpacing(14, after: subtitleLabel)
        mainStack.setCustomSpacing(6, after: periodRow)
        graph.heightAnchor.constraint(equalToConstant: graph.frame.height).isActive = true
        buildSettings()

        let stack = rootStack
        fill(stack, [mainStack, settingsStack, divider, footer])
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 10, right: 16)
        stack.setCustomSpacing(6, after: divider)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = PanelView()
        container.appearance = Theme.dark
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    /// A vertical stack of full-width rows.
    private func fill(_ stack: NSStackView, _ views: [NSView]) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for v in views {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }
    }

    private func buildSettings() {
        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = Theme.text
        let done = smallButton("Done", #selector(toggleSettings))
        done.keyEquivalent = "\r"

        unitsSwitch.target = self
        unitsSwitch.action = #selector(settingsChanged)
        stylePopup.addItems(withTitles: MENU_BAR_STYLES.map { $0.label })
        stylePopup.target = self
        stylePopup.action = #selector(settingsChanged)
        for field in [lowField, highField, urgentLowField, urgentHighField] {
            field.onChange = { [weak self] in self?.settingsChanged() }
        }
        let rangeCaption = NSTextField(labelWithString: "TARGET RANGE")
        rangeCaption.font = .systemFont(ofSize: 11, weight: .semibold)
        rangeCaption.textColor = Theme.secondary
        settingsError.font = .systemFont(ofSize: 11)
        settingsError.textColor = Theme.low
        settingsError.preferredMaxLayoutWidth = contentWidth
        settingsError.isHidden = true

        openAtLoginBox.target = self
        openAtLoginBox.action = #selector(toggleOpenAtLogin)
        accountLabel.font = .systemFont(ofSize: 11)
        accountLabel.textColor = Theme.secondary
        accountLabel.lineBreakMode = .byTruncatingMiddle
        accountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let accountDivider = NSBox()
        accountDivider.boxType = .separator

        fill(settingsStack, [
            row([title, spacer(), done]),
            row([settingLabel("Units"), spacer(), unitsSwitch]),
            row([settingLabel("Menu bar shows"), spacer(), stylePopup]),
            rangeCaption,
            row([lowField, spacer(), highField]),
            row([urgentLowField, spacer(), urgentHighField]),
            settingsError,
            openAtLoginBox,
            accountDivider,
            row([accountLabel, spacer(), smallButton("Sign Out", #selector(signOut))]),
        ])
        settingsStack.setCustomSpacing(14, after: settingsStack.arrangedSubviews[0])
        settingsStack.setCustomSpacing(14, after: settingsStack.arrangedSubviews[2])
        settingsStack.setCustomSpacing(6, after: rangeCaption)
    }

    private func settingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.text
        return label
    }

    private func smallButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return button
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 6
        return stack
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return v
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = Theme.text
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    func update(_ m: DashboardModel) {
        _ = view   // make sure the view is built
        model = m
        warningLabel.stringValue = m.configError.map { "⚠︎ \($0)" } ?? ""
        warningLabel.isHidden = m.configError == nil
        placeholderLabel.stringValue = m.placeholder ?? ""
        placeholderLabel.isHidden = m.value != nil
        dataViews.forEach { $0.isHidden = m.value == nil }
        messageLabel.stringValue = m.message.map { "⚠︎ \($0)" } ?? ""
        messageLabel.isHidden = m.message == nil
        hintLabel.stringValue = m.hint ?? ""
        hintLabel.isHidden = m.hint == nil
        nextCheckLabel.stringValue = m.nextCheck

        mainStack.isHidden = showingSettings
        settingsStack.isHidden = !showingSettings
        if m.config != shownConfig {   // not on every refresh, so typing isn't interrupted
            shownConfig = m.config
            unitsSwitch.selectedSegment = m.config.units == "mmol/L" ? 1 : 0
            stylePopup.selectItem(at: MENU_BAR_STYLES.firstIndex { $0.name == m.config.menuBarStyle } ?? 0)
            lowField.set(m.config.low, units: m.config.units)
            highField.set(m.config.high, units: m.config.units)
            urgentLowField.set(m.config.urgentLow, units: m.config.units)
            urgentHighField.set(m.config.urgentHigh, units: m.config.units)
            settingsError.isHidden = true
        }
        openAtLoginBox.isHidden = m.openAtLogin == nil
        openAtLoginBox.state = m.openAtLogin == true ? .on : .off
        accountLabel.stringValue = m.account

        if let value = m.value {
            let s = NSMutableAttributedString(string: value, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 40, weight: .bold), .foregroundColor: m.valueColor])
            if !m.arrow.isEmpty {
                s.append(NSAttributedString(string: " " + m.arrow, attributes: [
                    .font: NSFont.systemFont(ofSize: 22), .foregroundColor: Theme.text]))
            }
            s.append(NSAttributedString(string: "  " + m.units, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.secondary]))
            valueLabel.attributedStringValue = s
            pill.text = m.state
            pill.color = m.stateColor
            subtitleLabel.stringValue = m.subtitle

            periodLabel.stringValue = m.hours == 1 ? "LAST HOUR" : "LAST \(m.hours) HOURS"
            periodSwitch.selectedSegment = GRAPH_HOUR_CHOICES.firstIndex(of: m.hours) ?? 1
            graph.now = m.now
            graph.hours = m.hours
            graph.low = m.low
            graph.high = m.high
            graph.units = m.units
            graph.gapFrom = m.gapFrom
            graph.points = m.points

            averageTile.set([(m.average, Theme.text)])
            inRangeTile.set([(m.inRange, Theme.inRange)])
            outsideTile.set([(m.lowShare, Theme.low), (" · ", Theme.secondary), (m.highShare, Theme.accent)])
        }
        resize()
    }

    /// The panel resizes to fit. Measured on the stack, which the window doesn't hold to its current size.
    private func resize() {
        view.layoutSubtreeIfNeeded()
        preferredContentSize = rootStack.fittingSize
    }

    @objc private func periodChanged() {
        onHours?(GRAPH_HOUR_CHOICES[max(0, periodSwitch.selectedSegment)])
    }

    @objc private func refresh() { onRefresh?() }
    @objc private func quit() { onQuit?() }
    @objc private func signOut() { onSignOut?() }
    @objc private func toggleOpenAtLogin() { onToggleOpenAtLogin?() }

    /// The reading comes back each time the panel opens.
    func showMain() { showingSettings = false }

    func showSettings() {
        showingSettings = true
        update(model)
    }

    @objc private func toggleSettings() {
        showingSettings.toggle()
        update(model)
    }

    /// Any control on the settings page changed: check the values and save them.
    @objc private func settingsChanged() {
        var cfg = model.config
        cfg.units = unitsSwitch.selectedSegment == 1 ? "mmol/L" : "mg/dL"
        cfg.menuBarStyle = MENU_BAR_STYLES[max(0, stylePopup.indexOfSelectedItem)].name
        cfg.low = lowField.mgdl
        cfg.high = highField.mgdl
        cfg.urgentLow = urgentLowField.mgdl
        cfg.urgentHigh = urgentHighField.mgdl
        guard cfg.urgentLow < cfg.low, cfg.low < cfg.high, cfg.high < cfg.urgentHigh else {
            settingsError.stringValue = "Not saved: keep urgent low below low, low below high, and high below urgent high."
            settingsError.isHidden = false
            resize()
            return
        }
        settingsError.isHidden = true
        onConfig?(cfg)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var fetchTimer: Timer?
    private var nextFetchAt: Date?
    private var lastFetchAt: Date?          // last successful check with Dexcom
    private var lateRetries = 0
    private var config = Config()
    private var configError: String?
    private var last: Snapshot?
    private var lastError: String?
    private var isLoading = false

    private var dexcom: DexcomClient?
    private var needsLogin = false
    private var authError: String?          // set after Dexcom rejects the saved password; polling pauses
    private var didAutoPrompt = false
    private let dashboard = DashboardViewController()
    private let dashPopover = NSPopover()
    private var loginController: LoginViewController?
    private let loginPopover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.image = dotImage(.secondaryLabelColor, hollow: true)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        dashPopover.behavior = .transient
        dashPopover.appearance = Theme.dark
        loginPopover.appearance = Theme.dark
        dashPopover.contentViewController = dashboard
        dashboard.onRefresh = { [weak self] in self?.refresh() }
        dashboard.onQuit = { NSApp.terminate(nil) }
        dashboard.onConfig = { [weak self] cfg in
            try? self?.saveConfig(cfg)
            self?.render()
        }
        dashboard.onSignOut = { [weak self] in
            self?.dashPopover.performClose(nil)
            self?.signOut()
        }
        dashboard.onToggleOpenAtLogin = { [weak self] in self?.toggleOpenAtLogin() }
        dashboard.onHours = { [weak self] hours in self?.setGraphHours(hours) }
        loginPopover.behavior = .transient   // closes when you click elsewhere
        loginPopover.animates = true

        loadConfig()
        setUpOpenAtLoginOnce()
        // A sleeping Mac skips timers: fetch right away on wake and re-learn the timing.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshNow),
            name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
    }

    // MARK: Open at Login (the downloadable .app only; dev-install.sh uses a LaunchAgent instead)

    private var isAppBundle: Bool { Bundle.main.bundleIdentifier != nil }

    /// The first time the .app runs, turn on Open at Login (users can turn it off in the menu).
    private func setUpOpenAtLoginOnce() {
        guard isAppBundle, #available(macOS 13.0, *) else { return }
        let key = "didSetUpOpenAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        do { try SMAppService.mainApp.register() } catch { NSLog("Sugarcane: Open at Login failed: \(error)") }
    }

    @objc private func toggleOpenAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Sugarcane: changing Open at Login failed: \(error)")
        }
        render()
    }

    // MARK: Config

    private func loadConfig() {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: CONFIG_URL.path) {
                try fm.createDirectory(at: CONFIG_DIR, withIntermediateDirectories: true)
                if let old = LEGACY_CONFIG_URLS.first(where: { fm.fileExists(atPath: $0.path) }) {
                    try fm.copyItem(at: old, to: CONFIG_URL)
                } else {
                    try saveConfig(Config())
                }
            }
            let data = try Data(contentsOf: CONFIG_URL)
            config = try JSONDecoder().decode(Config.self, from: data)
            configError = nil
        } catch {
            // Keep the previous working config and say what's wrong.
            configError = "Settings file problem: \(error.localizedDescription)"
        }
    }

    private func saveConfig(_ cfg: Config) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cfg).write(to: CONFIG_URL, options: .atomic)
        config = cfg
    }

    // MARK: Fetch timing

    /// When the reading after `latest` should have arrived.
    private func nextReadingDue(after latest: Date) -> Date {
        latest.addingTimeInterval(READING_INTERVAL + UPLOAD_GRACE)
    }

    /// True when a check made after the expected time found no new reading.
    private var isSignalLoss: Bool {
        guard let latest = last?.readings.first?.date, let checked = lastFetchAt else { return false }
        return checked > nextReadingDue(after: latest)
    }

    /// Plan the next fetch from the timestamp of the newest reading.
    private func scheduleNextFetch() {
        fetchTimer?.invalidate()
        let now = Date()
        var delay: TimeInterval
        if let latest = last?.readings.first?.date {
            let due = nextReadingDue(after: latest)
            if due > now {
                delay = due.timeIntervalSince(now)   // next reading isn't due yet: sleep until it is
                lateRetries = 0
            } else {
                // Due but not here (signal loss): back off gently.
                delay = LATE_RETRY_BASE * pow(2, Double(min(lateRetries, 4)))
                lateRetries += 1
            }
        } else {
            delay = lastError == nil ? LATE_RETRY_BASE : 60
        }
        delay = min(max(delay, 5), MAX_FETCH_DELAY)
        nextFetchAt = now.addingTimeInterval(delay)
        let timer = Timer(timeInterval: delay, target: self, selector: #selector(refreshNow),
                          userInfo: nil, repeats: false)
        timer.tolerance = min(10, delay * 0.1)   // lets macOS batch wake-ups to save power
        RunLoop.main.add(timer, forMode: .common)
        fetchTimer = timer
    }

    private func stopFetching() {
        fetchTimer?.invalidate()
        fetchTimer = nil
        nextFetchAt = nil
    }

    // MARK: Refresh

    @objc func refreshNow() { refresh() }

    func refresh() {
        loadConfig()
        let user = config.dexcomUsername
        // The Keychain is read only when a client is needed (at launch, or when the account
        // changes), never on every refresh: each read can make macOS ask for permission.
        if dexcom?.username != user || dexcom?.regionName != config.dexcomRegion {
            dexcom = nil
            if !user.isEmpty, let password = Keychain.load(account: user) {
                // An item saved by an older build belongs to that build. Saving it again from
                // this one means macOS doesn't ask the next time.
                Keychain.save(password, account: user)
                dexcom = DexcomClient(username: user, password: password, regionName: config.dexcomRegion)
            }
        }
        guard dexcom != nil else {
            needsLogin = true
            last = nil
            lastFetchAt = nil
            stopFetching()
            render()
            if !didAutoPrompt {
                didAutoPrompt = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    self.showLogin()
                }
            }
            return
        }
        needsLogin = false
        if authError != nil { stopFetching(); render(); return }   // paused until the user signs in again

        guard let client = dexcom, !isLoading else { render(); return }
        isLoading = true
        Task {
            do {
                let snap = try await client.readings()
                self.last = snap
                self.lastFetchAt = Date()
                self.lastError = snap.readings.isEmpty
                    ? "No recent readings – check that Share is on in the Dexcom app" : nil
            } catch let e as DexcomError where e.isAuthFailure {
                self.authError = e.localizedDescription
                self.lastError = nil
            } catch {
                // Couldn't reach Dexcom (e.g. the Mac is offline). That's not signal loss:
                // keep the last good data and say what went wrong.
                self.lastError = error.localizedDescription
            }
            self.isLoading = false
            if self.authError == nil { self.scheduleNextFetch() } else { self.stopFetching() }
            self.render()
            if let err = self.authError {
                self.showLogin(error: "Dexcom no longer accepts the saved password (\(err)). "
                               + "Please sign in again. Updates are paused so your account isn't locked.")
            }
        }
    }

    // MARK: Sign-in

    /// Show the sign-in panel under the menu bar item.
    private func showLogin(error: String? = nil) {
        guard let button = statusItem.button else { return }
        if loginController == nil {
            let controller = LoginViewController(username: config.dexcomUsername, region: config.dexcomRegion)
            controller.onSuccess = { [weak self] user, pass, region, client in
                self?.loginPopover.performClose(nil)
                self?.didSignIn(user: user, password: pass, region: region, client: client)
            }
            controller.onQuit = { NSApp.terminate(nil) }
            loginController = controller
            loginPopover.contentViewController = controller
        }
        loginController?.setError(error)
        NSApp.activate(ignoringOtherApps: true)
        if !loginPopover.isShown {
            loginPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        loginPopover.contentViewController?.view.window?.makeKey()
        loginController?.focus()
    }

    /// Clicking the menu bar item opens/closes the panel, or the sign-in panel while signed out.
    @objc private func statusItemClicked() {
        if needsLogin || authError != nil {
            if loginPopover.isShown { loginPopover.performClose(nil) } else { showLogin() }
            return
        }
        guard let button = statusItem.button else { return }
        if dashPopover.isShown {
            dashPopover.performClose(nil)
            return
        }
        dashboard.showMain()
        render()   // no network: just recompute ages from the data already fetched
        NSApp.activate(ignoringOtherApps: true)
        dashPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        dashPopover.contentViewController?.view.window?.makeKey()
    }

    private func setGraphHours(_ hours: Int) {
        var cfg = config
        cfg.graphHours = hours
        try? saveConfig(cfg)
        render()
    }

    private func didSignIn(user: String, password: String, region: String, client: DexcomClient) {
        let previous = config.dexcomUsername
        if !previous.isEmpty && previous != user { Keychain.delete(account: previous) }
        Keychain.save(password, account: user)
        var cfg = config
        cfg.dexcomUsername = user
        cfg.dexcomRegion = region
        try? saveConfig(cfg)
        dexcom = client
        authError = nil
        lastError = nil
        lateRetries = 0
        refresh()
    }

    @objc private func signOut() {
        if !config.dexcomUsername.isEmpty { Keychain.delete(account: config.dexcomUsername) }
        var cfg = config
        cfg.dexcomUsername = ""
        try? saveConfig(cfg)
        dexcom = nil
        authError = nil
        last = nil
        lastError = nil
        didAutoPrompt = true  // don't pop the window right after signing out
        refresh()
    }

    // MARK: Rendering

    private func setStatus(color: NSColor, text: String?, hollow: Bool = false, signalLoss: Bool = false) {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let gray = NSColor.secondaryLabelColor
        if signalLoss {
            // Gray "no signal" icon + last value and its age, so it can't pass for a live reading.
            button.image = signalLossImage(gray, pointSize: 12) ?? dotImage(gray, hollow: true)
            if let text, config.menuBarStyle != "dot" {
                button.imagePosition = .imageLeft
                button.attributedTitle = NSAttributedString(string: " " + text, attributes: [
                    .font: font, .foregroundColor: gray])
            } else {
                button.imagePosition = .imageOnly
                button.title = ""
            }
            return
        }
        let style = config.menuBarStyle
        if style == "number", let text {
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: hollow ? gray : color])
        } else if style == "dotNumber", let text {
            button.image = dotImage(color, hollow: hollow)
            button.imagePosition = .imageLeft
            button.attributedTitle = NSAttributedString(string: " " + text, attributes: [
                .font: font, .foregroundColor: hollow ? gray : NSColor.labelColor])
        } else {
            button.image = dotImage(color, hollow: hollow)
            button.imagePosition = .imageOnly
            button.title = ""
        }
    }

    private func render() {
        let cfg = config
        let units = cfg.units
        let now = Date()
        let gray = NSColor.secondaryLabelColor

        // Not signed in, or the saved password stopped working: the item opens the sign-in panel.
        if needsLogin || authError != nil {
            setStatus(color: gray, text: nil, hollow: true)
            statusItem.button?.setAccessibilityLabel("Sugarcane: sign in to Dexcom")
            dashPopover.performClose(nil)
            return
        }

        var model = DashboardModel()
        model.configError = configError
        model.config = cfg
        model.now = now
        model.units = units
        model.hours = cfg.graphHours
        model.low = cfg.low
        model.high = cfg.high
        model.account = "Dexcom: \(cfg.dexcomUsername) (\(DexcomRegion.named(cfg.dexcomRegion).label))"
        model.nextCheck = nextFetchAt.map { "Next check at \(fmtClock($0, seconds: true))" } ?? ""
        if isAppBundle, #available(macOS 13.0, *) {
            model.openAtLogin = SMAppService.mainApp.status == .enabled
        }
        defer { dashboard.update(model) }

        guard let snap = last, let latest = snap.readings.first else {
            setStatus(color: gray, text: nil, hollow: true)
            statusItem.button?.setAccessibilityLabel("Glucose: no data")
            model.placeholder = lastError.map { "Couldn't load data: \($0)" } ?? "Loading…"
            return
        }

        let bg = latest.sgv
        let age = now.timeIntervalSince(latest.date)
        let minutes = Int(age / 60)
        let delta: Double? = snap.readings.count > 1 ? bg - snap.readings[1].sgv : nil
        let direction = snap.direction ?? ""
        let arrow = TREND_ARROWS[direction] ?? ""
        let trendText = TREND_DESCRIPTIONS[direction] ?? "unknown"
        let (state, color) = rangeState(bg, cfg)
        let signalLoss = isSignalLoss

        model.value = fmtBG(bg, units)
        model.arrow = arrow
        if signalLoss {
            // Menu bar: gray "no signal" icon + last value and its age
            setStatus(color: gray, text: "\(fmtBG(bg, units)) · \(minutes)m", signalLoss: true)
            statusItem.button?.setAccessibilityLabel(
                "Signal loss. Last reading \(fmtBG(bg, units)) \(units), \(minutes) minutes ago")
            model.valueColor = Theme.secondary
            model.state = "Signal loss"
            model.stateColor = Theme.accent
            model.subtitle = "No new reading since \(fmtClock(latest.date))  ·  \(fmtAge(age))"
            model.hint = "Keep your phone near you with the Dexcom app open. "
                + "Missed readings fill in when the signal returns."
            model.gapFrom = latest.date
        } else {
            let barText = "\(fmtBG(bg, units)) \(arrow)".trimmingCharacters(in: .whitespaces)
            setStatus(color: color, text: barText)
            statusItem.button?.setAccessibilityLabel("Glucose \(fmtBG(bg, units)) \(units), \(trendText), \(state)")
            model.valueColor = Theme.color(bg, cfg)
            model.state = state
            model.stateColor = Theme.color(bg, cfg)
            let deltaText = fmtDelta(delta, units)
            model.subtitle = (deltaText.isEmpty ? "" : "\(deltaText) \(units)  ·  ") + fmtAge(age)
        }
        if let err = lastError {
            model.message = "Couldn't reach Dexcom: \(err)"
        }

        // The chosen period, as a graph you can hover, and its stats
        let span = Double(cfg.graphHours) * 3600
        let period = snap.readings.filter { now.timeIntervalSince($0.date) <= span }
        let all = Array(snap.readings.reversed())  // oldest first
        for r in period.reversed() {
            let isLatest = r.date == latest.date
            var pointArrow = isLatest ? arrow : ""
            if !isLatest, let i = all.firstIndex(where: { $0.date == r.date }), i > 0 {
                pointArrow = TREND_ARROWS[directionFromDelta(r.sgv - all[i - 1].sgv)] ?? ""
            }
            model.points.append(GraphView.Point(date: r.date, value: r.sgv, arrow: pointArrow,
                                                color: Theme.color(r.sgv, cfg)))
        }
        if !period.isEmpty {
            let count = Double(period.count)
            func share(_ n: Int) -> String { "\(Int((Double(n) / count * 100).rounded()))%" }
            model.average = fmtBG(period.reduce(0) { $0 + $1.sgv } / count, units)
            model.inRange = share(period.filter { $0.sgv >= cfg.low && $0.sgv <= cfg.high }.count)
            model.lowShare = share(period.filter { $0.sgv < cfg.low }.count)
            model.highShare = share(period.filter { $0.sgv > cfg.high }.count)
        }
    }

    // MARK: Actions

    /// ⌘, : the settings page of the panel.
    @objc func openSettings() {
        guard !needsLogin, authError == nil else { return }
        if !dashPopover.isShown { statusItemClicked() }
        dashboard.showSettings()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

@main
struct SugarcaneMain {
    @MainActor
    static func main() {
        // Only one Sugarcane at a time (e.g. the downloaded app and a developer build).
        let me = ProcessInfo.processInfo.processIdentifier
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.localizedName == "Sugarcane" && $0.processIdentifier != me
        }) {
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon

        // Hidden menus: ⌘R / ⌘, / ⌘Q while the panel is open, and an Edit menu so
        // ⌘V / ⌘C / ⌘A work in the sign-in fields.
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Sugarcane")
        for (title, selector, key) in [("Refresh", #selector(AppDelegate.refreshNow), "r"),
                                       ("Settings…", #selector(AppDelegate.openSettings), ","),
                                       ("Quit Sugarcane", #selector(AppDelegate.quit), "q")] {
            appMenu.addItem(withTitle: title, action: selector, keyEquivalent: key).target = delegate
        }
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        app.mainMenu = mainMenu

        // NSApplication holds its delegate weakly; keep ours alive for the app's lifetime,
        // otherwise an optimized build can release it before launch and nothing appears.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
