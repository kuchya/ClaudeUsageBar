// Renders a promo screenshot of the menu-bar UI to assets/screenshot.png.
// Usage: swift make_screenshot.swift <output.png>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "screenshot.png"
let W: CGFloat = 900, H: CGFloat = 690

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let red = NSColor.systemRed
let orange = NSColor.systemOrange
let dim = NSColor(white: 0.62, alpha: 1)
let white = NSColor(white: 0.96, alpha: 1)

func colorFor(_ p: Double) -> NSColor { p >= 90 ? red : (p >= 70 ? orange : white) }

// top-left origin text helper
func draw(_ s: String, x: CGFloat, topY: CGFloat, font: NSFont, color: NSColor) {
    let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: a)
    str.draw(at: NSPoint(x: x, y: H - topY - font.pointSize * 1.3))
}
func width(_ s: String, _ font: NSFont) -> CGFloat {
    NSAttributedString(string: s, attributes: [.font: font]).size().width
}

// --- Background (soft desktop gradient) ---
NSGradient(colors: [
    NSColor(srgbRed: 0.13, green: 0.24, blue: 0.36, alpha: 1),
    NSColor(srgbRed: 0.07, green: 0.13, blue: 0.20, alpha: 1),
])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// --- Mini dual-bar gauge ---
func drawGauge(x: CGFloat, topY: CGFloat, h: CGFloat, session: Double, weekly: Double) {
    let barW: CGFloat = h * 0.30, gap: CGFloat = h * 0.18
    let baseY = H - topY - h
    for (i, pct) in [session, weekly].enumerated() {
        let bx = x + CGFloat(i) * (barW + gap)
        NSColor(white: 1, alpha: 0.28).setFill()
        NSBezierPath(roundedRect: NSRect(x: bx, y: baseY, width: barW, height: h), xRadius: 2, yRadius: 2).fill()
        let fh = max(h * CGFloat(pct / 100.0), 2)
        colorFor(pct).setFill()
        NSBezierPath(roundedRect: NSRect(x: bx, y: baseY, width: barW, height: fh), xRadius: 2, yRadius: 2).fill()
    }
}

// --- Menu-bar pill ---
let pill = NSRect(x: 40, y: H - 78, width: 430, height: 50)
NSColor(white: 0, alpha: 0.55).setFill()
NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()

let mbFont = NSFont.monospacedDigitSystemFont(ofSize: 21, weight: .medium)
drawGauge(x: 60, topY: 40, h: 26, session: 94, weekly: 52)
var cx: CGFloat = 96
let mbSegs: [(String, NSColor)] = [("S 94% ", red), ("2h20m   ", dim), ("W 52% ", white), ("4d15h", dim)]
for (t, c) in mbSegs { draw(t, x: cx, topY: 33, font: mbFont, color: c); cx += width(t, mbFont) }

// --- Dropdown panel ---
let panel = NSRect(x: 40, y: 24, width: 520, height: 560)
NSColor(srgbRed: 0.05, green: 0.10, blue: 0.16, alpha: 0.98).setFill()
let panelPath = NSBezierPath(roundedRect: panel, xRadius: 16, yRadius: 16)
panelPath.fill()
NSColor(white: 1, alpha: 0.10).setStroke()
panelPath.lineWidth = 1
panelPath.stroke()

func sep(topY: CGFloat) {
    NSColor(white: 1, alpha: 0.10).setFill()
    NSBezierPath(rect: NSRect(x: 70, y: H - topY, width: 460, height: 1)).fill()
}

let hdr = NSFont.systemFont(ofSize: 22, weight: .semibold)
let sub = NSFont.systemFont(ofSize: 17, weight: .regular)
let row = NSFont.systemFont(ofSize: 20, weight: .regular)

draw("Session (5h):  94%", x: 70, topY: 108, font: hdr, color: red)
draw("resets in 2h 20m   (Tue 01:59)", x: 92, topY: 152, font: sub, color: dim)
draw("Weekly (7d):   52%", x: 70, topY: 196, font: hdr, color: white)
draw("resets in 4d 15h   (Sat 15:29)", x: 92, topY: 240, font: sub, color: dim)
sep(topY: 292)
draw("Updated 11:39:25 PM", x: 70, topY: 312, font: sub, color: dim)
sep(topY: 360)
draw("✓  Notify at 80% / 90%", x: 70, topY: 380, font: row, color: white)
draw("✓  Start at Login", x: 70, topY: 428, font: row, color: white)
sep(topY: 480)
draw("Refresh Now", x: 70, topY: 500, font: row, color: white)
draw("⌘R", x: 470, topY: 500, font: row, color: dim)
draw("Quit", x: 70, topY: 548, font: row, color: white)
draw("⌘Q", x: 470, topY: 548, font: row, color: dim)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
