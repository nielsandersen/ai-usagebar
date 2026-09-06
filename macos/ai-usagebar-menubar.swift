// ai-usagebar-menubar — macOS menu bar app for ai-usagebar.
//
// Shows ai-usagebar's 5-hour (session), weekly, and optional extra-usage
// bars in the macOS menu bar, next to the clock, with a native dropdown and
// a Preferences window (⌘,). Mirrors the GNOME Shell extension: same binary,
// same One Dark colors and severity thresholds. Runs as a menu-bar agent.
//
// Settings persist in UserDefaults (edit them in Preferences, no rebuild).
//
// Build:  swiftc -O -parse-as-library ai-usagebar-menubar.swift -o ai-usagebar-menubar
//         (needs the Xcode command-line tools: `xcode-select --install`)
// Run:    ./ai-usagebar-menubar &      (or ./install-agent.sh for login start)
// macOS:  12+ (Monterey) for the Preferences window; menu bar works on 10.15+.
//
// First, on the Mac: run `claude` once so the OAuth creds land in the login
// Keychain — ai-usagebar reads them there (src/anthropic/keychain.rs).

import Cocoa
import SwiftUI
import Carbon.HIToolbox  // RegisterEventHotKey for the global vendor-swap shortcut

// ─── Settings (persisted in UserDefaults; edit in Preferences) ───────────
let DEF = UserDefaults.standard

let SETTINGS_DEFAULTS: [String: Any] = [
    "vendor": "anthropic",
    "interval": 30.0,
    "barWidth": 8,
    "showSession": true,
    "showWeekly": true,
    "showExtra": false,
    "showPercent": true,
    "showBars": true,
    "showMeta": true,
    "barStyle": "block",
    "menuBarMode": "compact",
    "menuBarGlyph": "dot",
    "colorLow": "#98c379",
    "colorMid": "#e5c07b",
    "colorHigh": "#d19a66",
    "colorCritical": "#e06c75",
    "colorEmpty": "#3e4451",
    "binaryPath": "",
]

var VENDOR: String { DEF.string(forKey: "vendor") ?? "anthropic" }
var INTERVAL: Double { let v = DEF.double(forKey: "interval"); return v > 0 ? v : 30 }
/// Upper bound on one `ai-usagebar` invocation. It can block on the cache
/// flock (up to 15s) and then refresh OAuth over the network, so without a
/// bound a hung run holds a worker indefinitely and the panel simply stops
/// updating with no explanation. Matches the GNOME extension's own timeout.
let REFRESH_TIMEOUT: Double = 45
var BAR_WIDTH: Int { max(4, min(20, DEF.integer(forKey: "barWidth"))) }
let MENU_BAR_W = 14
var SHOW_SESSION: Bool { DEF.bool(forKey: "showSession") }
var SHOW_WEEKLY: Bool { DEF.bool(forKey: "showWeekly") }
var SHOW_EXTRA: Bool { DEF.bool(forKey: "showExtra") }
var SHOW_PERCENT: Bool { DEF.bool(forKey: "showPercent") }
var SHOW_BARS: Bool { DEF.bool(forKey: "showBars") }
// Layout of the progress indicator: "block" (default, text bars ░█) or "ring"
// (a Core Graphics arc image). Both honor the meta marker the same way.
var BAR_STYLE: String { DEF.string(forKey: "barStyle") ?? "block" }
/// Menu-bar face: "icon" (template ring only), "compact" (ring + worst %),
/// "text" (full readout). Unknown values fall back to compact.
func menuBarMode(_ raw: String?) -> String {
    ["icon", "compact", "text"].contains(raw ?? "") ? raw! : "compact"
}
var MENUBAR_MODE: String { menuBarMode(DEF.string(forKey: "menuBarMode")) }
/// Which glyph stands for a provider: "dot" (the default anonymous severity
/// dot) or "mark" (its own silhouette). Unknown values fall back to the dot —
/// the face that works for every provider, mark or no mark.
func menuBarGlyph(_ raw: String?) -> String {
    ["dot", "mark"].contains(raw ?? "") ? raw! : "dot"
}
var MENUBAR_GLYPH: String { menuBarGlyph(DEF.string(forKey: "menuBarGlyph")) }
var COLOR_LOW: String { DEF.string(forKey: "colorLow") ?? "#98c379" }
var COLOR_MID: String { DEF.string(forKey: "colorMid") ?? "#e5c07b" }
var COLOR_HIGH: String { DEF.string(forKey: "colorHigh") ?? "#d19a66" }
var COLOR_CRITICAL: String { DEF.string(forKey: "colorCritical") ?? "#e06c75" }
var COLOR_EMPTY: String { DEF.string(forKey: "colorEmpty") ?? "#3e4451" }
// Meta reference: draw a pace marker at the elapsed-time position and flag the
// over-meta segment of the fill. Off = plain absolute-usage bars, no marker.
var SHOW_META: Bool { DEF.bool(forKey: "showMeta") }
// The meta marker is a fixed blue, matching the binary's default theme `marker`
// color and distinct from the over-pace warning fill.
let COLOR_MARKER = "#61afef"
let POINT_MID_MIN = -10
let POINT_CRITICAL_MIN = 10

// The `{scoped_*}` fields (10-12) carry the model-scoped weekly window (e.g.
// "Fable") from the API's `limits[]`; empty on older binaries → the row falls
// back to the flat `{sonnet_*}` window and the "Sonnet only" label. The trailing
// `*_elapsed` fields (13-15) carry the meta (pace) position; `vendor_short`
// (16) lets balance-only vendors suppress meaningless quota rows. The balance
// fields (17-22) carry the per-vendor credits — only the selected vendor's is
// populated — and the `aapi_*` fields (23-26) carry the Anthropic API headline
// plus its spend-vs-limit bar. `cursor_total_pct` (27) is followed by the
// Antigravity-only fourth-window fields (28-30). A final literal sentinel
// absorbs the widget's stale suffix, preserving these fields.
let FORMAT = "{plan};;{session_pct};;{session_reset};;{weekly_pct};;{weekly_reset};;" +
             "{sonnet_pct};;{sonnet_reset};;{extra_pct};;{extra_spent};;{extra_limit};;" +
             "{scoped_model};;{scoped_pct};;{scoped_reset};;" +
             "{session_elapsed};;{weekly_elapsed};;{scoped_elapsed};;{vendor_short};;{or_balance};;" +
             "{ds_balance};;{kilo_balance};;{nv_balance};;{km_balance};;{grok_balance};;" +
             "{aapi_headline};;{aapi_pct};;{aapi_spent};;{aapi_limit};;{cursor_total_pct};;" +
             "{extra_model};;{extra_reset};;{extra_elapsed}"

let FORMAT_WITH_SENTINEL = FORMAT + ";;__aiub_end__"

// ─── Color / text helpers ────────────────────────────────────────────────
func hexColor(_ hex: String) -> NSColor {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return .labelColor }
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255.0,
                   green: CGFloat((v >> 8) & 0xff) / 255.0,
                   blue: CGFloat(v & 0xff) / 255.0,
                   alpha: 1.0)
}

func colorForPct(_ pct: Int) -> NSColor {
    if pct >= 90 { return hexColor(COLOR_CRITICAL) }
    if pct >= 75 { return hexColor(COLOR_HIGH) }
    if pct >= 50 { return hexColor(COLOR_MID) }
    return hexColor(COLOR_LOW)
}

// Matches pacing::pace_severity: < -10 low, -10...0 mid, 1...9 high, >= 10 critical.
func colorForDelta(_ delta: Int) -> NSColor {
    if delta >= POINT_CRITICAL_MIN { return hexColor(COLOR_CRITICAL) }
    if delta > 0 { return hexColor(COLOR_HIGH) }
    if delta >= POINT_MID_MIN { return hexColor(COLOR_MID) }
    return hexColor(COLOR_LOW)
}

func menuBarTextColor(_ appearance: NSAppearance, secondary: Bool = false) -> NSColor {
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let color = isDark ? NSColor.white : NSColor.black
    return secondary ? color.withAlphaComponent(0.72) : color
}

// The ring track needs to stay visible over both light and dark menu bars /
// dropdowns, but it is scenery, not data: it says where the arc could go, so it
// must never compete with the arc that says where it is. A neutral wash of the
// foreground at a low alpha does that in either appearance. COLOR_EMPTY is
// deliberately not used — it is a solid charcoal picked for the block bar's ░
// glyphs, and at ring line widths it reads as a second filled arc.
func ringTrackColor(_ appearance: NSAppearance) -> NSColor {
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return isDark ? NSColor.white.withAlphaComponent(0.18)
                  : NSColor.black.withAlphaComponent(0.12)
}

// A missing reset keeps its row visible but never has a meaningful pace marker.
func markerElapsed(reset: String, elapsed: Int?) -> Int? {
    guard !reset.isEmpty, reset != "—" else { return nil }
    return elapsed
}

/// Squeeze a countdown ("4d 1h", "2h 05m", "now") down to its leading unit for
/// the overview status-bar title, where every character fights for space:
/// "4d 1h" → "4d", "2h 05m" → "2h", "0h 05m" → "5m". Missing/em-dash → nil.
func shortReset(_ r: String) -> String? {
    guard !r.isEmpty, r != "—" else { return nil }
    let parts = r.split(separator: " ")
    guard let first = parts.first else { return nil }
    if first == "0h", parts.count > 1 {
        let m = parts[1].drop(while: { $0 == "0" })
        return m == "m" ? "0m" : String(m)
    }
    return String(first)
}

/// Monospace ONLY for the block-bar glyphs (░█ need fixed advance).
let barFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
/// HIG text: menus in the system menu font, numerics in monospaced digits
/// so values change without the row (or the menu bar item) jittering.
let menuLabelFont = NSFont.menuFont(ofSize: 0)
let menuDigitFont = NSFont.monospacedDigitSystemFont(
    ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
let statusFont = NSFont.menuBarFont(ofSize: 0)
let statusDigitFont = NSFont.monospacedDigitSystemFont(
    ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)

/// Right-aligned numeric columns via tab stops, so SF Pro rows align without
/// monospace space-padding. Locations in points from the item's leading edge.
///
/// Every location is measured rather than guessed, because a guessed grid is
/// what left ~45 pt of air before the gauge and ~90 pt after the percentage:
/// the stops were sized for provider names in rows that no longer carry
/// numbers. The rows that do are labelled "Session", "Weekly", "Fable",
/// "Extra usage" — 32–72 pt of text against a 128 pt column.
///
/// The label column is therefore sized per render, to the widest label the
/// menu is about to draw (see `menuLabelColumn`), and the long tail is clipped
/// (see `fitMenuLabel`) so one stray model name cannot stretch the grid for
/// every other row. Measured in `menuLabelFont` at 13 pt:
///
///     Fable 32.5 · Weekly 43.7 · Session 47.1 · Extra usage 71.1
///     Other Models 82.1 · Cursor Models 88.4 · Gemini Weekly 89.3
///     Claude & GPT OSS Weekly 161.9 — the outlier the clip exists for
let MENU_LABEL_MAX: CGFloat = 96   // fits every real two-word label
let MENU_LABEL_GAP: CGFloat = 12   // label → gauge breathing room

/// Indicator + value column: the widest percentage ("100%" = 36.3 pt in
/// menuDigitFont) right-aligned clear of the gauge, plus ~8 pt. The gauge is
/// the one width that is not constant — a ring is a single 18 pt attachment, a
/// block bar is MENU_BAR_W (14) monospaced glyphs = 112.5 pt — so the numeric
/// columns sit behind whichever style is on.
let MENU_VALUE_RING: CGFloat = 62    // 18 ring + 36.3 pct + 8
let MENU_VALUE_BLOCK: CGFloat = 157  // 112.5 bar + 36.3 pct + 8
/// Reset column: the widest countdown ("↺ 12h 59m" = 69 pt) plus ~8 pt.
let MENU_RESET_W: CGFloat = 77

func menuTextWidth(_ s: String, _ font: NSFont) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: font]).width
}

/// Clip a number-carrying row's label so it cannot overrun the label column —
/// an overrunning label does not merely look wide, it pushes the gauge onto
/// the NEXT tab stop and breaks the row's alignment outright.
///
/// A character cap alone does not bound the width (14 wide glyphs,
/// "Claude & GPT O…", still measure 108 pt against a 96 pt column), so the
/// character cap keeps labels short and a width cap makes that guarantee.
func fitMenuLabel(_ s: String) -> String {
    var out = s.count > 14 ? String(s.prefix(14)) + "…" : s
    while menuTextWidth(out, menuLabelFont) > MENU_LABEL_MAX, out.count > 2 {
        out = String(out.dropLast(out.hasSuffix("…") ? 2 : 1)) + "…"
    }
    return out
}

/// Where the gauge column starts, for one render's worth of labels. Sizing to
/// the labels actually on screen is what keeps the grid tight: a menu of
/// Session/Weekly/Fable rows gets an 84 pt column, one carrying "Gemini
/// Weekly" gets 102, and neither pays for the other.
func menuLabelColumn(_ labels: [String]) -> CGFloat {
    let widest = labels.map { menuTextWidth(fitMenuLabel($0), menuLabelFont) }.max() ?? 0
    return ceil(widest) + MENU_LABEL_GAP
}

/// `wideValue` drops the percentage column. A right-aligned tab stop only
/// right-aligns a run that FITS in the space before it; a longer one starts at
/// the pen and overflows past the stop. A currency pair ("€24.53 / €50.00" =
/// 100 pt) does not fit the 77 pt value column, so it used to straggle ~25 pt
/// beyond where every reset above it ended. Those rows carry no countdown, so
/// handing them the value and reset columns as one span (139 pt) lets them
/// right-align flush on the reset stop with room to spare.
func menuRowStyle(_ label: CGFloat, wideValue: Bool = false) -> NSParagraphStyle {
    let s = NSMutableParagraphStyle()
    let value = label + (BAR_STYLE == "ring" ? MENU_VALUE_RING : MENU_VALUE_BLOCK)
    var stops = [NSTextTab(textAlignment: .left, location: label)]
    if !wideValue { stops.append(NSTextTab(textAlignment: .right, location: value)) }
    stops.append(NSTextTab(textAlignment: .right, location: value + MENU_RESET_W))
    s.tabStops = stops
    s.lineBreakMode = .byClipping
    return s
}

/// A row's value is "wide" when it is not a percentage AND has no countdown
/// to displace — the currency pair and the credit balance. Both conditions
/// matter: the wide style has no percentage column, so a row that still owed a
/// reset would have nowhere to put it.
func menuValueIsWide(_ value: String, _ reset: String?) -> Bool {
    !value.hasSuffix("%") && (reset ?? "").isEmpty
}

func run(_ s: String, _ color: NSColor, _ font: NSFont = barFont) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.foregroundColor: color, .font: font])
}

// Block bar. When `elapsed` (0..100) is known and the meta is on, the fill stays
// in the calm absolute-usage color up to a blue marker at the elapsed position,
// and only the part that overshoots the meta (how far ahead of pace you are →
// risk of paid extra usage) is painted in the warning color. Otherwise it's a
// plain absolute-color bar with no marker.
func barAttr(pct: Int, width: Int, elapsed: Int?) -> NSAttributedString {
    let p = max(0, min(100, pct))
    let filled = Int((Double(p) * Double(width) / 100.0).rounded())
    let out = NSMutableAttributedString()

    guard SHOW_META, let elapsedVal = elapsed else {
        out.append(run(String(repeating: "█", count: filled), colorForPct(p)))
        out.append(run(String(repeating: "░", count: max(0, width - filled)), hexColor(COLOR_EMPTY)))
        return out
    }

    let e = max(0, min(100, elapsedVal))
    let base = colorForPct(p)        // on-track portion → calm absolute color
    let over = colorForDelta(p - e)  // excess beyond the meta → pace warning
    var m = Int(Double(e) * Double(width) / 100.0) // floor
    if m > width - 1 { m = width - 1 }
    if m < 0 { m = 0 }
    let preF = min(filled, m)
    let postF = filled > m + 1 ? filled - m - 1 : 0
    let preE = m - preF
    let postE = width - m - 1 - postF
    out.append(run(String(repeating: "█", count: max(0, preF)), base))
    out.append(run(String(repeating: "░", count: max(0, preE)), hexColor(COLOR_EMPTY)))
    out.append(run("│", hexColor(COLOR_MARKER)))
    out.append(run(String(repeating: "█", count: max(0, postF)), over))
    out.append(run(String(repeating: "░", count: max(0, postE)), hexColor(COLOR_EMPTY)))
    return out
}

// Ring indicator (optional layout). A Core Graphics arc whose sweep is the
// usage fraction, painted in the severity color, over a faint track. When the
// meta is on, the elapsed position marks a blue tick and the arc beyond it (how
// far ahead of pace you are) shifts to the pace-warning color — the same idea
// as the block bar, just radial. The image is rendered as an attachment so it
// composes in an attributed string alongside the percentage text.
/// Arc geometry for a ring segment, in degrees for `NSBezierPath.appendArc`.
/// The ring starts at 12 o'clock (`startRad = -π/2`) and fills clockwise, so a
/// segment [from, to] spans `[start - 2π·from, start - 2π·to]`. Pure and tested
/// so the pace-arc regression (overshoot restarting at 12h) cannot return.
func arcAngles(from fromFraction: CGFloat, to toFraction: CGFloat,
               startRad: CGFloat = -.pi / 2) -> (startDeg: CGFloat, endDeg: CGFloat) {
    ((startRad - 2 * .pi * fromFraction) * 180 / .pi,
     (startRad - 2 * .pi * toFraction) * 180 / .pi)
}

func ringImage(pct: Int, size: CGFloat, elapsed: Int?, appearance: NSAppearance) -> NSImage {
    let p = CGFloat(max(0, min(100, pct))) / 100.0
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    let box = NSRect(x: 0, y: 0, width: size, height: size)
    let lw = max(1.5, size * 0.11)
    let inset = lw / 2 + 0.5
    let rect = box.insetBy(dx: inset, dy: inset)
    let start: CGFloat = -.pi / 2

    // Track (empty background ring).
    let track = NSBezierPath()
    track.appendArc(withCenter: CGPoint(x: size / 2, y: size / 2),
                    radius: rect.width / 2, startAngle: 0, endAngle: 360)
    track.lineWidth = lw
    ringTrackColor(appearance).setStroke()
    track.stroke()

    // Filled arc. With the meta on, the part behind the pace marker keeps the
    // calm absolute color and the overshoot turns warning; otherwise a single
    // severity-colored sweep. The helper draws [from, to] so the overshoot can
    // continue from the elapsed marker to pct instead of restarting at 12h.
    let drawArc = { (fromFraction: CGFloat, toFraction: CGFloat, color: NSColor) in
        guard toFraction > fromFraction else { return }
        let a = arcAngles(from: fromFraction, to: toFraction, startRad: start)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: CGPoint(x: size / 2, y: size / 2),
                      radius: rect.width / 2,
                      startAngle: a.startDeg,
                      endAngle: a.endDeg,
                      clockwise: true)
        arc.lineWidth = lw
        arc.lineCapStyle = .round   // fill reads as a stroke, not a pie slice
        color.setStroke()
        arc.stroke()
    }
    let pInt = max(0, min(100, pct))
    if SHOW_META, let elapsedVal = elapsed {
        let e = max(0, min(100, elapsedVal))
        let base = colorForPct(pInt)
        let over = colorForDelta(pInt - e)
        let eFrac = CGFloat(e) / 100.0
        let boundary = min(p, eFrac)
        drawArc(0, boundary, base)
        if p > eFrac { drawArc(boundary, p, over) }
        // Pace tick at the elapsed position.
        let tickAngle = start - 2 * .pi * eFrac
        let c = CGPoint(x: size / 2, y: size / 2)
        let r = rect.width / 2
        let tick = NSBezierPath()
        tick.move(to: CGPoint(x: c.x + (r - lw) * cos(tickAngle),
                              y: c.y + (r - lw) * sin(tickAngle)))
        tick.line(to: CGPoint(x: c.x + (r + lw) * cos(tickAngle),
                              y: c.y + (r + lw) * sin(tickAngle)))
        tick.lineWidth = max(1, lw * 0.5)
        hexColor(COLOR_MARKER).setStroke()
        tick.stroke()
    } else {
        drawArc(0, p, colorForPct(pInt))
    }
    img.unlockFocus()
    img.isTemplate = false
    return img
}

final class ColoredAttachmentCell: NSTextAttachmentCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let image else { return }
        image.draw(in: cellFrame,
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1.0,
                   respectFlipped: true,
                   hints: nil)
    }
}

/// One provider as the status bar draws it: a severity dot and the bare number
/// beside it. `pct == nil` is a dot with nothing to grade — a credit balance, a
/// loading ellipsis, raw output from the binary.
struct StatusEntry {
    let pct: Int?
    let text: String
    /// Which provider this entry is, so the bar can draw its mark. Stored as
    /// the raw id (`anthropic@work`, `anthropic-desktop@…`); the lookup folds
    /// it to a base vendor, so every Claude account gets the same creature.
    /// Empty where there is no provider to name — a loading placeholder, or
    /// output from the binary nothing could parse.
    var vendorId: String = ""
}

/// The status bar's calm tier, for a dot with no warning to give and for the
/// rule between providers: dim enough to read as punctuation next to the number
/// it belongs to, still legible on either menu bar. Baked for one appearance
/// rather than left dynamic, because an attachment image is drawn once instead
/// of resolved at paint time; an appearance flip re-renders the panel anyway.
func statusDimColor(_ appearance: NSAppearance) -> NSColor {
    menuBarTextColor(appearance).withAlphaComponent(0.5)
}

/// What color a percentage is in the status bar: the same tiers as the
/// dropdown (`colorForPct`), low tier neutral.
///
/// Everything from MID (50) up matches the dropdown exactly, so the bar can no
/// longer read calm about a number the menu has already turned amber. The low
/// tier is the one deliberate difference: the dropdown can afford COLOR_LOW's
/// green because it is a table being read, while a permanently green dot in
/// the menu bar is a light that only ever means "ignore me". `nil` is nothing
/// to grade — a credit balance, a loading ellipsis, raw output.
func tierColor(pct: Int?, appearance: NSAppearance) -> NSColor {
    switch pct {
    case .some(let p) where p >= 90: return hexColor(COLOR_CRITICAL)
    case .some(let p) where p >= 75: return hexColor(COLOR_HIGH)
    case .some(let p) where p >= 50: return hexColor(COLOR_MID)
    default: return statusDimColor(appearance)
    }
}

/// One provider's severity, as a dot sized to sit beside the menu bar's digits.
/// `trailing` is transparent padding baked into the image: spacing here is
/// measured in points, and the width of a space glyph follows the font.
func statusDotImage(pct: Int?, appearance: NSAppearance,
                    size: CGFloat = 7, trailing: CGFloat = 3) -> NSImage {
    let img = NSImage(size: NSSize(width: size + trailing, height: size))
    img.lockFocus()
    tierColor(pct: pct, appearance: appearance).setFill()
    NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
    img.unlockFocus()
    return img
}

/// The mark between two providers: a short rule at digit height, so the bar
/// reads as pairs instead of one long number. Deliberately not a pipe glyph —
/// a full-height bar would out-shout the dots it is separating. Padding either
/// side is baked in for the same reason the dot's is.
func statusDividerImage(appearance: NSAppearance,
                        height: CGFloat = 9, gap: CGFloat = 5) -> NSImage {
    let width: CGFloat = 1
    let img = NSImage(size: NSSize(width: width + gap * 2, height: height))
    img.lockFocus()
    statusDimColor(appearance).setFill()
    NSBezierPath(rect: NSRect(x: gap, y: 0, width: width, height: height)).fill()
    img.unlockFocus()
    return img
}

/// Wrap a status-bar glyph as an inline attachment, centered on the digits' cap
/// height rather than left sitting on the baseline — the same correction
/// ringAttr makes, measured against the font the numbers are set in.
func statusAttachment(_ image: NSImage) -> NSAttributedString {
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.attachmentCell = ColoredAttachmentCell(imageCell: image)
    let dy = (statusDigitFont.capHeight - image.size.height) / 2
    attachment.bounds = NSRect(x: 0, y: dy,
                               width: image.size.width, height: image.size.height)
    return NSAttributedString(attachment: attachment)
}

/// The provider marks — the "Cuties". Exported from the design
/// playground (`tools/ai-usagebar-en/playground/index.html`) by
/// `marks_export.py`. Edit the shapes THERE and re-run `./apply.sh` —
/// this table is generated, never typed by hand.
/// Variant picks resolved: claude C, deepseek A, openai A.
///
/// Coordinates are SVG, viewBox 0 0 20 20, y pointing DOWN. A part is
/// either filled (`evenOdd` picks the winding rule, so a detail cut into
/// the silhouette is a real hole the menu bar shows through) or stroked
/// at `stroke` viewBox units with round caps and joins.
struct MarkPart {
    let d: String
    let evenOdd: Bool
    let stroke: CGFloat?
}

/// Stable order for anything that shows the whole set (the render harness).
let PROVIDER_MARK_ORDER: [String] = [
    "claude", "anthropicApi", "openai", "gemini", "grok", "deepseek",
    "moonshot", "kimi", "zai", "openrouter", "cursor", "kilo", "novita",
    "mistral", "meta"
]

let PROVIDER_MARKS: [String: [MarkPart]] = [
    "claude": [
        MarkPart(d: "M4.5 3 H15.5 C16.3 3 17 3.7 17 4.5 V13.5 C17 14.3 16.3 15 15.5 15 H4.5 C3.7 15 3 14.3 3 13.5 V4.5 C3 3.7 3.7 3 4.5 3 Z M6 6.5 H8 V11 H6 Z M12 6.5 H14 V11 H12 Z M5 15 H7.5 V17.5 C7.5 17.8 7.3 18 7 18 H5.5 C5.2 18 5 17.8 5 17.5 Z M12.5 15 H15 V17.5 C15 17.8 14.8 18 14.5 18 H13 C12.7 18 12.5 17.8 12.5 17.5 Z M1 8 H3 V11 H1 Z M17 8 H19 V11 H17 Z",
                 evenOdd: true, stroke: nil),
    ],
    "anthropicApi": [
        MarkPart(d: "M6 3 H14 C16.2 3 18 4.8 18 7 V13 C18 15.2 16.2 17 14 17 H6 C3.8 17 2 15.2 2 13 V7 C2 4.8 3.8 3 6 3 Z M6 5 H14 C15.11 5 16 5.89 16 7 V13 C16 14.11 15.11 15 14 15 H6 C4.89 15 4 14.11 4 13 V7 C4 5.89 4.89 5 6 5 Z M5.6 6.5 L10.2 10 L5.6 13.5 L5.6 11 L6.9 10 L5.6 9 Z M11.9 11.7 L14.3 11.7 Q14.8 11.7 14.8 12.2 L14.8 13 Q14.8 13.5 14.3 13.5 L11.9 13.5 Q11.4 13.5 11.4 13 L11.4 12.2 Q11.4 11.7 11.9 11.7 Z",
                 evenOdd: true, stroke: nil),
    ],
    "openai": [
        MarkPart(d: "M10 2 L16.93 6 L16.93 14 L10 18 L3.07 14 L3.07 6 Z",
                 evenOdd: false, stroke: 2.5),
    ],
    "gemini": [
        MarkPart(d: "M10 1.5 Q11 9 18.5 10 Q11 11 10 18.5 Q9 11 1.5 10 Q9 9 10 1.5 Z",
                 evenOdd: false, stroke: nil),
    ],
    "grok": [
        MarkPart(d: "M4.4 4.4 L15.6 15.6 M15.6 4.4 L7.5 12.5",
                 evenOdd: false, stroke: 2.5),
    ],
    "deepseek": [
        MarkPart(d: "M3.2 11.6 C3.2 8.6 5.6 6.8 8.4 6.8 C10.9 6.8 12.8 8 13.8 9.8 L17.4 5.6 C18.2 4.7 19.2 5.8 18.5 6.8 L15.6 10.8 C15.2 13.4 12.4 15.4 9 15.4 C5.6 15.4 3.2 13.8 3.2 11.6 Z M6.6 9.15 C7.18 9.15 7.65 9.62 7.65 10.2 C7.65 10.78 7.18 11.25 6.6 11.25 C6.02 11.25 5.55 10.78 5.55 10.2 C5.55 9.62 6.02 9.15 6.6 9.15 Z",
                 evenOdd: true, stroke: nil),
    ],
    "moonshot": [
        MarkPart(d: "M15.09 3.83 C11.83 1.14 7.05 1.45 4.16 4.53 C1.28 7.6 1.28 12.4 4.16 15.47 C7.05 18.55 11.83 18.86 15.09 16.17 C12.49 16.89 9.72 15.89 8.16 13.68 C6.61 11.47 6.61 8.53 8.16 6.32 C9.72 4.11 12.49 3.11 15.09 3.83 Z",
                 evenOdd: false, stroke: nil),
    ],
    "kimi": [
        MarkPart(d: "M6 3 H14 C16.2 3 18 4.8 18 7 V13 C18 15.2 16.2 17 14 17 H6 C3.8 17 2 15.2 2 13 V7 C2 4.8 3.8 3 6 3 Z M6 5 H14 C15.11 5 16 5.89 16 7 V13 C16 14.11 15.11 15 14 15 H6 C4.89 15 4 14.11 4 13 V7 C4 5.89 4.89 5 6 5 Z M6.55 6.5 L7.85 6.5 Q8.2 6.5 8.2 6.85 L8.2 8.65 Q8.2 9 8.46 8.77 L10.74 6.73 Q11 6.5 11.35 6.5 L13.25 6.5 Q13.6 6.5 13.34 6.74 L10.06 9.76 Q9.8 10 10.06 10.24 L13.34 13.26 Q13.6 13.5 13.25 13.5 L11.35 13.5 Q11 13.5 10.74 13.27 L8.46 11.23 Q8.2 11 8.2 11.35 L8.2 13.15 Q8.2 13.5 7.85 13.5 L6.55 13.5 Q6.2 13.5 6.2 13.15 L6.2 6.85 Q6.2 6.5 6.55 6.5 Z",
                 evenOdd: true, stroke: nil),
    ],
    "zai": [
        MarkPart(d: "M14.34 2.21 L11.44 7.67 Q11.02 8.46 11.92 8.46 L16.92 8.46 Q17.82 8.46 17.13 9.04 L6.61 18 Q5.92 18.58 6.31 17.77 L8.93 12.35 Q9.32 11.54 8.42 11.54 L3.08 11.54 Q2.18 11.54 2.88 10.98 L14.06 1.98 Q14.76 1.42 14.34 2.21 Z",
                 evenOdd: false, stroke: nil),
    ],
    "openrouter": [
        MarkPart(d: "M4.6 4.6 L10 11 L15.4 4.6 M10 11 L10 17.4 M3.9 3.9 H5.3 V5.3 H3.9 Z M14.7 3.9 H16.1 V5.3 H14.7 Z M9.3 16.7 H10.7 V18.1 H9.3 Z",
                 evenOdd: false, stroke: 2.5),
    ],
    "cursor": [
        MarkPart(d: "M4 3.3 L4 15.7 Q4 16.6 4.65 15.98 L7.35 13.42 Q8 12.8 8.42 13.6 L10.18 17 Q10.6 17.8 11.4 17.4 L12.2 17 Q13 16.6 12.58 15.8 L10.92 12.6 Q10.5 11.8 11.4 11.8 L14.7 11.8 Q15.6 11.8 14.9 11.23 L4.7 2.97 Q4 2.4 4 3.3 Z",
                 evenOdd: false, stroke: nil),
    ],
    "kilo": [
        MarkPart(d: "M3.9 5.6 L4.9 5.6 Q6.4 5.6 6.4 7.1 L6.4 12.9 Q6.4 14.4 4.9 14.4 L3.9 14.4 Q2.4 14.4 2.4 12.9 L2.4 7.1 Q2.4 5.6 3.9 5.6 Z M15.1 5.6 L16.1 5.6 Q17.6 5.6 17.6 7.1 L17.6 12.9 Q17.6 14.4 16.1 14.4 L15.1 14.4 Q13.6 14.4 13.6 12.9 L13.6 7.1 Q13.6 5.6 15.1 5.6 Z M6.6 8.6 L13.4 8.6 Q14.4 8.6 14.4 9.6 L14.4 10.4 Q14.4 11.4 13.4 11.4 L6.6 11.4 Q5.6 11.4 5.6 10.4 L5.6 9.6 Q5.6 8.6 6.6 8.6 Z",
                 evenOdd: false, stroke: nil),
    ],
    "novita": [
        MarkPart(d: "M10.36 1.88 L11.99 5.88 Q12.35 6.76 13.3 6.83 L17.61 7.15 Q18.56 7.22 17.83 7.83 L14.53 10.62 Q13.8 11.24 14.03 12.16 L15.06 16.36 Q15.29 17.28 14.48 16.78 L10.81 14.5 Q10 14 9.19 14.5 L5.52 16.78 Q4.71 17.28 4.94 16.36 L5.97 12.16 Q6.2 11.24 5.47 10.62 L2.17 7.83 Q1.44 7.22 2.39 7.15 L6.7 6.83 Q7.65 6.76 8.01 5.88 L9.64 1.88 Q10 1 10.36 1.88 Z",
                 evenOdd: false, stroke: nil),
    ],
    "mistral": [
        MarkPart(d: "M2.6 15.3 L2.6 4.7 Q2.6 4 3.3 4 L4.9 4 Q5.6 4 5.97 4.59 L9.63 10.41 Q10 11 10.37 10.41 L14.03 4.59 Q14.4 4 15.1 4 L16.7 4 Q17.4 4 17.4 4.7 L17.4 15.3 Q17.4 16 16.7 16 L15.3 16 Q14.6 16 14.6 15.3 L14.6 9.1 Q14.6 8.4 14.21 8.98 L11.09 13.62 Q10.7 14.2 10 14.2 L10 14.2 Q9.3 14.2 8.91 13.62 L5.79 8.98 Q5.4 8.4 5.4 9.1 L5.4 15.3 Q5.4 16 4.7 16 L3.3 16 Q2.6 16 2.6 15.3 Z",
                 evenOdd: false, stroke: nil),
    ],
    "meta": [
        MarkPart(d: "M10 10 C8.4 6.8 6.8 6.4 5.4 7 C3.6 7.8 3.6 12.2 5.4 13 C6.8 13.6 8.4 13.2 10 10 C11.6 6.8 13.2 6.4 14.6 7 C16.4 7.8 16.4 12.2 14.6 13 C13.2 13.6 11.6 13.2 10 10 Z",
                 evenOdd: false, stroke: 2.5),
    ],
]

/// The mark box is 20 × 20 viewBox units, whatever size it is drawn at.
let MARK_BOX: CGFloat = 20

/// Vendor id → mark id. Keyed on the BASE vendor, so "anthropic@work" and a
/// Claude Desktop account both land on the same creature. Deliberately allowed
/// to be incomplete: a provider with no mark of its own draws its dot, which is
/// a face the bar already knows how to make.
let VENDOR_MARK_IDS: [String: String] = [
    "anthropic": "claude",
    "anthropic_api": "anthropicApi",
    "openai": "openai",
    "antigravity": "gemini",
    "grok": "grok",
    "deepseek": "deepseek",
    "moonshot": "moonshot",
    "kimi": "kimi",
    "zai": "zai",
    "openrouter": "openrouter",
    "cursor": "cursor",
    "kilo": "kilo",
    "novita": "novita",
]

/// The mark a vendor draws, or nil if it has none yet.
func markId(forVendor id: String) -> String? {
    id.isEmpty ? nil : VENDOR_MARK_IDS[baseVendorId(id)]
}

/// Parse an SVG path into an NSBezierPath, in the path's own coordinates
/// (viewBox units, y pointing DOWN — flipping is the caller's job).
///
/// ABSOLUTE `M L H V C Q Z` only, which is exactly what the playground authors
/// and `marks_export.py` enforces on the way out. The narrowness is the point:
/// a relative command or an arc quietly drawn as something else would put a
/// plausible but WRONG shape in the menu bar, so anything outside the set is
/// refused here — logged, and nil, which makes the caller fall back to the dot.
/// Q is folded into a cubic on the way in; NSBezierPath has no quadratic
/// segment, and the conversion is exact.
func bezierPath(svg d: String) -> NSBezierPath? {
    enum Token { case command(Character), number(CGFloat) }
    func reject(_ why: String) -> NSBezierPath? {
        NSLog("ai-usagebar: bad mark path (%@) in \"%@\"", why, d)
        assertionFailure("bad mark path (\(why)): \(d)")
        return nil
    }

    var tokens: [Token] = []
    let chars = Array(d)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" {
            i += 1
        } else if c.isLetter {
            guard "MLHVCQZ".contains(c) else { return reject("unsupported command \(c)") }
            tokens.append(.command(c))
            i += 1
        } else {
            var text = ""
            if c == "-" || c == "+" { text.append(c); i += 1 }
            while i < chars.count, chars[i].isNumber || chars[i] == "." {
                text.append(chars[i]); i += 1
            }
            guard let value = Double(text) else { return reject("not a number: \(text)") }
            tokens.append(.number(CGFloat(value)))
        }
    }

    let path = NSBezierPath()
    var at = 0
    var current = CGPoint.zero, subpathStart = CGPoint.zero
    var command: Character = " "
    var started = false
    /// The next `n` numbers, or nil if the command was handed fewer than it needs.
    func take(_ n: Int) -> [CGFloat]? {
        var out: [CGFloat] = []
        while out.count < n {
            guard at < tokens.count, case .number(let v) = tokens[at] else { return nil }
            out.append(v)
            at += 1
        }
        return out
    }

    while at < tokens.count {
        var explicit = false
        if case .command(let c) = tokens[at] { command = c; at += 1; explicit = true }
        guard command != " " else { return reject("numbers before any command") }
        guard started || command == "M" else { return reject("\(command) before the first M") }
        switch command {
        case "M":
            guard let a = take(2) else { return reject("M needs 2 numbers") }
            current = CGPoint(x: a[0], y: a[1])
            subpathStart = current
            path.move(to: current)
            started = true
            command = "L"   // SVG: extra coordinate pairs after an M are lines
        case "L":
            guard let a = take(2) else { return reject("L needs 2 numbers") }
            current = CGPoint(x: a[0], y: a[1])
            path.line(to: current)
        case "H":
            guard let a = take(1) else { return reject("H needs 1 number") }
            current.x = a[0]
            path.line(to: current)
        case "V":
            guard let a = take(1) else { return reject("V needs 1 number") }
            current.y = a[0]
            path.line(to: current)
        case "C":
            guard let a = take(6) else { return reject("C needs 6 numbers") }
            current = CGPoint(x: a[4], y: a[5])
            path.curve(to: current,
                       controlPoint1: CGPoint(x: a[0], y: a[1]),
                       controlPoint2: CGPoint(x: a[2], y: a[3]))
        case "Q":
            guard let a = take(4) else { return reject("Q needs 4 numbers") }
            // A quadratic is the cubic whose two controls sit two thirds of the
            // way from each end point toward the quadratic's single control.
            let q = CGPoint(x: a[0], y: a[1]), end = CGPoint(x: a[2], y: a[3])
            path.curve(to: end,
                       controlPoint1: CGPoint(x: current.x + 2.0 / 3.0 * (q.x - current.x),
                                              y: current.y + 2.0 / 3.0 * (q.y - current.y)),
                       controlPoint2: CGPoint(x: end.x + 2.0 / 3.0 * (q.x - end.x),
                                              y: end.y + 2.0 / 3.0 * (q.y - end.y)))
            current = end
        case "Z":
            guard explicit else { return reject("numbers after Z") }
            path.close()
            current = subpathStart
        default:
            return reject("unsupported command \(command)")
        }
    }
    guard started else { return reject("empty path") }
    return path
}

/// One provider's mark, drawn at the height the menu bar's digits are set at
/// and in the SAME tier color a dot would have taken — the glyph changes, the
/// severity language does not. Nil for an unknown id or an unparsable path, so
/// the caller can fall back to the dot; `trailing` is transparent padding baked
/// into the canvas, exactly as in `statusDotImage`.
func statusMarkImage(markId: String, pct: Int?, appearance: NSAppearance,
                     size: CGFloat = 10, trailing: CGFloat = 3) -> NSImage? {
    guard let parts = PROVIDER_MARKS[markId], !parts.isEmpty else { return nil }
    let scale = size / MARK_BOX
    // SVG's y grows downward and AppKit's grows up: scale and flip about the
    // box in one transform, so the path arrives in image coordinates.
    let flip = AffineTransform(m11: scale, m12: 0, m21: 0, m22: -scale, tX: 0, tY: size)
    var drawable: [(path: NSBezierPath, part: MarkPart)] = []
    for part in parts {
        guard let path = bezierPath(svg: part.d) else { return nil }
        path.transform(using: flip)
        drawable.append((path, part))
    }
    let img = NSImage(size: NSSize(width: size + trailing, height: size))
    img.lockFocus()
    tierColor(pct: pct, appearance: appearance).set()
    for (path, part) in drawable {
        if let stroke = part.stroke {
            path.lineWidth = stroke * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        } else {
            // Details are cut as real holes, so the menu bar shows through them
            // instead of the mark carrying a second, painted-on color.
            path.windingRule = part.evenOdd ? .evenOdd : .nonZero
            path.fill()
        }
    }
    img.unlockFocus()
    return img
}

/// Every mark path, parsed. Returns the ones that failed, so a bad path is
/// caught by a harness rather than by Niels noticing a gap in his menu bar:
/// `-O` strips the assertion out of the shipping build, and `render-marks.sh`
/// exits non-zero on a non-empty list.
func validateProviderMarks() -> [String] {
    var broken: [String] = []
    for id in PROVIDER_MARK_ORDER {
        guard let parts = PROVIDER_MARKS[id], !parts.isEmpty else {
            broken.append("\(id): no parts")
            continue
        }
        for (n, part) in parts.enumerated() where bezierPath(svg: part.d) == nil {
            broken.append("\(id)[\(n)]: path did not parse")
        }
    }
    return broken
}

/// The status item's title for a glyph face — the compact row of provider
/// pairs, or the icon-only row of bare glyphs ("text" mode never reaches here).
/// A free function rather than a delegate method so the offscreen render
/// harness (`render-marks.sh`) draws the face the bar actually shows, instead
/// of a copy of this layout that drifts from it.
func statusFaceTitle(_ entries: [StatusEntry], mode: String, glyph: String,
                     appearance: NSAppearance) -> NSAttributedString {
    // Nothing to report still needs a status item to click on.
    let shown = entries.isEmpty ? [StatusEntry(pct: nil, text: "—")] : entries
    // Dots or Cuties, decided once for the whole row so the two faces cannot
    // end up speaking different languages. A provider with no mark — or one
    // whose path failed to parse — falls back to its dot rather than leaving a
    // hole where a provider should be.
    func glyphImage(_ e: StatusEntry, trailing: CGFloat) -> NSImage {
        if glyph == "mark", let id = markId(forVendor: e.vendorId),
           let mark = statusMarkImage(markId: id, pct: e.pct, appearance: appearance,
                                      trailing: trailing) {
            return mark
        }
        return statusDotImage(pct: e.pct, appearance: appearance, trailing: trailing)
    }
    let title = NSMutableAttributedString()
    for (i, e) in shown.enumerated() {
        if mode == "compact" {
            if i > 0 { title.append(statusAttachment(statusDividerImage(appearance: appearance))) }
            title.append(statusAttachment(glyphImage(e, trailing: 3)))
            // The numbers ARE the readout, so they stay in the menu bar's own
            // text color whatever they say: colored digits next to a row of
            // monochrome system icons read as noise, and severity is the
            // glyph's job. The color has to be set explicitly — an attributed
            // string without one draws black, invisible on a dark menu bar.
            title.append(run(e.text, .labelColor, statusDigitFont))
        } else {
            let last = i == shown.count - 1
            title.append(statusAttachment(glyphImage(e, trailing: last ? 0 : 4)))
        }
    }
    return title
}

func ringAttr(pct: Int, size: CGFloat, elapsed: Int?, appearance: NSAppearance) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let attachment = NSTextAttachment()
    let image = ringImage(pct: pct, size: size, elapsed: elapsed, appearance: appearance)
    attachment.image = image
    attachment.attachmentCell = ColoredAttachmentCell(imageCell: image)
    // Vertically center the ring on the text's cap height rather than sitting it
    // on the baseline: without this the attachment grows upward only, so larger
    // rings drift toward the top of the menu bar. The origin is baseline-relative,
    // so offset by half the gap between the image and the cap height.
    let cap = barFont.capHeight
    let dy = (cap - size) / 2
    attachment.bounds = NSRect(x: 0, y: dy, width: size, height: size)
    out.append(NSAttributedString(attachment: attachment))
    return out
}

// Dispatches to the block bar or the ring according to the selected layout, so
// the panel and dropdown render with one call regardless of style. The ring has
// its own fixed pixel sizes (it does not scale with the block `width`, which is
// a character count); `menu` picks the larger ring used in dropdown rows. The
// appearance is threaded through so the ring track can adapt to light/dark.
func progressAttr(pct: Int, width: Int, elapsed: Int?, menu: Bool = false,
                  appearance: NSAppearance) -> NSAttributedString {
    if BAR_STYLE == "ring" {
        let size: CGFloat = menu ? CGFloat(MENU_BAR_W) + 4 : CGFloat(BAR_WIDTH) + 6
        return ringAttr(pct: pct, size: size, elapsed: elapsed, appearance: appearance)
    }
    return barAttr(pct: pct, width: width, elapsed: elapsed)
}

func resolveBinary(_ name: String) -> String? {
    let fm = FileManager.default
    if name == "ai-usagebar" || name == "ai-usagebar-tui" {
        let configured = DEF.string(forKey: "binaryPath") ?? ""
        if !configured.isEmpty {
            let candidate = name == "ai-usagebar" ? configured
                : URL(fileURLWithPath: configured).deletingLastPathComponent()
                    .appendingPathComponent(name).path
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
    }
    let home = NSHomeDirectory()
    for c in ["\(home)/.cargo/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
    where fm.isExecutableFile(atPath: c) {
        return c
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    p.arguments = [name]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty && fm.isExecutableFile(atPath: path) { return path }
    } catch {}
    return nil
}

// ─── Data model ──────────────────────────────────────────────────────────
struct Window { let pct: Int; let reset: String; let elapsed: Int? }
struct Snapshot {
    let plan: String
    let hasUsageWindows: Bool
    let creditBalance: String?
    let session: Window?
    let weekly: Window?
    /// The per-model weekly bar (model-scoped window, e.g. Fable, or the legacy
    /// flat sonnet window).
    let sonnet: Window?
    /// Label for that bar: the scoped model name ("Fable") or "Sonnet only".
    let sonnetLabel: String
    let extra: (pct: Int, spent: String, limit: String)?
    /// Antigravity's optional fourth rate-limit window (Claude & GPT OSS
    /// weekly). This is distinct from `extra`, which is a monetary budget.
    var secondaryWeekly: Window? = nil
    var secondaryWeeklyLabel: String = ""
    /// Overridable labels for the session/weekly bars. Default to the
    /// time-window names; a vendor whose two windows aren't time-based (Cursor:
    /// "Cursor Models" / "Other Models") sets its own. Tags are the 2-char
    /// prefixes shown on the compact status bar. Defaulted so every other
    /// vendor's construction is unchanged.
    var sessionTag: String = "5h"
    var weeklyTag: String = "7d"
    var sessionLabel: String = "Session"
    var weeklyLabel: String = "Weekly"
    /// Cursor's combined "included total usage" headline (`totalPercentUsed`),
    /// the single number its dashboard shows across both pools. nil for others.
    var cursorTotalPct: Int? = nil
}

func stripMarkup(_ s: String) -> String {
    // Decode exactly one layer after removing tags. Rust escapes API-controlled
    // labels for Pango; the native surface consumes plain text and must not
    // display those entities literally or reactivate decoded markup.
    s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
}

func providerNotice(_ output: [String: Any], vendor: String) -> String? {
    let text = stripMarkup(output["text"] as? String ?? "")
    let detail = stripMarkup(output["tooltip"] as? String ?? "").lowercased()
    let stale = text.contains("⏸")
    let failed = text.contains("⚠")
    guard stale || failed || text.contains("Loading") else { return nil }
    if detail.contains("keychain") && (detail.contains("locked") || detail.contains("denied")) {
        return "Unlock your login keychain, then retry."
    }
    if detail.contains("http 429") || detail.contains("rate limit") {
        return stale ? "Provider is busy. Showing saved usage; retrying." : "Provider is busy. Retrying."
    }
    let auth = ["http 401", "http 403", "unauthorized", "not logged", "re-auth",
                "sign in", "login", "credentials", "api_key", "api key", "token expired"]
        .contains { detail.contains($0) }
    if auth {
        if vendor.hasPrefix(DESKTOP_ACCOUNT_ID_PREFIX) { return "Sign in again in Claude Desktop." }
        switch baseVendorId(vendor) {
        case "anthropic": return "Sign in again in Claude Code."
        case "openai": return "Sign in again in Codex."
        case "cursor": return "Sign in again in Cursor."
        case "antigravity": return "Open Antigravity and check your sign-in."
        default: return "Check your API key in Preferences."
        }
    }
    if text.contains("Loading") || detail.contains("network") || detail.contains("connect") || detail.contains("timed out") {
        return "Can't connect. Check your connection; retrying."
    }
    return stale ? "Showing saved usage. Retrying." : "Couldn't load usage. Check provider setup in Preferences."
}

func parse(_ text: String, vendor: String) -> Snapshot? {
    let f = stripMarkup(text).components(separatedBy: ";;")
    guard f.count >= 10 else { return nil }
    let isAntigravity = vendor == "antigravity"
    func unknownPlaceholder(_ s: String) -> Bool {
        s.hasPrefix("{") && s.hasSuffix("}")
    }
    func t(_ i: Int) -> String {
        guard i < f.count else { return "" }
        let v = f[i].trimmingCharacters(in: .whitespaces)
        return unknownPlaceholder(v) ? "" : v
    }
    // Do not accept a numeric prefix: a stale suffix such as "27 ⏸" is not elapsed.
    func n(_ i: Int) -> Int? {
        let value = t(i)
        guard value.range(of: "^-?[0-9]+$", options: .regularExpression) != nil else { return nil }
        return Int(value)
    }
    func quotaWindow(_ pctIndex: Int, _ resetIndex: Int, _ elapsedIndex: Int) -> Window? {
        guard let pct = n(pctIndex), (0...100).contains(pct) else { return nil }
        let reset = t(resetIndex)
        return Window(
            pct: pct,
            reset: reset,
            elapsed: markerElapsed(reset: reset, elapsed: n(elapsedIndex)))
    }
    // Third bar = the per-model weekly window: a non-empty scoped model is the
    // presence signal. Its reset can legitimately be unavailable, so do not
    // mistake a missing reset for an absent scoped window and show Sonnet.
    let sonnetReset = t(6)
    var sonnet: Window? = nil
    var sonnetLabel = "Sonnet only"
    let scopedReset = t(12)
    let scopedModel = t(10)
    if !scopedModel.isEmpty {
        // A malformed scoped percentage is unavailable too, but must not make
        // us fall back to the unrelated legacy Sonnet window.
        if let p = n(11), (0...100).contains(p) {
            let reset = scopedReset.isEmpty ? "—" : scopedReset
            sonnet = Window(pct: p, reset: reset, elapsed: markerElapsed(reset: reset, elapsed: n(15)))
            sonnetLabel = isAntigravity ? "\(scopedModel) 5h" : scopedModel
        }
    } else if !sonnetReset.isEmpty, sonnetReset != "—", let p = n(5) {
        sonnet = Window(pct: p, reset: sonnetReset, elapsed: nil)
    }
    let spent = t(8)
    let limit = t(9)
    let extra: (pct: Int, spent: String, limit: String)? =
        (spent.isEmpty || limit.isEmpty) ? nil : n(7).map { (pct: $0, spent: spent, limit: limit) }
    // Dispatch the balance by the SELECTED vendor, not by vendor_short: binaries
    // up to 0.16 report vendor_short = "kmi" for both Kimi and Moonshot, so
    // keying on vendor_short would collide and read the wrong field.
    let balanceFieldIndex: Int?
    switch vendor {
    case "openrouter": balanceFieldIndex = 17
    case "deepseek": balanceFieldIndex = 18
    case "kilo": balanceFieldIndex = 19
    case "novita": balanceFieldIndex = 20
    case "moonshot": balanceFieldIndex = 21
    case "grok": balanceFieldIndex = 22
    case "anthropic_api": balanceFieldIndex = 23
    default: balanceFieldIndex = nil
    }
    let balance = balanceFieldIndex.flatMap { t($0).isEmpty ? nil : t($0) }
    // Vendors with no rate-limit windows show only a balance; suppress the fake
    // 5h/7d 0% rows their session_pct/weekly_pct aliases would otherwise paint.
    let balanceOnly = balanceFieldIndex != nil
    // Anthropic API exposes spend-vs-limit instead of a balance, and reports the
    // spend % through the session/weekly aliases. When a limit is configured it
    // becomes an extra ($) bar; otherwise it is balance-only headline display.
    // FORMAT tail: aapi_headline(23) aapi_pct(24) aapi_spent(25) aapi_limit(26).
    let aapiLimit = t(26)
    let aapiExtra: (pct: Int, spent: String, limit: String)?
    if vendor == "anthropic_api", !aapiLimit.isEmpty, aapiLimit != "—",
       let aapiPct = n(24), (0...100).contains(aapiPct), !t(25).isEmpty {
        aapiExtra = (pct: aapiPct, spent: t(25), limit: aapiLimit)
    } else {
        aapiExtra = nil
    }
    // With a limit configured the spend-vs-limit bar replaces the headline, so
    // avoid showing both the "cr" balance and the extra ($) row at once.
    let displayBalance = aapiExtra == nil ? balance : nil
    // Cursor carries its two included-usage pools on the session/weekly
    // aliases (session = Cursor Models, weekly = Other Models — both real, not
    // time windows), so relabel those bars rather than call them "Session"/
    // "Weekly". Every other vendor keeps the default time-window labels.
    let isCursor = vendor == "cursor"
    let secondaryWeekly: Window?
    let secondaryWeeklyLabel: String
    if isAntigravity, !t(28).isEmpty {
        secondaryWeekly = quotaWindow(7, 29, 30)
        secondaryWeeklyLabel = "\(t(28)) Weekly"
    } else {
        secondaryWeekly = nil
        secondaryWeeklyLabel = ""
    }
    return Snapshot(plan: t(0),
                    hasUsageWindows: !balanceOnly,
                    creditBalance: displayBalance,
                    session: quotaWindow(1, 2, 13),
                    weekly: quotaWindow(3, 4, 14),
                    sonnet: sonnet,
                    sonnetLabel: sonnetLabel,
                    extra: aapiExtra ?? extra,
                    secondaryWeekly: secondaryWeekly,
                    secondaryWeeklyLabel: secondaryWeeklyLabel,
                    sessionTag: isCursor ? "auto" : "5h",
                    weeklyTag: isCursor ? "premium" : "7d",
                    sessionLabel: isCursor ? "Cursor Models" : (isAntigravity ? "Gemini 5h" : "Session"),
                    weeklyLabel: isCursor ? "Other Models" : (isAntigravity ? "Gemini Weekly" : "Weekly"),
                    cursorTotalPct: isCursor ? n(27) : nil)
}

// ─── Preferences UI (SwiftUI) ────────────────────────────────────────────
extension Color {
    init(hexString: String) { self.init(nsColor: hexColor(hexString)) }
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02x%02x%02x",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }
}

struct HexColorPicker: View {
    let title: String
    @Binding var hex: String
    var body: some View {
        ColorPicker(title, selection: Binding(
            get: { Color(hexString: hex) },
            set: { hex = $0.hexString }
        ), supportsOpacity: false)
    }
}

// ─── Vendor login / config (mirrors the GNOME "Vendors" tab) ──────────────
struct VendorAuth {
    let id, name, kind, cli, login, pkg, env: String
}

let VENDOR_AUTH: [VendorAuth] = [
    VendorAuth(id: "anthropic", name: "Claude", kind: "oauth", cli: "claude", login: "claude", pkg: "@anthropic-ai/claude-code", env: ""),
    VendorAuth(id: "openai", name: "Codex", kind: "oauth", cli: "codex", login: "codex login", pkg: "@openai/codex", env: ""),
    VendorAuth(id: "zai", name: "Z.AI (GLM)", kind: "apikey", cli: "", login: "", pkg: "", env: "ZAI_API_KEY"),
    VendorAuth(id: "openrouter", name: "OpenRouter", kind: "apikey", cli: "", login: "", pkg: "", env: "OPENROUTER_API_KEY"),
    VendorAuth(id: "deepseek", name: "DeepSeek", kind: "apikey", cli: "", login: "", pkg: "", env: "DEEPSEEK_API_KEY"),
    VendorAuth(id: "kimi", name: "Kimi", kind: "apikey", cli: "", login: "", pkg: "", env: "KIMI_API_KEY"),
    VendorAuth(id: "kilo", name: "Kilo", kind: "apikey", cli: "", login: "", pkg: "", env: "KILO_API_KEY"),
    VendorAuth(id: "novita", name: "Novita", kind: "apikey", cli: "", login: "", pkg: "", env: "NOVITA_API_KEY"),
    VendorAuth(id: "moonshot", name: "Moonshot", kind: "apikey", cli: "", login: "", pkg: "", env: "MOONSHOT_API_KEY"),
    VendorAuth(id: "grok", name: "Grok (xAI)", kind: "apikey", cli: "", login: "", pkg: "", env: "XAI_MANAGEMENT_KEY"),
    VendorAuth(id: "anthropic_api", name: "Anthropic API", kind: "apikey", cli: "", login: "", pkg: "", env: "ANTHROPIC_ADMIN_KEY"),
    // Cursor has no API key: the binary reads the session token the Cursor IDE
    // wrote to its own state.vscdb. `kind: "local"` marks the "configured =
    // signed in to the app" case (like Antigravity below), with no login CLI
    // or env var of its own.
    VendorAuth(id: "cursor", name: "Cursor", kind: "local", cli: "", login: "", pkg: "", env: ""),
    // Antigravity 2.0, the `agy` CLI and the IDE are separate products
    // sharing one account-wide quota; any combination may be installed and
    // there is no credential file to check — the binary probes whichever
    // local server is running. `kind: "local"` mirrors Cursor and the GNOME
    // extension (gnome-extension/prefs.js).
    VendorAuth(id: "antigravity", name: "Google Antigravity", kind: "local", cli: "agy", login: "", pkg: "", env: ""),
]

// The config file the Rust binary would actually read. On macOS
// `directories::ProjectDirs` resolves to ~/Library/Application Support, so
// checking only ~/.config reported "no key configured" for a key the binary
// was happily using. Prefer the canonical location, fall back to the legacy
// Unix path the docs have always shown (the binary accepts both).
func configPathTOML() -> String {
    let appSupport = "\(NSHomeDirectory())/Library/Application Support/ai-usagebar/config.toml"
    if FileManager.default.fileExists(atPath: appSupport) { return appSupport }
    return "\(NSHomeDirectory())/.config/ai-usagebar/config.toml"
}

func configHasApiKeyTOML(_ section: String) -> Bool {
    guard let value = configValueTOML(section, "api_key") else { return false }
    return !value.isEmpty
}

func configEnabledTOML(_ section: String) -> Bool? {
    guard let value = configValueTOML(section, "enabled") else { return nil }
    switch value.lowercased() {
    case "true": return true
    case "false": return false
    default: return nil
    }
}

/// Read a single `key` under `[section]` from TOML text. Pure (no filesystem)
/// so the enabled-flag and api_key_env parsing is testable. Handles quoted
/// strings, bare booleans (`enabled = false`), inline comments, and `api_key_env`.
func tomlValueInText(_ text: String, section: String, key: String) -> String? {
    var inSection = false
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw).trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") {
            inSection = line == "[\(section)]"
            continue
        }
        guard inSection, !line.hasPrefix("#") else { continue }
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
        // A `#` starts a comment only outside quotes. Check for a quoted value
        // first so `api_key = "sk-abc#def"` keeps its embedded `#` instead of
        // being truncated into an unterminated string.
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        if let quote = value.first, quote == "\"" || quote == "'" {
            let content = value.dropFirst()
            guard let end = content.firstIndex(of: quote) else { continue }
            return String(content[..<end])
        }
        // Unquoted value: strip a trailing inline comment — `enabled = false
        // # opt-in` is a bare boolean, not a string starting with '#'.
        var bare = value
        if let hash = bare.firstIndex(of: "#") {
            bare = String(bare[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        // Bare tokens (booleans, numbers) reach here. Only `true`/`false` are
        // meaningful for the keys this reader serves; everything else is left
        // for the caller to ignore.
        return bare
    }
    return nil
}

/// Read a TOML array of quoted strings. This intentionally stays small (the
/// native app is a single dependency-free Swift file), but accepts multiline
/// arrays and rejects malformed values instead of silently widening Overview.
func tomlStringArrayInText(_ text: String, section: String, key: String) -> [String]? {
    func withoutComment(_ line: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for ch in line {
            if let active = quote {
                result.append(ch)
                if active == "\"", escaped {
                    escaped = false
                } else if active == "\"", ch == "\\" {
                    escaped = true
                } else if ch == active {
                    quote = nil
                }
            } else if ch == "#" {
                break
            } else {
                result.append(ch)
                if ch == "\"" || ch == "'" { quote = ch }
            }
        }
        return result
    }

    func hasClosingBracket(_ value: String) -> Bool {
        var quote: Character?
        var escaped = false
        for ch in value {
            if let active = quote {
                if active == "\"", escaped {
                    escaped = false
                } else if active == "\"", ch == "\\" {
                    escaped = true
                } else if ch == active {
                    quote = nil
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "]" {
                return true
            }
        }
        return false
    }

    var inSection = false
    var rawValue: String?
    for rawLine in text.components(separatedBy: .newlines) {
        let line = withoutComment(rawLine).trimmingCharacters(in: .whitespaces)
        if let current = rawValue {
            let joined = current + " " + line
            rawValue = joined
            if hasClosingBracket(joined) { break }
            continue
        }
        if line.hasPrefix("[") {
            inSection = line == "[\(section)]"
            continue
        }
        guard inSection, !line.isEmpty else { continue }
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("[") else { return nil }
        rawValue = value
        if hasClosingBracket(value) { break }
    }

    guard let raw = rawValue, hasClosingBracket(raw) else { return nil }
    let chars = Array(raw)
    guard chars.first == "[" else { return nil }
    var result: [String] = []
    var i = 1

    func skipSpace() {
        while i < chars.count && chars[i].isWhitespace { i += 1 }
    }

    while true {
        skipSpace()
        guard i < chars.count else { return nil }
        if chars[i] == "]" {
            i += 1
            skipSpace()
            return i == chars.count ? result : nil
        }
        let quote = chars[i]
        guard quote == "\"" || quote == "'" else { return nil }
        i += 1
        var value = ""
        var closed = false
        while i < chars.count {
            let ch = chars[i]
            i += 1
            if ch == quote {
                closed = true
                break
            }
            if quote == "\"", ch == "\\", i < chars.count {
                value.append(chars[i])
                i += 1
            } else {
                value.append(ch)
            }
        }
        guard closed else { return nil }
        result.append(value)
        skipSpace()
        guard i < chars.count else { return nil }
        if chars[i] == "," {
            i += 1
            continue
        }
        guard chars[i] == "]" else { return nil }
    }
}

func configValueTOML(_ section: String, _ key: String) -> String? {
    let path = configPathTOML()
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return tomlValueInText(text, section: section, key: key)
}

func configuredOverviewVendorIds() -> [String]? {
    let path = configPathTOML()
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return tomlStringArrayInText(text, section: "ui", key: "overview_vendors")
}

func apiKeyEnvironment(_ v: VendorAuth) -> String {
    configValueTOML(v.id, "api_key_env") ?? v.env
}

// ── Multi-account identities ───────────────────────────────────────────────
// Claude mirrors the Rust side (`src/config.rs`): explicit
// `[[anthropic.accounts]]` entries plus subdirectories of `[anthropic]`
// `accounts_dir`, with explicit labels winning on a clash. Each account is a
// selectable entry with the pseudo-id `anthropic@<label>`, fetched by the
// binary as `--vendor anthropic --account <label>` — the binary resolves the
// account's credentials itself (file or its own Keychain item), so the app
// never needs to know where they live.

/// Account-array labels for one provider, in file order. Pure text scan, like
/// the rest of this app's TOML reading: a `[[provider.accounts]]` header opens
/// a block, and the first `label = "…"` inside it counts.
func accountLabels(inTOML text: String, vendor: String) -> [String] {
    var labels: [String] = []
    var inBlock = false
    let header = "[[\(vendor).accounts]]"
    for rawLine in text.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") {
            inBlock = line == header
            continue
        }
        guard inBlock, line.hasPrefix("label") else { continue }
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2,
              parts[0].trimmingCharacters(in: .whitespaces) == "label" else { continue }
        var value = parts[1].trimmingCharacters(in: .whitespaces)
        if let quote = value.first, quote == "\"" || quote == "'" {
            let content = value.dropFirst()
            guard let end = content.firstIndex(of: quote) else { continue }
            value = String(content[..<end])
        }
        if !value.isEmpty {
            labels.append(value)
            inBlock = false  // one label per block
        }
    }
    return labels
}

func anthropicAccountLabels(inTOML text: String) -> [String] {
    accountLabels(inTOML: text, vendor: "anthropic")
}

/// Immediate subdirectories of `dir`, sorted — the same discovery rule as the
/// Rust `accounts_dir` scan. Credentials may be file- or Keychain-backed.
func discoverAccountLabels(inDir dir: String) -> [String] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
    return names.filter { name in
        var isDir: ObjCBool = false
        let sub = "\(dir)/\(name)"
        return fm.fileExists(atPath: sub, isDirectory: &isDir) && isDir.boolValue
    }.sorted()
}

/// Explicit labels first (file order), then discovered ones that don't clash.
func mergedAccountLabels(explicit: [String], discovered: [String]) -> [String] {
    explicit + discovered.filter { !explicit.contains($0) }
}

/// All configured Claude account labels, from the same config the binary reads.
func claudeAccountLabels() -> [String] {
    guard let text = try? String(contentsOfFile: configPathTOML(), encoding: .utf8) else {
        return []
    }
    let explicit = anthropicAccountLabels(inTOML: text)
    var discovered: [String] = []
    if let dir = tomlValueInText(text, section: "anthropic", key: "accounts_dir"), !dir.isEmpty {
        discovered = discoverAccountLabels(inDir: NSString(string: dir).expandingTildeInPath)
    }
    return mergedAccountLabels(explicit: explicit, discovered: discovered)
}

/// Explicit `[[openrouter.accounts]]` labels from the active config.
func openRouterAccountLabels() -> [String] {
    guard let text = try? String(contentsOfFile: configPathTOML(), encoding: .utf8) else {
        return []
    }
    return accountLabels(inTOML: text, vendor: "openrouter")
}

/// Rust semantics (`show_default_account`): `false` hides an unnamed entry,
/// but is ignored when there are no named accounts, so a vendor never loses
/// its only entry.
func showDefaultAccount(configValue: String?, hasAccounts: Bool) -> Bool {
    guard hasAccounts else { return true }
    return configValue != "false"
}

/// Pseudo-id mapping: `<vendor>@<label>` selects a named account.
let CLAUDE_ACCOUNT_ID_PREFIX = "anthropic@"
let OPENROUTER_ACCOUNT_ID_PREFIX = "openrouter@"
// A Claude account whose usage comes from the Desktop app's own token (a saved
// ~/.claude-acc/profiles/<label>), fetched with the widget's `--desktop` flag.
// Distinct prefix so `vendorArgs` knows to pass it; every other helper treats it
// as a Claude account via `accountLabel(of:)`.
let DESKTOP_ACCOUNT_ID_PREFIX = "anthropic-desktop@"

func accountLabel(of id: String) -> String? {
    if id.hasPrefix(DESKTOP_ACCOUNT_ID_PREFIX) {
        return String(id.dropFirst(DESKTOP_ACCOUNT_ID_PREFIX.count))
    }
    guard let separator = id.firstIndex(of: "@") else { return nil }
    let label = String(id[id.index(after: separator)...])
    return label.isEmpty ? nil : label
}

func isDesktopAccountId(_ id: String) -> Bool { id.hasPrefix(DESKTOP_ACCOUNT_ID_PREFIX) }

func baseVendorId(_ id: String) -> String {
    if isDesktopAccountId(id) { return "anthropic" }
    guard let separator = id.firstIndex(of: "@") else { return id }
    return String(id[..<separator])
}

/// The subprocess arguments that select `id` (base vendor or named account).
func vendorArgs(for id: String) -> [String] {
    if let label = accountLabel(of: id) {
        var args = ["--vendor", baseVendorId(id), "--account", label]
        if isDesktopAccountId(id) { args.append("--desktop") }
        return args
    }
    return ["--vendor", id]
}

/// One selectable entry: a base vendor or a named account.
struct MenuEntry {
    let id: String    // "cursor", "anthropic@<label>", or "openrouter@<label>"
    let name: String  // display: "Cursor" or "Vendor · <label>"
}

func claudeAccountMenuEntries(_ accounts: [UsageAccount]) -> [MenuEntry] {
    accounts.map { account in
        let prefix = account.desktop ? DESKTOP_ACCOUNT_ID_PREFIX : CLAUDE_ACCOUNT_ID_PREFIX
        return MenuEntry(id: prefix + account.label, name: "Claude · \(account.label)")
    }
}

func openRouterAccountMenuEntries(_ labels: [String]) -> [MenuEntry] {
    labels.map {
        MenuEntry(id: OPENROUTER_ACCOUNT_ID_PREFIX + $0, name: "OpenRouter · \($0)")
    }
}

/// Apply `[ui] overview_vendors` with the same semantics as the TUI: preserve
/// config order, omit unavailable vendors, and include every named account
/// when its base vendor is requested.
func filterOverviewEntries(_ entries: [MenuEntry], requested: [String]?) -> [MenuEntry] {
    guard let requested else { return entries }
    var result: [MenuEntry] = []
    var seen = Set<String>()
    for vendor in requested {
        for entry in entries where baseVendorId(entry.id) == vendor && !seen.contains(entry.id) {
            result.append(entry)
            seen.insert(entry.id)
        }
    }
    return result
}

/// The selectable entries, in menu order: every enabled+configured vendor,
/// with Claude and OpenRouter expanded into named accounts (their default
/// entries kept only per `show_default_account`). `active` stays listed even when
/// unconfigured — same rule the per-vendor list always had.
func vendorEntries(active: String, usageAccounts: [UsageAccount]? = nil) -> [MenuEntry] {
    var out: [MenuEntry] = []
    for v in VENDOR_AUTH where vendorEnabled(v) {
        if v.id == "anthropic" {
            // Once account status is available, Rust owns profile-directory
            // resolution and CLI/Desktop dedup. The nil fallback preserves
            // configured CLI accounts with an older binary.
            let accounts = usageAccounts ?? claudeAccountLabels().map {
                UsageAccount(label: $0, desktop: false)
            }
            let showDefault = showDefaultAccount(
                configValue: configValueTOML("anthropic", "show_default_account"),
                hasAccounts: !accounts.isEmpty)
            if showDefault && (v.id == active || vendorConfigured(v)) {
                out.append(MenuEntry(id: v.id, name: v.name))
            }
            out.append(contentsOf: claudeAccountMenuEntries(accounts))
        } else if v.id == "openrouter" {
            let labels = openRouterAccountLabels()
            let showDefault = showDefaultAccount(
                configValue: configValueTOML("openrouter", "show_default_account"),
                hasAccounts: !labels.isEmpty)
            if showDefault && (v.id == active || vendorConfigured(v)) {
                out.append(MenuEntry(id: v.id, name: v.name))
            }
            out.append(contentsOf: openRouterAccountMenuEntries(labels))
        } else if v.id == active || vendorConfigured(v) {
            out.append(MenuEntry(id: v.id, name: v.name))
        }
    }
    return out
}

/// Display name for any selectable id (base vendor, account, or overview).
func entryDisplayName(_ id: String) -> String {
    if id == "overview" { return "Overview" }
    if let label = accountLabel(of: id) {
        let base = baseVendorId(id)
        let vendor = VENDOR_AUTH.first { $0.id == base }?.name ?? base
        return "\(vendor) · \(label)"
    }
    return VENDOR_AUTH.first { $0.id == id }?.name ?? id
}

// MARK: - Which account each surface is signed in as
//
// Separate from the vendor entries above: those decide whose usage is *shown*,
// these are who the Claude Desktop app and the `claude` CLI are actually signed
// in as. Both come from `ai-usagebar account status --json`; the binary owns
// every path and credential detail, so this side only parses and displays.

struct AccountStatus: Equatable {
    /// False when there is no Claude Desktop app on this machine. Distinct from
    /// "no accounts saved yet": with the app present but nothing captured, the
    /// submenu still has to appear so the user can add the first one.
    var desktopAvailable = false
    var desktopActive: String?
    var cliActive: String?
    var desktopLabels: [String] = []
    var cliLabels: [String] = []
    /// Canonical Rust/TUI usage enumeration. Nil means an older binary, so the
    /// menu falls back to configured CLI labels; an empty array is authoritative.
    var usageAccounts: [UsageAccount]?
    /// Routines one account deleted that another still holds. A switch would
    /// hand them back, so the user is asked before it starts.
    var deletionConflicts: [DeletionConflict] = []
}

struct UsageAccount: Equatable {
    var label: String
    var desktop: Bool
}

struct DeletionConflict: Equatable {
    /// Opaque, type-scoped value accepted by `--delete-conflict`.
    var key: String
    var id: String
    /// "routine" or "chat" — they are swept differently but answered together.
    var kind: String
    var summary: String
    var deletedBy: String
    var stillIn: [String]

    /// One line for the dialog: what it is, and who dropped it.
    var line: String { "[\(kind)] \(summary) — deleted in \(deletedBy)" }
}

/// Parse `account status --json`. Every field is optional on purpose: a Mac
/// with no Claude Desktop app reports `"desktop": null`, and an older binary
/// may not know the subcommand at all — both must degrade to "no submenus"
/// rather than crash.
func parseAccountStatus(_ data: Data) -> AccountStatus? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    func labels(_ side: Any?, _ key: String) -> [String] {
        guard let side = side as? [String: Any], let rows = side[key] as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { $0["label"] as? String }
    }
    func active(_ side: Any?) -> String? {
        (side as? [String: Any])?["active_label"] as? String
    }
    let desktop = root["desktop"], cli = root["cli"]
    let usageAccounts: [UsageAccount]?
    if let rows = root["usage_accounts"] as? [[String: Any]] {
        usageAccounts = rows.compactMap { row in
            guard let label = row["label"] as? String,
                  let desktop = row["desktop"] as? Bool else { return nil }
            return UsageAccount(label: label, desktop: desktop)
        }
    } else {
        usageAccounts = nil
    }
    let conflicts = ((desktop as? [String: Any])?["deletion_conflicts"] as? [[String: Any]] ?? [])
        .compactMap { row -> DeletionConflict? in
            guard let id = row["id"] as? String else { return nil }
            let kind = row["kind"] as? String ?? "item"
            guard let key = row["key"] as? String else { return nil }
            return DeletionConflict(key: key,
                                   id: id,
                                   kind: kind,
                                   summary: row["summary"] as? String ?? id,
                                   deletedBy: row["deleted_by"] as? String ?? "?",
                                   stillIn: row["still_in"] as? [String] ?? [])
        }
    return AccountStatus(desktopAvailable: desktop is [String: Any],
                         desktopActive: active(desktop),
                         cliActive: active(cli),
                         desktopLabels: labels(desktop, "profiles"),
                         cliLabels: labels(cli, "accounts"),
                         usageAccounts: usageAccounts,
                         deletionConflicts: conflicts)
}

/// The one dim line under the header. Empty when neither surface resolved, so
/// the caller can hide the row entirely rather than show a bare label.
func accountsSummaryLine(_ s: AccountStatus) -> String {
    var parts: [String] = []
    if !s.desktopLabels.isEmpty { parts.append("Desktop: \(s.desktopActive ?? "?")") }
    if !s.cliLabels.isEmpty { parts.append("Code: \(s.cliActive ?? "?")") }
    return parts.joined(separator: "   ·   ")
}

/// `-y` because the menu has already asked; without it the binary would prompt
/// on a stdin that is not a terminal and abort.
func switchArgs(label: String, desktop: Bool, deleting: [String] = []) -> [String] {
    var args = ["account", "switch", label, desktop ? "--desktop" : "--cli", "-y"]
    // Passing any --delete-conflict also tells the binary the question was
    // already answered, so it never blocks on a prompt it cannot show here.
    for id in deleting { args += ["--delete-conflict", id] }
    return args
}

/// The first few conflicts spelled out, the rest summarised — a switch after a
/// big clean-up must not grow a dialog taller than the screen.
func conflictPreview(_ conflicts: [DeletionConflict], limit: Int = 10) -> String {
    var lines = conflicts.prefix(limit).map { "• \($0.line)" }
    if conflicts.count > limit {
        lines.append("… and \(conflicts.count - limit) more")
    }
    return lines.joined(separator: "\n")
}

/// Adding an account is interactive — a Desktop capture waits for you to sign
/// in, and a CLI one runs `claude` — so it goes to Terminal rather than being
/// swallowed by a background subprocess. Single-quoted with `'` doubled out,
/// so a label with a quote in it can't break out of the command.
func addAccountScript(binary: String, label: String, desktop: Bool) -> String {
    func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    return "#!/usr/bin/env bash\n"
        + "\(quote(binary)) account add \(quote(label))\(desktop ? " --desktop" : "")\n"
        + "echo; read -n 1 -s -r -p 'Press any key to close…'\n"
}

/// Rust defaults (`src/config.rs`): the OAuth/api-key vendors that ship enabled,
/// versus the opt-in balance vendors that default to disabled. An omitted
/// `[vendor].enabled` must reproduce these, not silently enable everything.
func defaultEnabled(_ id: String) -> Bool {
    switch id {
    case "anthropic", "openai", "zai", "openrouter": return true
    case "deepseek", "kimi", "kilo", "novita", "moonshot", "grok", "anthropic_api", "cursor", "antigravity": return false
    default: return true
    }
}

func vendorEnabled(_ v: VendorAuth) -> Bool {
    if let explicit = configEnabledTOML(v.id) { return explicit }
    return defaultEnabled(v.id)
}

// Cached: the check spawns a `security` subprocess, and it is consulted from the
// menu-rebuild path (main thread). Signed-in state doesn't change within a run,
// so compute it at most once — a restart picks up a fresh login.
var keychainClaudeCache: Bool?
func keychainHasClaude() -> Bool {
    if let cached = keychainClaudeCache { return cached }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    let result: Bool
    do { try p.run(); p.waitUntilExit(); result = p.terminationStatus == 0 } catch { result = false }
    keychainClaudeCache = result
    return result
}

func vendorConfigured(_ v: VendorAuth) -> Bool {
    guard vendorEnabled(v) else { return false }
    let home = NSHomeDirectory()
    let fm = FileManager.default
    if v.id == "anthropic" {
        return fm.fileExists(atPath: "\(home)/.claude/.credentials.json") || keychainHasClaude()
    }
    if v.id == "openai" {
        return fm.fileExists(atPath: "\(home)/.codex/auth.json")
    }
    if v.id == "cursor" {
        // Configured == signed in to the Cursor IDE, i.e. its state DB exists.
        // Honor a [cursor] db_path override the same way the binary does.
        let dbPath = configValueTOML("cursor", "db_path")
            ?? "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        return fm.fileExists(atPath: dbPath)
    }
    if v.id == "antigravity" {
        // Same check as gnome-extension/prefs.js: having any of the three
        // products' state directories is enough — there is no credential
        // file, and the binary itself probes whichever local server answers.
        return ["antigravity", "antigravity-cli", "antigravity-ide"]
            .contains { d in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: "\(home)/.gemini/\(d)", isDirectory: &isDir) && isDir.boolValue
            }
    }
    if let e = ProcessInfo.processInfo.environment[apiKeyEnvironment(v)], !e.isEmpty { return true }
    return configHasApiKeyTOML(v.id)
}

func cliInstalled(_ cli: String) -> Bool {
    let home = NSHomeDirectory()
    let fm = FileManager.default
    for dir in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin"]
    where fm.isExecutableFile(atPath: "\(dir)/\(cli)") {
        return true
    }
    // Fall back to a login shell (covers nvm etc.).
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-lc", "command -v \(cli)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return !(String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    } catch { return false }
}

// Write a script to a temp file and run it in Terminal.app (no AppleScript quoting hell).
func runInTerminal(_ script: String) {
    let tmp = NSTemporaryDirectory() + "ai-usagebar-\(UUID().uuidString).sh"
    try? script.write(toFile: tmp, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)
    let osa = "tell application \"Terminal\" to do script \"bash '\(tmp)'; rm -f '\(tmp)'\"\n" +
        "tell application \"Terminal\" to activate"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", osa]
    try? p.run()
}

func oauthScript(_ v: VendorAuth) -> String {
    return """
    export PATH="$HOME/.local/bin:$PATH"
    if command -v \(v.cli) >/dev/null 2>&1; then
      \(v.login)
    else
      echo "\(v.cli) not found. Installing to ~/.local without sudo. Package: \(v.pkg)"
      read -p "Install now? [y/N] " a
      if [ "$a" = y ] || [ "$a" = Y ]; then npm i -g --prefix "$HOME/.local" \(v.pkg) && hash -r && \(v.login); fi
    fi
    echo
    read -p "Enter to close..."
    """
}

func openTuiInTerminal() {
    let tui = resolveBinary("ai-usagebar-tui") ?? "ai-usagebar-tui"
    runInTerminal("\"\(tui)\"\necho\nread -p \"Enter to close...\"")
}

// Launch a .app by name (e.g. "Cursor") via `open -a`, so a local-kind vendor's
// button can bring the user to the app they need to sign into.
func openApp(_ name: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", name]
    try? p.run()
}

struct VendorsSection: View {
    @State private var configured: [String: Bool] = [:]
    @State private var cliPresent: [String: Bool] = [:]
    @State private var checking = false

    var body: some View {
        GroupBox("Vendors") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(VENDOR_AUTH, id: \.id) { v in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.name)
                            Text(statusText(v)).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(buttonLabel(v)) { action(v) }
                    }
                }
                if checking {
                    Text("checking…").font(.caption).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            var conf: [String: Bool] = [:]
            var cli: [String: Bool] = [:]
            for v in VENDOR_AUTH {
                conf[v.id] = vendorConfigured(v)
                // OAuth vendors need their CLI to log in; apikey vendors are
                // configured via the TUI.
                if v.kind == "oauth" { cli[v.id] = cliInstalled(v.cli) }
            }
            DispatchQueue.main.async {
                self.configured = conf
                self.cliPresent = cli
                self.checking = false
            }
        }
    }

    private func statusText(_ v: VendorAuth) -> String {
        if configured[v.id] == true { return "✓ Configured" }
        if v.kind == "oauth" {
            if cliPresent[v.id] == false { return "⚠ \(v.cli) not installed" }
            return "⚠ Not signed in — \(v.login)"
        }
        // Local vendors have no key: "configured" means signed in to the app
        // AND the vendor's own section enabled in config.
        if v.id == "antigravity" {
            return "⚠ Open Antigravity (app, IDE, or agy) and enable [antigravity] in config"
        }
        if v.kind == "local" {
            return "⚠ Sign in to the Cursor app and enable [cursor] in config"
        }
        return "⚠ No API key — \(apiKeyEnvironment(v))"
    }

    private func buttonLabel(_ v: VendorAuth) -> String {
        if v.kind == "oauth" {
            if configured[v.id] == true { return "Sign In Again" }
            if cliPresent[v.id] == false { return "Install + Sign In" }
            return "Sign In"
        }
        if v.id == "antigravity" { return "Open Antigravity" }
        if v.kind == "local" { return "Open Cursor" }
        return "Configure (TUI)"
    }

    private func action(_ v: VendorAuth) {
        if v.kind == "oauth" { runInTerminal(oauthScript(v)) }
        else if v.id == "antigravity" { openApp("Antigravity") }
        else if v.kind == "local" { openApp(v.name) }
        else { openTuiInTerminal() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { refresh() }
    }
}

struct SettingsView: View {
    @AppStorage("vendor") private var vendor = "anthropic"
    @AppStorage("interval") private var interval = 30.0
    @AppStorage("barWidth") private var barWidth = 8
    @AppStorage("showSession") private var showSession = true
    @AppStorage("showWeekly") private var showWeekly = true
    @AppStorage("showExtra") private var showExtra = false
    @AppStorage("showPercent") private var showPercent = true
    @AppStorage("showBars") private var showBars = true
    @AppStorage("showMeta") private var showMeta = true
    @AppStorage("barStyle") private var barStyle = "block"
    @AppStorage("menuBarMode") private var menuBarMode = "compact"
    @AppStorage("menuBarGlyph") private var menuBarGlyph = "dot"
    @AppStorage("swapShortcutEnabled") private var swapShortcutEnabled = true
    @AppStorage("compactShortcutEnabled") private var compactShortcutEnabled = true
    @AppStorage("colorLow") private var colorLow = "#98c379"
    @AppStorage("colorMid") private var colorMid = "#e5c07b"
    @AppStorage("colorHigh") private var colorHigh = "#d19a66"
    @AppStorage("colorCritical") private var colorCritical = "#e06c75"
    @AppStorage("colorEmpty") private var colorEmpty = "#3e4451"
    @State private var launchAtLogin = launchAgentIsInstalled()
    @State private var launchAtLoginError: String?

    // Only enabled vendors appear in the selector: Rust treats opt-in vendors
    // (deepseek/kimi/kilo/novita/moonshot/grok/anthropic_api) as disabled when
    // their `[vendor].enabled` is omitted, and so must this picker. Claude
    // accounts appear as their `vendor@<label>` pseudo-ids, same as the
    // "Switch Vendor" submenu.
    private var vendors: [String] {
        var ids = VENDOR_AUTH.filter { vendorEnabled($0) }.map { $0.id }
        let labels = claudeAccountLabels()
        if let at = ids.firstIndex(of: "anthropic") {
            ids.insert(contentsOf: labels.map { CLAUDE_ACCOUNT_ID_PREFIX + $0 }, at: at + 1)
        }
        let openRouterLabels = openRouterAccountLabels()
        if let at = ids.firstIndex(of: "openrouter") {
            ids.insert(
                contentsOf: openRouterLabels.map { OPENROUTER_ACCOUNT_ID_PREFIX + $0 },
                at: at + 1)
        }
        return ids + ["overview"]
    }

    var body: some View {
        // A ScrollView (not a Form) so the pane reliably scrolls on every macOS
        // version: on short displays the window can't grow past the screen, and
        // a plain Form clipped its top rows with no way to reach them.
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Display") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Show 5h bar (session)", isOn: $showSession)
                        Toggle("Show weekly bar", isOn: $showWeekly)
                        Toggle("Show extra-usage bar ($)", isOn: $showExtra)
                        Toggle("Show target line (pacing)", isOn: $showMeta)
                        Picker("Indicator style", selection: $barStyle) {
                            Text("Bars (░█)").tag("block")
                            Text("Ring (○)").tag("ring")
                        }
                        Picker("Menu bar", selection: $menuBarMode) {
                            Text("Icon only").tag("icon")
                            Text("Compact").tag("compact")
                            Text("Full text").tag("text")
                        }
                        Picker("Provider marks", selection: $menuBarGlyph) {
                            Text("Dots").tag("dot")
                            Text("Provider icons").tag("mark")
                        }
                        if menuBarMode == "text" {
                            DisclosureGroup("Full-text options") {
                                Toggle("Show percentage/value", isOn: $showPercent)
                                Toggle("Show bars", isOn: $showBars)
                                Stepper("Indicator width: \(barWidth)", value: $barWidth, in: 4...20)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Shortcuts") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Switch provider with ⌥⌘\\ (global shortcut)", isOn: $swapShortcutEnabled)
                        Text("Switches the active provider from any app.")
                            .font(.caption).foregroundColor(.secondary)
                        if menuBarMode == "text" {
                            Toggle("Collapse/expand with ⌥⌘E", isOn: $compactShortcutEnabled)
                            Text("Switches the full-text Overview between bars and numbers.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Colors") {
                    VStack(alignment: .leading, spacing: 8) {
                        HexColorPicker(title: "Low (<50%)", hex: $colorLow)
                        HexColorPicker(title: "Medium (50–74%)", hex: $colorMid)
                        HexColorPicker(title: "High (75–89%)", hex: $colorHigh)
                        HexColorPicker(title: "Critical (≥90%)", hex: $colorCritical)
                        if barStyle == "block" {
                            HexColorPicker(title: "Empty (bar background)", hex: $colorEmpty)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Data") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Provider", selection: $vendor) {
                            ForEach(vendors, id: \.self) { Text(entryDisplayName($0)).tag($0) }
                        }
                        Stepper("Interval: \(Int(interval))s", value: $interval, in: 5...3600, step: 5)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("System") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Start at login", isOn: Binding(
                            get: { launchAtLogin },
                            set: { enabled in
                                do {
                                    try setLaunchAtLogin(enabled)
                                    launchAtLogin = launchAgentIsInstalled()
                                    launchAtLoginError = nil
                                } catch {
                                    launchAtLogin = launchAgentIsInstalled()
                                    launchAtLoginError = error.localizedDescription
                                }
                            }))
                        Text("Open AI Usage Bar automatically when you log in.")
                            .font(.caption).foregroundColor(.secondary)
                        if let error = launchAtLoginError {
                            Text("Could not save login setting: \(error)")
                                .font(.caption).foregroundColor(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                VendorsSection()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460)
        .frame(minHeight: 300, idealHeight: 560, maxHeight: .infinity)
        .onAppear { launchAtLogin = launchAgentIsInstalled() }
    }
}

// ─── Launch at login (macOS LaunchAgent) ─────────────────────────────────
//
// The app is an unbundled single binary, so the modern SMAppService.mainApp
// API (which needs a bundle id) doesn't apply. A per-user LaunchAgent is the
// portable way to start an unbundled executable at login — the same mechanism
// install-agent.sh sets up, now toggleable from Preferences.
let LAUNCH_AGENT_LABEL = "com.akitaonrails.ai-usagebar-menubar"

func launchAgentPlistPath() -> String {
    "\(NSHomeDirectory())/Library/LaunchAgents/\(LAUNCH_AGENT_LABEL).plist"
}

func launchAgentIsInstalled() -> Bool {
    FileManager.default.fileExists(atPath: launchAgentPlistPath())
}

/// Absolute path of the running executable, for the LaunchAgent to relaunch.
func selfExecutablePath() -> String {
    if let p = Bundle.main.executablePath, !p.isEmpty { return p }
    let arg0 = CommandLine.arguments.first ?? "ai-usagebar-menubar"
    if arg0.hasPrefix("/") { return arg0 }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(arg0).standardized.path
}

/// Install (or remove) the login LaunchAgent by managing its plist file.
/// Building the plist via PropertyListSerialization sidesteps the XML-escaping
/// the shell installer has to do by hand.
///
/// Deliberately no `launchctl load`/`unload`: the app is already running when
/// this is toggled, so `RunAtLoad` on load would spawn a *second* copy, and
/// `unload` on disable would SIGTERM this very process (quitting the app the
/// user is still using) if it happened to be the launchd-managed one. launchd
/// loads every agent in ~/Library/LaunchAgents at the next login, so writing
/// (or removing) the file is all that's needed for a start-at-login toggle.
func launchAgentPlist(executable: String) throws -> Data {
    let plist: [String: Any] = [
        "Label": LAUNCH_AGENT_LABEL,
        "ProgramArguments": [executable],
        "RunAtLoad": true,
        "ProcessType": "Interactive",
    ]
    return try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
}

func setLaunchAtLogin(_ enabled: Bool) throws {
    let path = launchAgentPlistPath()
    if enabled {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try launchAgentPlist(executable: selfExecutablePath())
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } else if FileManager.default.fileExists(atPath: path) {
        try FileManager.default.removeItem(atPath: path)
    }
}

// ─── App ─────────────────────────────────────────────────────────────────
// ─── Global vendor-swap shortcut (⌥⌘\) ───────────────────────────────────
//
// A menu-bar app has no focused window, so a system-wide shortcut needs a
// Carbon hot key (RegisterEventHotKey), which fires regardless of focus and —
// unlike an NSEvent global monitor — needs no Accessibility permission. The
// Carbon handler is a C callback that can't capture Swift state, so it just
// posts a notification the delegate observes.

let swapHotKeyNotification = Notification.Name("aiusagebar.swapHotKey")
let compactHotKeyNotification = Notification.Name("aiusagebar.compactHotKey")

/// Default shortcuts: `\` (kVK_ANSI_Backslash) with Command+Option swaps the
/// vendor; `E` with Command+Option toggles the overview's Compact/Expand.
/// `[ui]` on Linux has no equivalent; this is macOS-only.
let SWAP_HOTKEY_KEYCODE = UInt32(kVK_ANSI_Backslash)
let COMPACT_HOTKEY_KEYCODE = UInt32(kVK_ANSI_E)
let SWAP_HOTKEY_MODIFIERS = UInt32(cmdKey | optionKey)

/// Registered hot-key ids, carried back to us in the event so one shared C
/// callback can tell which shortcut fired.
let SWAP_HOTKEY_ID = UInt32(1)
let COMPACT_HOTKEY_ID = UInt32(2)

private func swapHotKeyCallback(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hk = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &hk)
    NotificationCenter.default.post(
        name: hk.id == COMPACT_HOTKEY_ID ? compactHotKeyNotification : swapHotKeyNotification,
        object: nil)
    return noErr
}

/// Whether the overview status-bar title draws mini bars (vs. the compact
/// %-text mode). "Compact" forces the text mode even under the bars-count
/// threshold. Pure + testable — the render path is not.
func overviewUsesBars(count: Int, barsMax: Int, compact: Bool) -> Bool {
    !compact && count <= barsMax
}

/// Provider ids the user toggled out of the always-visible top-bar summary in
/// Overview mode. The dropdown still lists them (unchecked + dimmed) so they can
/// be turned back on. Persisted in UserDefaults; absent key → nothing hidden.
func overviewHiddenProviders() -> Set<String> {
    Set(DEF.stringArray(forKey: "overviewHiddenProviders") ?? [])
}

func setOverviewProvider(_ id: String, hidden: Bool) {
    var hiddenSet = overviewHiddenProviders()
    if hidden { hiddenSet.insert(id) } else { hiddenSet.remove(id) }
    DEF.set(hiddenSet.sorted(), forKey: "overviewHiddenProviders")
}

/// The ids that survive the top-bar filter, in their original order. Pure +
/// testable — the render path (which also drops nil snapshots) is not.
func overviewVisibleIds(_ ids: [String], hidden: Set<String>) -> [String] {
    ids.filter { !hidden.contains($0) }
}

/// The next id in the cycle, wrapping. `current` absent from `ids` (e.g. the
/// selected vendor was disabled) starts at the first (or last, backward).
/// Pure + testable — the hot-key handler is not.
func nextVendorId(current: String, in ids: [String], forward: Bool = true) -> String? {
    guard !ids.isEmpty else { return nil }
    let n = ids.count
    let i = ids.firstIndex(of: current) ?? (forward ? -1 : 0)
    let j = forward ? (i + 1) % n : (i - 1 + n) % n
    return ids[j]
}

func hotKeyRegistrationSucceeded(_ status: OSStatus) -> Bool {
    status == noErr
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var swapHotKeyRef: EventHotKeyRef?
    var compactHotKeyRef: EventHotKeyRef?
    var swapHotKeyHandlerInstalled = false
    var timer: Timer?
    var prefsWindow: NSWindow?
    var appearanceObservation: NSKeyValueObservation?
    /// Last resolved light/dark name, so the appearance observer ignores the
    /// layout-driven KVO fires that don't actually change the theme.
    var lastAppearanceName: NSAppearance.Name?
    /// Tracks the active vendor so `settingsChanged` can tell a vendor swap (show
    /// Loading) apart from an unrelated preference change (repaint from cache).
    var lastVendor = ""
    var lastSnapshot: Snapshot?
    var pendingRefresh: DispatchWorkItem?
    /// Live watch on config.toml so external edits (a text editor, the TUI's
    /// Settings overlay, `ai-usagebar account add`) hot-reload
    /// the vendor list without restarting the app. The fd is closed by the
    /// source's cancel handler; `pendingConfigReload` coalesces an editor's
    /// burst of vnode events into a single reload.
    var configWatchSource: DispatchSourceFileSystemObject?
    var configWatchFD: CInt = -1
    var pendingConfigReload: DispatchWorkItem?
    /// A visibility checkbox changes presentation only. Its UserDefaults
    /// notification should repaint from cache without restarting the timer or
    /// launching a fresh round of provider subprocesses.
    var overviewVisibilityChangePending = false
    /// Bumped on every refresh attempt. A result whose generation is no longer
    /// current belongs to a superseded attempt — most often the previously
    /// selected vendor — and must not be rendered. Without this, the timer,
    /// the Preferences window and a vendor change could each start their own
    /// subprocess and whichever finished last won, regardless of what the user
    /// had actually selected. Main-thread only.
    var refreshGeneration: Int = 0
    /// At most one subprocess in flight; a request arriving while one runs is
    /// coalesced rather than stacked.
    var refreshInFlight = false
    var refreshQueued = false
    let headerItem = NSMenuItem()
    let connectionNoticeItem = NSMenuItem()
    var providerNotices: [String: String] = [:]
    var rows: [String: NSMenuItem] = [:]
    // Overview mode fills these (one per vendor/account); hidden in
    // single-vendor mode. The pool starts at the built-in vendor count and can
    // grow if account discovery adds more rows.
    var overviewRows: [NSMenuItem] = []
    /// Last overview fetch, so a settings/appearance change re-renders it without
    /// flashing the stale single-vendor snapshot.
    var lastOverview: [(name: String, id: String, snap: Snapshot?)]?
    // Rebuilt on every render so only configured vendors show, and the active
    // one is checked. Kept as a field so the menu owns it for its lifetime.
    let vendorSubmenu = NSMenu()
    let vendorSubmenuItem = NSMenuItem(title: "Switch Vendor", action: nil, keyEquivalent: "")
    /// Overview-only: forces the status-bar title into the compact %-text mode
    /// ("Compact"); while compact it reads "Expand" and turns it back off.
    let compactItem = NSMenuItem(title: "Compact", action: nil, keyEquivalent: "")
    /// Which account each surface is signed in as. One dim line under the
    /// header, plus a submenu per surface. All three stay hidden until
    /// `account status --json` answers, so an older binary that doesn't know
    /// the subcommand simply shows the menu it always did.
    let accountsInfoItem = NSMenuItem()
    let desktopAccountSubmenu = NSMenu()
    let desktopAccountItem = NSMenuItem(title: "Claude Desktop", action: nil, keyEquivalent: "")
    let cliAccountSubmenu = NSMenu()
    let cliAccountItem = NSMenuItem(title: "Claude Code", action: nil, keyEquivalent: "")
    var lastAccountStatus: AccountStatus?
    var accountStatusFetchedAt = Date.distantPast
    var accountStatusGeneration = 0
    /// A switch runs a subprocess that quits and reopens another app; both
    /// submenus grey out until it returns so it cannot be fired twice.
    var accountSwitchInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DEF.register(defaults: ["swapShortcutEnabled": true, "compactShortcutEnabled": true])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Every face is image-then-text (see setStatusFace); set the position
        // once so later updates only swap the image and the title. The first
        // paint is a bare ellipsis: nothing is known yet, and "5h" pre-announces
        // a window this vendor may not even have.
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.title = "…"
        buildMenu()
        rebuildVendorSubmenu()
        observeAppearanceChanges()
        lastVendor = VENDOR  // so the first settingsChanged isn't mistaken for a swap
        refresh()
        restartTimer()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: UserDefaults.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSwapHotKey),
            name: swapHotKeyNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleCompactHotKey),
            name: compactHotKeyNotification, object: nil)
        installSwapHotKey()
        installCompactHotKey()
        installConfigWatch()
        fetchAccountStatus()
    }

    /// Watch config.toml and hot-reload the vendor list when it changes on disk.
    /// Editors usually save atomically (write a temp file, then rename it over
    /// the target), which unlinks the inode our descriptor points at — so a
    /// `.delete`/`.rename` event means "re-open the path to keep watching the
    /// new file". A plain in-place write (`>>`, some editors) fires `.write` on
    /// the same descriptor. Idempotent: always tears down the previous watch.
    func installConfigWatch() {
        removeConfigWatch()
        let path = configPathTOML()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // No readable file yet (not created, or momentarily gone between an
            // editor's unlink and rename). Retry shortly so a config created
            // after launch — or a non-atomic save's brief gap — is still picked
            // up. ponytail: a fixed 3s retry, not exponential backoff; this only
            // spins in the rare window before the file exists.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.installConfigWatch()
            }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, let flags = self.configWatchSource?.data else { return }
            self.scheduleConfigReload()
            // The watched inode was replaced; re-arm on whatever is at the path
            // now so future edits keep firing.
            if flags.contains(.delete) || flags.contains(.rename) {
                self.installConfigWatch()
            }
        }
        src.setCancelHandler { close(fd) }
        configWatchFD = fd
        configWatchSource = src
        src.resume()
    }

    func removeConfigWatch() {
        configWatchSource?.cancel()  // the cancel handler closes the fd
        configWatchSource = nil
        configWatchFD = -1
    }

    /// Coalesce the burst of vnode events a save emits (write → rename → attrib)
    /// into one reload a beat later, mirroring `settingsChanged`'s debounce.
    func scheduleConfigReload() {
        pendingConfigReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.configFileChanged() }
        pendingConfigReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// A config.toml edit landed: rebuild the vendor submenu/ring, re-render the
    /// current view from cache so an `[ui]` tweak shows at once, then debounce a
    /// full refresh to fetch any newly-added vendor/account. Reads are all fresh
    /// from disk (nothing caches config.toml), so no invalidation is needed.
    @objc func configFileChanged() {
        rebuildVendorSubmenu()
        // A new [[anthropic.accounts]] entry changes the Claude Code list.
        fetchAccountStatus()
        if VENDOR == "overview" {
            if let ov = lastOverview { renderOverview(ov) }
        } else if let s = lastSnapshot {
            renderPanel(s); renderMenu(s)
        }
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// (Re)register the global ⌥⌘\ hot key to match the `swapShortcutEnabled`
    /// preference. Idempotent: always unregisters first.
    func installSwapHotKey() {
        guard removeSwapHotKey() else {
            // The old registration is still live; reflect that instead of
            // showing a disabled toggle that continues intercepting the key.
            DEF.set(true, forKey: "swapShortcutEnabled")
            return
        }
        let enabled = DEF.bool(forKey: "swapShortcutEnabled")
        // Mirror the swap shortcut as a hint on the "Switch Vendor" item. A native
        // keyEquivalent is suppressed by the submenu's disclosure arrow, so paint
        // the hint into the title instead (right-aligned, dimmed). Cleared when off.
        if enabled {
            // Inline, dimmed hint right after the label. A right-aligned column
            // (like the other items' ⌘R) isn't possible here: the submenu arrow
            // takes the trailing slot, and a fixed tab stop would over-widen the
            // menu whenever the wide overview rows are hidden.
            let font = NSFont.menuFont(ofSize: 0)
            let s = NSMutableAttributedString(
                string: "Switch Vendor  ", attributes: [.font: font])
            s.append(NSAttributedString(string: "⌥⌘\\", attributes: [
                .font: font, .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            vendorSubmenuItem.attributedTitle = s
        } else {
            vendorSubmenuItem.attributedTitle = NSAttributedString(string: "Switch Vendor")
        }
        guard enabled else { return }
        guard installHotKeyHandlerOnce() else {
            disableFailedShortcut("swapShortcutEnabled", name: "⌥⌘\\")
            vendorSubmenuItem.attributedTitle = NSAttributedString(string: "Switch Vendor")
            return
        }
        let id = EventHotKeyID(signature: OSType(0x4149_4242), id: SWAP_HOTKEY_ID)  // 'AIBB'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            SWAP_HOTKEY_KEYCODE, SWAP_HOTKEY_MODIFIERS, id, GetApplicationEventTarget(), 0,
            &ref)
        guard hotKeyRegistrationSucceeded(status), let ref else {
            if let ref { UnregisterEventHotKey(ref) }
            disableFailedShortcut("swapShortcutEnabled", name: "⌥⌘\\", status: status)
            vendorSubmenuItem.attributedTitle = NSAttributedString(string: "Switch Vendor")
            return
        }
        swapHotKeyRef = ref
    }

    /// (Re)register the global ⌥⌘E Compact/Expand hot key to match the
    /// `compactShortcutEnabled` preference. Idempotent, mirroring
    /// `installSwapHotKey` — including the painted-in hint (a native
    /// keyEquivalent would fire a second time while the menu is open, double-
    /// toggling on one press).
    func installCompactHotKey() {
        guard removeCompactHotKey() else {
            DEF.set(true, forKey: "compactShortcutEnabled")
            return
        }
        updateCompactItemTitle()
        guard DEF.bool(forKey: "compactShortcutEnabled") else { return }
        guard installHotKeyHandlerOnce() else {
            disableFailedShortcut("compactShortcutEnabled", name: "⌥⌘E")
            updateCompactItemTitle()
            return
        }
        let id = EventHotKeyID(signature: OSType(0x4149_4242), id: COMPACT_HOTKEY_ID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            COMPACT_HOTKEY_KEYCODE, SWAP_HOTKEY_MODIFIERS, id, GetApplicationEventTarget(), 0,
            &ref)
        guard hotKeyRegistrationSucceeded(status), let ref else {
            if let ref { UnregisterEventHotKey(ref) }
            disableFailedShortcut("compactShortcutEnabled", name: "⌥⌘E", status: status)
            updateCompactItemTitle()
            return
        }
        compactHotKeyRef = ref
    }

    /// Compact ↔ Expand label plus the dimmed ⌥⌘E hint when the global
    /// shortcut is on. Shared by the overview render and the hot-key installer.
    func updateCompactItemTitle() {
        let label = DEF.bool(forKey: "overviewCompact") ? "Expand" : "Compact"
        guard DEF.bool(forKey: "compactShortcutEnabled") else {
            compactItem.attributedTitle = NSAttributedString(string: label)
            return
        }
        let font = NSFont.menuFont(ofSize: 0)
        let s = NSMutableAttributedString(string: "\(label)  ", attributes: [.font: font])
        s.append(NSAttributedString(string: "⌥⌘E", attributes: [
            .font: font, .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        compactItem.attributedTitle = s
    }

    /// One Carbon handler serves every hot key; the event's EventHotKeyID
    /// says which one fired.
    private func installHotKeyHandlerOnce() -> Bool {
        guard !swapHotKeyHandlerInstalled else { return true }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(), swapHotKeyCallback, 1, &spec, nil, nil)
        guard hotKeyRegistrationSucceeded(status) else {
            NSLog("ai-usagebar: global hot-key handler registration failed (OSStatus %d)", status)
            return false
        }
        swapHotKeyHandlerInstalled = true
        return true
    }

    private func disableFailedShortcut(_ key: String, name: String,
                                       status: OSStatus? = nil) {
        if let status {
            NSLog("ai-usagebar: global shortcut %@ registration failed (OSStatus %d)",
                  name, status)
        } else {
            NSLog("ai-usagebar: global shortcut %@ registration failed", name)
        }
        // Keep the visible preference honest when another app already owns the
        // shortcut or Carbon refuses the registration.
        DEF.set(false, forKey: key)
    }

    @discardableResult
    func removeSwapHotKey() -> Bool {
        if let ref = swapHotKeyRef {
            let status = UnregisterEventHotKey(ref)
            guard hotKeyRegistrationSucceeded(status) else {
                NSLog("ai-usagebar: could not unregister ⌥⌘\\ (OSStatus %d)", status)
                return false
            }
            swapHotKeyRef = nil
        }
        return true
    }

    @discardableResult
    private func removeCompactHotKey() -> Bool {
        if let ref = compactHotKeyRef {
            let status = UnregisterEventHotKey(ref)
            guard hotKeyRegistrationSucceeded(status) else {
                NSLog("ai-usagebar: could not unregister ⌥⌘E (OSStatus %d)", status)
                return false
            }
            compactHotKeyRef = nil
        }
        return true
    }

    /// Advance the active vendor to the next configured one, wrapping. Fired by
    /// the global hot key; sets `vendor` in defaults, which drives the usual
    /// re-render via `settingsChanged`.
    @objc func handleSwapHotKey() {
        if let next = nextVendorId(current: VENDOR, in: swapCycleIds()) {
            DEF.set(next, forKey: "vendor")
        }
    }

    /// ⌥⌘E: toggle Compact/Expand. Overview-only — flipping a hidden
    /// preference from another view would be invisible and confusing.
    @objc func handleCompactHotKey() {
        guard VENDOR == "overview" else { return }
        toggleCompact()
    }

    /// The swap-shortcut ring: every configured entry (vendors *and* Claude
    /// accounts) plus the synthetic "overview" target, so ⌥⌘\ cycles them all.
    func swapCycleIds() -> [String] {
        var ids = vendorEntries(active: VENDOR,
                                usageAccounts: lastAccountStatus?.usageAccounts).map { $0.id }
        ids.append("overview")
        return ids
    }

    func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(headerItem)
        connectionNoticeItem.isEnabled = false
        connectionNoticeItem.isHidden = true
        menu.addItem(connectionNoticeItem)
        // Reads as a sub-line of the header, so it sits above the usage rows.
        accountsInfoItem.isEnabled = false
        accountsInfoItem.isHidden = true
        menu.addItem(accountsInfoItem)
        // One hidden slot per built-in vendor for Overview mode. Named accounts
        // can take the total higher; renderOverview grows the pool on demand.
        for _ in 0..<VENDOR_AUTH.count {
            let it = NSMenuItem()
            it.isHidden = true
            overviewRows.append(it)
            menu.addItem(it)
        }
        for key in ["session", "weekly", "sonnet", "extra"] {
            let it = NSMenuItem()
            rows[key] = it
            menu.addItem(it)
        }
        // First item after the usage rows, Overview-only (hidden elsewhere).
        compactItem.action = #selector(toggleCompact)
        compactItem.target = self
        compactItem.isHidden = true
        menu.addItem(compactItem)

        menu.addItem(.separator())
        // The dropdown is a readout; the things that act live one level down.
        // Nested submenus are fine in AppKit, and a key equivalent still fires
        // from inside a submenu while the menu is open. autoenablesItems stays
        // off so renderAccountMenus' isEnabled (switch in flight) is respected
        // here exactly as it was at the top level.
        let moreMenu = NSMenu()
        moreMenu.autoenablesItems = false
        addAction(moreMenu, "Refresh Now", #selector(refreshAction), "r")
        addAction(moreMenu, "Open TUI", #selector(openTui), "t")
        vendorSubmenuItem.submenu = vendorSubmenu
        moreMenu.addItem(vendorSubmenuItem)
        for (item, submenu) in [(desktopAccountItem, desktopAccountSubmenu),
                                (cliAccountItem, cliAccountSubmenu)] {
            item.submenu = submenu
            item.isHidden = true
            moreMenu.addItem(item)
        }
        let moreItem = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        moreItem.submenu = moreMenu
        menu.addItem(moreItem)
        menu.addItem(.separator())
        addAction(menu, "Preferences…", #selector(openPrefs), ",")
        addAction(menu, "Quit", #selector(quit), "q")

        // Catches a switch made elsewhere (a terminal, claude-acc) without
        // polling for state that changes at most a few times a day.
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if Date().timeIntervalSince(accountStatusFetchedAt) >= 5 { fetchAccountStatus() }
    }

    func addAction(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String) {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        menu.addItem(it)
    }

    @objc func refreshAction() { refresh() }
    @objc func quit() { NSApp.terminate(nil) }

    /// Flip the overview's compact mode; the UserDefaults observer re-renders,
    /// which also relabels the item (Compact ↔ Expand).
    @objc func toggleCompact() {
        DEF.set(!DEF.bool(forKey: "overviewCompact"), forKey: "overviewCompact")
    }

    @objc func openPrefs() {
        if prefsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            // Install the host view directly so this window owns its size on
            // macOS 12 as well. The SwiftUI ScrollView still fills the
            // resizable content area without expanding it to its full height.
            let avail = NSScreen.main?.visibleFrame.height ?? 700
            let initialSize = NSSize(width: 460, height: min(560, avail - 40))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: initialSize),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered,
                             defer: false)
            w.contentViewController = host
            w.title = "AI Usage Bar — Preferences"
            // Resizable so the content can always be reached; a min size keeps
            // it usable, and the initial height is clamped to the visible screen
            // so the top never lands under the menu bar on short displays.
            w.contentMinSize = NSSize(width: 460, height: 360)
            w.setContentSize(initialSize)
            w.isReleasedWhenClosed = false
            w.center()
            prefsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        prefsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openTui() {
        guard let tui = resolveBinary("ai-usagebar-tui") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Terminal\" to do script \"\(tui)\""]
        try? p.run()
    }

    // Settings changed in Preferences: re-render instantly from cache, re-arm
    // the timer, and re-fetch (debounced) in case vendor/binary changed.
    @objc func settingsChanged() {
        if overviewVisibilityChangePending {
            overviewVisibilityChangePending = false
            if VENDOR == "overview", let ov = lastOverview { renderOverview(ov) }
            return
        }
        // The swap-shortcut toggle lives in defaults too; re-register only when
        // its state and the live registration disagree (avoids churn on every
        // vendor switch, which itself writes defaults).
        if DEF.bool(forKey: "swapShortcutEnabled") != (swapHotKeyRef != nil) {
            installSwapHotKey()
        }
        if DEF.bool(forKey: "compactShortcutEnabled") != (compactHotKeyRef != nil) {
            installCompactHotKey()
        }
        // A vendor swap re-fetches, which takes a moment; keeping the previous
        // vendor's view up reads as a freeze. Show a Loading placeholder at once.
        let vendorChanged = VENDOR != lastVendor
        lastVendor = VENDOR
        if vendorChanged {
            showLoading()
        } else if VENDOR == "overview" {
            if let ov = lastOverview { renderOverview(ov) }
        } else if let s = lastSnapshot {
            renderPanel(s); renderMenu(s)
        }
        restartTimer()
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Instant feedback for a vendor swap: replace the whole view with a Loading
    /// placeholder naming the target, until its data arrives.
    func showLoading() {
        lastSnapshot = nil
        lastOverview = nil
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let name = entryDisplayName(VENDOR)
        setStatusFace([StatusEntry(pct: nil, text: "…")],
                      textTitle: run("\(name) …", menuBarTextColor(appearance), statusFont))
        headerItem.attributedTitle = run("\(name) · loading…", .labelColor,
                                         NSFont.boldSystemFont(ofSize: 13))
        for (_, it) in rows { it.isHidden = true }
        for it in overviewRows { it.isHidden = true }
        compactItem.isHidden = true
        rebuildVendorSubmenu()
    }

    func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: INTERVAL, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func observeAppearanceChanges() {
        guard let button = statusItem.button else { return }
        lastAppearanceName = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        appearanceObservation = button.observe(\NSStatusBarButton.effectiveAppearance,
                                               options: [.new]) { [weak self] btn, _ in
            // The KVO fires on every layout pass, not only on a real light↔dark
            // flip — and rendering (which relays out the button) would retrigger
            // it, spinning the main thread. Act only when the theme truly changes.
            let name = btn.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            DispatchQueue.main.async {
                guard let self, self.lastAppearanceName != name else { return }
                self.lastAppearanceName = name
                self.rerenderAppearance()
            }
        }
    }

    func rerenderAppearance() {
        // Appearance only changes colors; the configured-vendor set is unchanged,
        // so repaint without rebuilding the (subprocess-touching) submenu.
        if VENDOR == "overview", let ov = lastOverview { renderOverview(ov, rebuildSubmenu: false); return }
        guard let snapshot = lastSnapshot else { return }
        renderPanel(snapshot)
    }

    func refresh() {
        guard let bin = resolveBinary("ai-usagebar") else {
            setError("ai-usagebar not found (PATH / ~/.cargo/bin / homebrew)")
            return
        }
        // Coalesce: one subprocess at a time, and remember that another was
        // asked for so a vendor change during a fetch is not simply dropped.
        if refreshInFlight {
            refreshQueued = true
            return
        }
        refreshInFlight = true
        refreshGeneration += 1
        let generation = refreshGeneration
        // Captured for THIS attempt: reading `VENDOR` again on completion would
        // label a late result with whatever is selected by then.
        let vendor = VENDOR

        if vendor == "overview" {
            refreshOverview(bin: bin, generation: generation)
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = vendorArgs(for: vendor) + ["--format", FORMAT_WITH_SENTINEL]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice

            // The subprocess takes the cache lock and may refresh OAuth over
            // the network; without a bound it can hold this worker for a very
            // long time. Kill it and report instead of hanging silently.
            let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + REFRESH_TIMEOUT, execute: watchdog)

            var out = ""
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()  // read before wait
                p.waitUntilExit()
                out = String(data: data, encoding: .utf8) ?? ""
            } catch {
                watchdog.cancel()
                DispatchQueue.main.async {
                    self?.finishRefresh(generation) { $0.setError("failed to run ai-usagebar") }
                }
                return
            }
            watchdog.cancel()
            let timedOut = out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            DispatchQueue.main.async {
                self?.finishRefresh(generation) { me in
                    // Selection may have changed while this ran.
                    guard vendor == VENDOR else { return }
                    if timedOut {
                        me.setError("ai-usagebar took too long (>\(Int(REFRESH_TIMEOUT))s)")
                    } else {
                        me.consume(out)
                    }
                }
            }
        }
    }

    /// Applies `body` only when `generation` is still the current attempt, then
    /// releases the in-flight slot and runs any request that arrived meanwhile.
    private func finishRefresh(_ generation: Int, _ body: (AppDelegate) -> Void) {
        let current = generation == refreshGeneration
        if current {
            refreshInFlight = false
            body(self)
        }
        if current && refreshQueued {
            refreshQueued = false
            refresh()
        }
    }

    /// Overview mode: fetch every configured vendor and render one compact row
    /// each. Sequential on purpose — reads are cache-first, and serializing
    /// respects the per-vendor cache flock and avoids an OAuth-refresh 429 burst.
    /// ponytail: parallelize only if it ever feels slow.
    func refreshOverview(bin: String, generation: Int) {
        // vendorEntries(active: "") keeps only configured entries — the
        // active-vendor courtesy slot has no place in an all-vendors sweep.
        let entries = filterOverviewEntries(vendorEntries(
                                                active: "",
                                                usageAccounts: lastAccountStatus?.usageAccounts),
                                            requested: configuredOverviewVendorIds())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var results: [(name: String, id: String, snap: Snapshot?)] = []
            var notices: [String: String] = [:]
            for v in entries {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = vendorArgs(for: v.id) + ["--format", FORMAT_WITH_SENTINEL]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global(qos: .utility)
                    .asyncAfter(deadline: .now() + REFRESH_TIMEOUT, execute: watchdog)
                var out = ""
                do {
                    try p.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    out = String(data: data, encoding: .utf8) ?? ""
                } catch { out = "" }
                watchdog.cancel()
                var snap: Snapshot?
                if let data = out.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = obj["text"] as? String {
                    snap = parse(text, vendor: baseVendorId(v.id))
                    notices[v.id] = providerNotice(obj, vendor: v.id)
                } else {
                    notices[v.id] = "Couldn't load usage. Try Refresh Now."
                }
                results.append((name: v.name, id: v.id, snap: snap))
            }
            DispatchQueue.main.async {
                self?.finishRefresh(generation) { me in
                    guard VENDOR == "overview" else { return }
                    me.providerNotices = notices
                    me.renderOverview(results)
                }
            }
        }
    }

    /// The single most-relevant number for a vendor in the overview.
    /// Cursor: the combined "included total usage" headline (both pools as one).
    /// Everyone else: the most-exhausted of its windows — for Anthropic that is
    /// the biggest of 5h, weekly, and the scoped model bar (Fable). Falls back to
    /// the $ budget when a vendor has no time windows.
    func overviewHeadline(_ s: Snapshot) -> (pct: Int, value: String, reset: String?, elapsed: Int?) {
        if let t = s.cursorTotalPct {
            return (t, "\(t)%", s.weekly?.reset ?? s.session?.reset, nil)
        }
        let windows = [s.session, s.weekly, s.sonnet, s.secondaryWeekly].compactMap { $0 }
        if let w = windows.max(by: { $0.pct < $1.pct }) {
            return (w.pct, "\(w.pct)%", w.reset, w.elapsed)
        }
        if let e = s.extra { return (e.pct, "\(e.spent) / \(e.limit)", nil, nil) }
        return (0, "—", nil, nil)
    }

    /// Compact bar label for a vendor name. Usually the first word; for a
    /// Claude account ("Claude · gmail") the account label is the part that
    /// distinguishes entries, so use it instead of the shared "Claude".
    func ovLabel(_ name: String, _ maxLen: Int) -> String {
        let base = name.range(of: " · ").map { String(name[$0.upperBound...]) }
            ?? String(name.split(separator: " ").first ?? Substring(name))
        return base.count <= maxLen ? base : String(base.prefix(maxLen))
    }

    /// Status-bar summary for overview mode: every vendor at once. Mini bar per
    /// vendor when few; worst-first numbers (capped, with `+K` overflow) when
    /// many. Tunable via `[ui] overview_menubar_bars_max` (bar↔number threshold,
    /// default 4) and `overview_menubar_max` (how many numbers fit, default 4).
    /// What the bar shows in overview mode: one dot-and-number pair per
    /// provider the summary includes. Alphabetical by display name, so a
    /// provider keeps its slot across refreshes instead of hopping when the
    /// numbers move. Providers hidden from the summary are dropped, as are
    /// balance-only ones (no percentage to grade) and any whose fetch came
    /// back empty; the dropdown still lists all of them.
    func overviewCompactEntries(_ items: [(name: String, id: String, snap: Snapshot?)]) -> [StatusEntry] {
        let visible = Set(overviewVisibleIds(items.map { $0.id },
                                             hidden: overviewHiddenProviders()))
        return items
            .filter { visible.contains($0.id) && $0.snap?.creditBalance == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .compactMap { item -> StatusEntry? in
                guard let s = item.snap else { return nil }
                let pct = overviewHeadline(s).pct
                return StatusEntry(pct: pct, text: "\(pct)", vendorId: item.id)
            }
    }

    func overviewBarTitle(_ items: [(name: String, id: String, snap: Snapshot?)],
                          _ appearance: NSAppearance) -> NSAttributedString {
        let secondary = menuBarTextColor(appearance, secondary: true)
        // Providers toggled off in the dropdown are dropped from the always-on
        // top summary (but still listed there so they can be re-enabled).
        let hidden = overviewHiddenProviders()
        let visible = Set(overviewVisibleIds(items.map { $0.id }, hidden: hidden))
        let heads: [(name: String, pct: Int, elapsed: Int?, value: String, reset: String?)] =
            items.compactMap {
                guard visible.contains($0.id), let s = $0.snap else { return nil }
                if let cb = s.creditBalance { return ($0.name, -1, nil, cb, nil) }
                let h = overviewHeadline(s)
                return ($0.name, h.pct, h.elapsed, "\(h.pct)%", h.reset.flatMap(shortReset))
            }
        guard !heads.isEmpty else { return run("ovr", secondary, statusFont) }

        let barsMax = Int(configValueTOML("ui", "overview_menubar_bars_max") ?? "") ?? 4
        let compact = DEF.bool(forKey: "overviewCompact")
        let t = NSMutableAttributedString()
        if overviewUsesBars(count: heads.count, barsMax: barsMax, compact: compact) {
            for (i, e) in heads.enumerated() {
                if i > 0 { t.append(run("   ", secondary, statusFont)) }
                t.append(run("\(ovLabel(e.name, 6)) ", secondary, statusFont))
                if e.pct >= 0 {
                    t.append(run("\(e.pct)% ", colorForPct(e.pct), statusDigitFont))
                    t.append(progressAttr(pct: e.pct, width: BAR_WIDTH, elapsed: e.elapsed,
                                          appearance: appearance))
                    if let r = e.reset { t.append(run(" \(r)", secondary, statusDigitFont)) }
                } else {
                    t.append(run(e.value, .labelColor, statusDigitFont))  // credit balance
                }
            }
        } else {
            let maxN = Int(configValueTOML("ui", "overview_menubar_max") ?? "") ?? 4
            // Entry order, not worst-first: entries are provider-grouped
            // (standard Claude, then its accounts, then the other vendors), and
            // stable positions beat a pct sort that reshuffles labels on every
            // refresh.
            for (i, e) in heads.prefix(maxN).enumerated() {
                if i > 0 { t.append(run("  ", secondary, statusFont)) }
                t.append(run("\(ovLabel(e.name, 3)) ", secondary, statusFont))
                t.append(run(e.value, e.pct >= 0 ? colorForPct(e.pct) : .labelColor, statusDigitFont))
                if let r = e.reset { t.append(run(" \(r)", secondary, statusDigitFont)) }
            }
            if heads.count > maxN { t.append(run("  +\(heads.count - maxN)", secondary, statusFont)) }
        }
        return t
    }

    /// One line under a provider header. Same shape the single-vendor menu
    /// renders, so both surfaces name and align the same things. `pct == nil`
    /// is a row with no gauge — a credit balance, or the em dash standing in
    /// for a provider whose fetch came back empty.
    struct OverviewDetail {
        let label: String
        let pct: Int?
        var value: String = ""
        var reset: String? = nil
        var elapsed: Int? = nil
        var dim: Bool = false
        var notice: Bool = false
    }

    /// Every window a provider actually reports, in the single-vendor menu's
    /// order. The headline (the worst of them) stays the menu bar's job; this
    /// is the arithmetic behind it.
    func overviewDetails(_ snap: Snapshot?) -> [OverviewDetail] {
        guard let s = snap else { return [OverviewDetail(label: "—", pct: nil, dim: true)] }
        var out: [OverviewDetail] = []
        if let cb = s.creditBalance {
            out.append(OverviewDetail(label: "Credits", pct: nil, value: cb))
        } else {
            if s.hasUsageWindows, let w = s.session {
                out.append(OverviewDetail(label: s.sessionLabel, pct: w.pct,
                                          value: "\(w.pct)%", reset: w.reset, elapsed: w.elapsed))
            }
            if s.hasUsageWindows, let w = s.weekly {
                out.append(OverviewDetail(label: s.weeklyLabel, pct: w.pct,
                                          value: "\(w.pct)%", reset: w.reset, elapsed: w.elapsed))
            }
        }
        if let w = s.sonnet {
            out.append(OverviewDetail(label: s.sonnetLabel, pct: w.pct,
                                      value: "\(w.pct)%", reset: w.reset, elapsed: w.elapsed))
        }
        if let w = s.secondaryWeekly {
            out.append(OverviewDetail(label: s.secondaryWeeklyLabel, pct: w.pct,
                                      value: "\(w.pct)%", reset: w.reset, elapsed: w.elapsed))
        } else if let e = s.extra {
            out.append(OverviewDetail(label: "Extra usage", pct: e.pct,
                                      value: "\(e.spent) / \(e.limit)"))
        }
        return out.isEmpty ? [OverviewDetail(label: "—", pct: nil, dim: true)] : out
    }

    /// A detail row on the single-vendor rows' tab stops: label, gauge, value,
    /// reset. Rows with no gauge tab straight to the value column, the way the
    /// Credits row does in single-vendor mode. `colW` is the label column every
    /// row in this render shares, so the whole menu reads as one grid.
    func overviewDetailTitle(_ d: OverviewDetail, _ colW: CGFloat,
                             _ appearance: NSAppearance) -> NSAttributedString {
        let a = NSMutableAttributedString()
        a.append(run(fitMenuLabel(d.label), d.dim ? .secondaryLabelColor : .labelColor,
                     menuLabelFont))
        if let pct = d.pct {
            a.append(run("\t", .labelColor, menuLabelFont))
            a.append(progressAttr(pct: pct, width: MENU_BAR_W, elapsed: d.elapsed,
                                  menu: true, appearance: appearance))
            a.append(run("\t\(d.value)", colorForPct(pct), menuDigitFont))
            if let r = d.reset, !r.isEmpty {
                a.append(run("\t↺ \(r)", .secondaryLabelColor, menuDigitFont))
            }
        } else if !d.value.isEmpty {
            a.append(run("\t\t\(d.value)", .labelColor, menuDigitFont))
        }
        a.addAttribute(.paragraphStyle,
                       value: menuRowStyle(colW, wideValue: menuValueIsWide(d.value, d.reset)),
                       range: NSRange(location: 0, length: a.length))
        return a
    }

    func renderOverview(_ items: [(name: String, id: String, snap: Snapshot?)],
                        rebuildSubmenu: Bool = true) {
        lastSnapshot = nil
        lastOverview = items
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        headerItem.attributedTitle = run("Overview", .labelColor, NSFont.boldSystemFont(ofSize: 13))
        for key in ["session", "weekly", "sonnet", "extra"] { rows[key]?.isHidden = true }

        // One section per provider: a header carrying the name and the ✓, then
        // its windows as indented detail rows. The pool is a flat list of menu
        // items, so "sections" is only a matter of how many slots each provider
        // claims — headers 1, plus one per detail row while it is shown.
        let hidden = overviewHiddenProviders()
        connectionNoticeItem.isHidden = true
        statusItem.button?.toolTip = items.compactMap { item in
            providerNotices[item.id].map { "\(item.name): \($0)" }
        }.joined(separator: "\n")
        let details = items.map { item -> [OverviewDetail] in
            guard !hidden.contains(item.id) else { return [] }
            var result = item.snap == nil && providerNotices[item.id] != nil ? [] : overviewDetails(item.snap)
            if let message = providerNotices[item.id] {
                result.insert(OverviewDetail(label: message, pct: nil, dim: true, notice: true), at: 0)
            }
            return result
        }
        ensureOverviewRowCapacity(items.count + details.reduce(0) { $0 + $1.count })
        // One label column for every provider's rows at once — measuring per
        // section would give each provider its own grid and the menu would read
        // as several ragged tables instead of one.
        let colW = menuLabelColumn(details.flatMap { $0 }.map { $0.label })

        var slot = 0
        for (i, item) in items.enumerated() {
            guard slot < overviewRows.count else { break }
            // Click a header to toggle whether this provider shows in the top-bar
            // summary. Checkmark = shown; unchecked = dimmed header with its
            // detail collapsed, so the toggle declutters both surfaces at once.
            // Jump-to-vendor lives in the "Switch Vendor" submenu and ⌥⌘\.
            let isHidden = hidden.contains(item.id)
            let head = overviewRows[slot]; slot += 1
            head.isHidden = false
            head.indentationLevel = 0
            head.isEnabled = true
            head.state = isHidden ? .off : .on
            head.representedObject = item.id
            head.target = self
            head.action = #selector(toggleOverviewProvider(_:))
            let fitted = item.name.count > 28 ? String(item.name.prefix(28)) + "…" : item.name
            head.attributedTitle = run(fitted, isHidden ? .tertiaryLabelColor : .labelColor,
                                       menuLabelFont)
            for d in details[i] {
                guard slot < overviewRows.count else { break }
                let it = overviewRows[slot]; slot += 1
                it.isHidden = false
                it.indentationLevel = 1     // native hierarchy; the stops still line up
                it.state = .off
                // A readout, not a control: disabled so it neither highlights nor
                // dismisses the menu on a stray click. Attributed colors still draw.
                it.isEnabled = false
                it.target = nil
                it.action = nil
                it.representedObject = nil
                it.attributedTitle = d.notice ? run(d.label, .secondaryLabelColor, menuLabelFont)
                    : overviewDetailTitle(d, colW, appearance)
            }
        }
        for i in slot..<overviewRows.count { overviewRows[i].isHidden = true }

        // Menu-bar title: every vendor at once (mini bars when few, numbers when
        // many). The dropdown always holds the full per-vendor list.
        setStatusFace(overviewCompactEntries(items),
                      textTitle: overviewBarTitle(items, appearance))
        // MENUBAR_MODE decides the bar's face now; overviewCompact only shapes
        // the "text" readout, so the item has nothing to do in the other modes.
        // ⌥⌘E still works everywhere for anyone who has learned it.
        compactItem.isHidden = MENUBAR_MODE != "text"
        updateCompactItemTitle()
        if rebuildSubmenu { rebuildVendorSubmenu() }
    }

    /// Add overview row slots before the single-vendor rows when newly
    /// discovered Claude accounts outgrow the initial built-in-vendor pool.
    private func ensureOverviewRowCapacity(_ count: Int) {
        guard count > overviewRows.count,
              let menu = statusItem.menu,
              let firstDetail = rows["session"] else { return }
        while overviewRows.count < count {
            let item = NSMenuItem()
            item.isHidden = true
            menu.insertItem(item, at: menu.index(of: firstDetail))
            overviewRows.append(item)
        }
    }

    func consume(_ output: String) {
        guard let data = output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else {
            setError("invalid output")
            return
        }
        providerNotices[VENDOR] = providerNotice(obj, vendor: VENDOR)
        guard let snap = parse(text, vendor: baseVendorId(VENDOR)) else {
            setError(providerNotices[VENDOR] ?? "Couldn't load usage. Check provider setup in Preferences.")
            return
        }
        lastSnapshot = snap
        renderPanel(snap)
        renderMenu(snap)
    }

    /// Paint the status item for the current menu-bar face — the one place any
    /// of them is assembled, so a new caller only has to describe its state as
    /// a list of providers.
    ///   • "text": `textTitle` verbatim — the full labelled readout.
    ///   • "icon": the dots alone, no numbers, so the bar keeps one glyph
    ///     language whichever face is on.
    ///   • "compact": a dot and its bare number per provider, pairs kept apart
    ///     by a short rule.
    /// Every face is text-side: several glyphs cannot ride a button's single
    /// `image`, so they are attachments and the image stays nil.
    func setStatusFace(_ entries: [StatusEntry], textTitle: NSAttributedString) {
        guard let button = statusItem.button else { return }
        button.image = nil
        if MENUBAR_MODE == "text" {
            button.attributedTitle = textTitle
            return
        }
        // The layout itself lives in `statusFaceTitle`, outside the delegate,
        // so the offscreen render harness can draw the real face instead of a
        // copy that drifts from it.
        button.attributedTitle = statusFaceTitle(entries, mode: MENUBAR_MODE,
                                                 glyph: MENUBAR_GLYPH,
                                                 appearance: button.effectiveAppearance)
    }

    func renderPanel(_ s: Snapshot) {
        let title = NSMutableAttributedString()
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let primaryTextColor = menuBarTextColor(appearance)
        let secondaryTextColor = menuBarTextColor(appearance, secondary: true)
        func seg(_ tag: String, _ pct: Int, _ value: String, _ elapsed: Int?) {
            if title.length > 0 { title.append(run("   ", secondaryTextColor, statusFont)) }
            title.append(run("\(tag) ", secondaryTextColor, statusFont))
            if SHOW_PERCENT { title.append(run(value + (SHOW_BARS ? " " : ""), colorForPct(pct), statusDigitFont)) }
            if SHOW_BARS { title.append(progressAttr(pct: pct, width: BAR_WIDTH, elapsed: elapsed, appearance: appearance)) }
            if !SHOW_PERCENT && !SHOW_BARS { title.append(run(value, colorForPct(pct), statusDigitFont)) }
        }
        if let creditBalance = s.creditBalance {
            title.append(run(creditBalance, primaryTextColor, statusDigitFont))
        } else if s.hasUsageWindows && SHOW_SESSION, let session = s.session {
            seg(s.sessionTag, session.pct, "\(session.pct)%", session.elapsed)
        }
        if s.creditBalance == nil && s.hasUsageWindows && SHOW_WEEKLY, let weekly = s.weekly {
            seg(s.weeklyTag, weekly.pct, "\(weekly.pct)%", weekly.elapsed)
        }
        if SHOW_EXTRA, let e = s.extra { seg("ex", e.pct, e.spent, nil) } // $ budget → no meta
        // The bar's number is the snapshot's headline — the worst of ALL its
        // windows, the scoped model bar included — not merely the worst of the
        // ones this text readout happens to draw. The dropdown lists that model
        // row either way, so a bar reading lower than a row above it lies.
        let headline = overviewHeadline(s)
        setStatusFace(s.creditBalance.map { [StatusEntry(pct: nil, text: $0, vendorId: VENDOR)] }
                        ?? [StatusEntry(pct: headline.pct, text: "\(headline.pct)",
                                        vendorId: VENDOR)],
                      textTitle: title.length > 0 ? title
                                                  : run("ai", secondaryTextColor, statusFont))
    }

    func renderMenu(_ s: Snapshot) {
        let message = providerNotices[VENDOR]
        connectionNoticeItem.isHidden = message == nil
        connectionNoticeItem.attributedTitle = run(message ?? "", .secondaryLabelColor, menuLabelFont)
        statusItem.button?.toolTip = message
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        for it in overviewRows { it.isHidden = true }
        compactItem.isHidden = true
        // With several Claude accounts the plan alone ("Claude Max 20x") no
        // longer says WHICH account this is — suffix the label.
        let plan = s.plan.isEmpty ? "AI Usage" : s.plan
        let header = accountLabel(of: VENDOR).map { "\(plan) · \($0)" } ?? plan
        headerItem.attributedTitle = run(header, .labelColor, NSFont.boldSystemFont(ofSize: 13))

        let colW = menuLabelColumn(overviewDetails(s).map { $0.label })

        func row(_ key: String, _ name: String, _ pct: Int, _ value: String, _ reset: String?, _ elapsed: Int?) {
            guard let item = rows[key] else { return }
            item.isHidden = false
            let a = NSMutableAttributedString()
            a.append(run("\(fitMenuLabel(name))\t", .labelColor, menuLabelFont))
            a.append(progressAttr(pct: pct, width: MENU_BAR_W, elapsed: elapsed, menu: true, appearance: appearance))
            a.append(run("\t\(value)", colorForPct(pct), menuDigitFont))
            if let r = reset, !r.isEmpty { a.append(run("\t↺ \(r)", .secondaryLabelColor, menuDigitFont)) }
            a.addAttribute(.paragraphStyle,
                           value: menuRowStyle(colW, wideValue: menuValueIsWide(value, reset)),
                           range: NSRange(location: 0, length: a.length))
            item.attributedTitle = a
        }
        if let creditBalance = s.creditBalance {
            rows["session"]?.isHidden = false
            let credits = NSMutableAttributedString()
            credits.append(run("Credits\t\t", .labelColor, menuLabelFont))
            credits.append(run(creditBalance, .labelColor, menuDigitFont))
            credits.addAttribute(.paragraphStyle, value: menuRowStyle(colW, wideValue: true),
                                 range: NSRange(location: 0, length: credits.length))
            rows["session"]?.attributedTitle = credits
            rows["weekly"]?.isHidden = true
            rows["sonnet"]?.isHidden = true
        } else {
            if s.hasUsageWindows, let session = s.session {
                row("session", s.sessionLabel, session.pct, "\(session.pct)%", session.reset, session.elapsed)
            } else { rows["session"]?.isHidden = true }
            if s.hasUsageWindows, let weekly = s.weekly {
                row("weekly", s.weeklyLabel, weekly.pct, "\(weekly.pct)%", weekly.reset, weekly.elapsed)
            } else { rows["weekly"]?.isHidden = true }
        }
        if let sn = s.sonnet { row("sonnet", s.sonnetLabel, sn.pct, "\(sn.pct)%", sn.reset, sn.elapsed) }
        else { rows["sonnet"]?.isHidden = true }
        if let weekly = s.secondaryWeekly {
            row("extra", s.secondaryWeeklyLabel, weekly.pct, "\(weekly.pct)%", weekly.reset, weekly.elapsed)
        } else if let e = s.extra {
            row("extra", "Extra usage", e.pct, "\(e.spent) / \(e.limit)", nil, nil)
        } else {
            rows["extra"]?.isHidden = true
        }
        rebuildVendorSubmenu()
    }

    // Vendor switch submenu: lists only configured vendors, with a checkmark on
    // the active one. Selecting one rewrites the `vendor` default and triggers a
    // refresh via the shared settings-change observer.
    func rebuildVendorSubmenu() {
        vendorSubmenu.removeAllItems()
        let active = VENDOR
        let entries = vendorEntries(active: active,
                                    usageAccounts: lastAccountStatus?.usageAccounts)
        if entries.isEmpty {
            let none = NSMenuItem(title: "None configured", action: nil, keyEquivalent: "")
            none.isEnabled = false
            vendorSubmenu.addItem(none)
            vendorSubmenuItem.isHidden = false
            return
        }
        for v in entries {
            let it = NSMenuItem(title: v.name, action: #selector(switchVendor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = v.id
            it.state = (v.id == active) ? .on : .off
            vendorSubmenu.addItem(it)
        }
        // Synthetic overview target — same one the ⌥⌘\ ring ends on.
        vendorSubmenu.addItem(.separator())
        let ov = NSMenuItem(title: "Overview", action: #selector(switchVendor(_:)), keyEquivalent: "")
        ov.target = self
        ov.representedObject = "overview"
        ov.state = (active == "overview") ? .on : .off
        vendorSubmenu.addItem(ov)
        vendorSubmenuItem.isHidden = false
    }

    @objc func switchVendor(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        DEF.set(id, forKey: "vendor")
    }

    /// Ask the binary who each surface is signed in as. Same off-main shape as
    /// `refresh()`; failures leave `lastAccountStatus` alone so a transient
    /// hiccup doesn't blank a working menu.
    func fetchAccountStatus() {
        guard let bin = resolveBinary("ai-usagebar") else { return }
        accountStatusFetchedAt = Date()
        accountStatusGeneration += 1
        let generation = accountStatusGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["account", "status", "--json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice

            let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + REFRESH_TIMEOUT, execute: watchdog)
            var data = Data()
            do {
                try p.run()
                data = pipe.fileHandleForReading.readDataToEndOfFile()  // read before wait
                p.waitUntilExit()
            } catch {
                watchdog.cancel()
                return
            }
            watchdog.cancel()
            guard let status = parseAccountStatus(data) else { return }
            DispatchQueue.main.async {
                guard let me = self, generation == me.accountStatusGeneration else { return }
                me.applyAccountStatus(status)
            }
        }
    }

    func applyAccountStatus(_ status: AccountStatus) {
        lastAccountStatus = status
        renderAccountMenus()
        rebuildVendorSubmenu()
    }

    func renderAccountMenus() {
        // Nil means the binary predates the subcommand: leave the menu exactly
        // as it was before this feature existed.
        guard let status = lastAccountStatus else {
            accountsInfoItem.isHidden = true
            desktopAccountItem.isHidden = true
            cliAccountItem.isHidden = true
            return
        }
        let line = accountsSummaryLine(status)
        accountsInfoItem.isHidden = line.isEmpty
        accountsInfoItem.attributedTitle = run(line, .secondaryLabelColor, menuLabelFont)

        fill(desktopAccountSubmenu, status.desktopLabels, status.desktopActive,
             #selector(switchDesktopAccount(_:)))
        fill(cliAccountSubmenu, status.cliLabels, status.cliActive,
             #selector(switchCliAccount(_:)))
        // Both stay visible with an empty list — that is when "Adicionar
        // conta…" matters most. Only a machine with no Claude Desktop app at
        // all loses its submenu.
        desktopAccountItem.isHidden = !status.desktopAvailable
        cliAccountItem.isHidden = false
        desktopAccountItem.isEnabled = !accountSwitchInFlight
        cliAccountItem.isEnabled = !accountSwitchInFlight
    }

    private func fill(_ submenu: NSMenu, _ labels: [String], _ active: String?, _ action: Selector) {
        submenu.removeAllItems()
        for label in labels {
            let it = NSMenuItem(title: label, action: action, keyEquivalent: "")
            it.target = self
            it.representedObject = label
            it.state = (label == active) ? .on : .off
            it.isEnabled = !accountSwitchInFlight && label != active
            submenu.addItem(it)
        }
        submenu.addItem(.separator())
        let add = NSMenuItem(title: "Add Account…",
                             action: #selector(addAccount(_:)), keyEquivalent: "")
        add.target = self
        add.representedObject = (submenu === desktopAccountSubmenu)
        add.isEnabled = !accountSwitchInFlight
        submenu.addItem(add)
    }

    /// Ask for a label, then hand the interactive part to Terminal: a Desktop
    /// capture waits for a browser sign-in, a CLI one runs `claude`. Neither
    /// belongs in a background subprocess the user cannot see or answer.
    @objc func addAccount(_ sender: NSMenuItem) {
        guard let desktop = sender.representedObject as? Bool,
              let bin = resolveBinary("ai-usagebar") else { return }
        let alert = NSAlert()
        alert.messageText = desktop ? "Add Claude Desktop account"
                                    : "Add Claude Code account"
        alert.informativeText = desktop
            ? "Pick a name. The app quits and reopens at the sign-in screen so you can "
                + "sign in with the new account; the current one is restored if you cancel."
            : "Pick a name. `claude` opens in Terminal for you to sign in; your current login "
                + "is left unchanged."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "work"
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        runInTerminal(addAccountScript(binary: bin, label: label, desktop: desktop))
    }

    /// Quits and reopens Claude.app, so confirm first — an unsent message or an
    /// in-flight Cowork run would go with it. The CLI switch has no visible
    /// side effect and needs no prompt.
    @objc func switchDesktopAccount(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Switch Claude Desktop account to “\(label)”?"
        alert.informativeText = "The app quits and reopens. Your local history is "
            + "merged into that account before switching, and a backup is written."
        alert.addButton(withTitle: "Switch and restart")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Routines deleted in one account but alive in another would be handed
        // straight back by the merge. Decide before the switch starts, since a
        // background subprocess has no way to ask.
        guard let doomed = resolveDeletionConflicts() else { return }
        runAccountSwitch(label: label, desktop: true, deleting: doomed)
    }

    /// Returns the routine ids to delete everywhere, or nil if the user backed
    /// out of the whole switch. An empty array means "keep them all".
    private func resolveDeletionConflicts() -> [String]? {
        let conflicts = lastAccountStatus?.deletionConflicts ?? []
        if conflicts.isEmpty { return [] }

        let alert = NSAlert()
        alert.messageText = conflicts.count == 1
            ? "1 item was deleted in one account and still exists in another"
            : "\(conflicts.count) items were deleted in one account and still exist in another"
        alert.informativeText = conflictPreview(conflicts)
            + "\n\nKeep restores the deleted ones. Delete removes them from every account — a conversation loses only its index; the transcript stays."
        alert.addButton(withTitle: "Keep All")
        alert.addButton(withTitle: "Delete Everywhere")
        alert.addButton(withTitle: "Choose…")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return []
        case .alertSecondButtonReturn: return conflicts.map { $0.key }
        default: return chooseDeletionConflicts(conflicts)
        }
    }

    /// A checkbox per conflict — checked means keep. Everything left unchecked
    /// is deleted everywhere, so the destructive outcome takes a deliberate
    /// uncheck rather than being the default.
    private func chooseDeletionConflicts(_ conflicts: [DeletionConflict]) -> [String]? {
        let rowHeight = 22
        let list = NSStackView(frame: NSRect(x: 0, y: 0, width: 420,
                                             height: rowHeight * conflicts.count))
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        var boxes: [NSButton] = []
        for conflict in conflicts {
            let box = NSButton(checkboxWithTitle: conflict.line, target: nil, action: nil)
            box.state = .on
            boxes.append(box)
            list.addArrangedSubview(box)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420,
                                                height: min(260, rowHeight * conflicts.count + 8)))
        scroll.hasVerticalScroller = true
        scroll.documentView = list

        let alert = NSAlert()
        alert.messageText = "What to keep?"
        alert.informativeText = "Checked items stay. Unchecked ones are deleted from every account."
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return zip(conflicts, boxes).filter { $0.1.state != .on }.map { $0.0.key }
    }

    @objc func switchCliAccount(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String else { return }
        runAccountSwitch(label: label, desktop: false)
    }

    private func runAccountSwitch(label: String, desktop: Bool, deleting: [String] = []) {
        guard let bin = resolveBinary("ai-usagebar"), !accountSwitchInFlight else { return }
        accountSwitchInFlight = true
        renderAccountMenus()
        let args = switchArgs(label: label, desktop: desktop, deleting: deleting)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let failure: String?
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let detail = String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    failure = detail.isEmpty
                        ? "ai-usagebar exited with status \(p.terminationStatus)."
                        : String(detail.prefix(2_000))
                } else {
                    failure = nil
                }
            } catch {
                failure = "Could not start ai-usagebar: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                guard let me = self else { return }
                me.accountSwitchInFlight = false
                me.fetchAccountStatus()
                if let failure {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Could not switch account"
                    alert.informativeText = failure
                    alert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                } else {
                    // The usage numbers belong to whoever is signed in now.
                    me.refresh()
                }
            }
        }
    }

    /// Toggle whether a provider appears in the Overview top-bar summary, from
    /// its dropdown row. The UserDefaults observer re-renders from the last
    /// fetch and consumes this presentation-only change without re-fetching.
    @objc func toggleOverviewProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        overviewVisibilityChangePending = true
        setOverviewProvider(id, hidden: !overviewHiddenProviders().contains(id))
    }

    func setError(_ msg: String) {
        connectionNoticeItem.isHidden = true
        statusItem.button?.toolTip = msg
        lastSnapshot = nil
        // One error face in every mode: the system's own warning symbol (a
        // template, so it tints itself) and no text. The message is one click
        // away in the dropdown header, where there is room to read it.
        statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                           accessibilityDescription: "error")
        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        headerItem.attributedTitle = run(msg, menuBarTextColor(appearance), menuLabelFont)
        for (_, it) in rows { it.isHidden = true }
        for it in overviewRows { it.isHidden = true }
        compactItem.isHidden = true
        accountsInfoItem.isHidden = true
    }
}

#if !SWIFT_TEST_HARNESS
@main
struct AppMain {
    static func main() {
        DEF.register(defaults: SETTINGS_DEFAULTS)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar agent, no Dock icon
        app.run()
    }
}
#endif
