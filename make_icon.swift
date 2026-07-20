// Renders the app icon (a usage-meter gauge on a warm gradient) to a 1024px PNG.
// Usage: swift make_icon.swift <output.png>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rad(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

// --- Squircle background with warm Claude-toned gradient ---
let inset: CGFloat = S * 0.06
let rect = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let corner = rect.width * 0.2237
let bg = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
bg.addClip()
let grad = NSGradient(colors: [
    NSColor(srgbRed: 0.98, green: 0.55, blue: 0.36, alpha: 1),  // top: soft coral
    NSColor(srgbRed: 0.85, green: 0.30, blue: 0.22, alpha: 1),  // bottom: deep terracotta
])!
grad.draw(in: bg, angle: -90)

// subtle top sheen
let sheen = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.18),
    NSColor.white.withAlphaComponent(0.0),
])!
sheen.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)

// --- Gauge ---
let cx = S / 2, cy = S / 2 - S * 0.02
let R = S * 0.28
let lw = S * 0.085
let startDeg: CGFloat = 210, sweep: CGFloat = 240   // opening at the bottom
let fraction: CGFloat = 0.68

func arc(from a0: CGFloat, to a1: CGFloat, color: NSColor, width: CGFloat) {
    let p = NSBezierPath()
    p.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: R,
                startAngle: a0, endAngle: a1, clockwise: true)
    p.lineWidth = width
    p.lineCapStyle = .round
    color.setStroke()
    p.stroke()
}

// Track
arc(from: startDeg, to: startDeg - sweep, color: NSColor.white.withAlphaComponent(0.28), width: lw)
// Progress
arc(from: startDeg, to: startDeg - sweep * fraction, color: NSColor.white.withAlphaComponent(0.95), width: lw)

// --- Needle ---
let needleAngle = rad(startDeg - sweep * fraction)
let tip = NSPoint(x: cx + cos(needleAngle) * (R - lw * 0.1),
                  y: cy + sin(needleAngle) * (R - lw * 0.1))
let needle = NSBezierPath()
needle.move(to: NSPoint(x: cx, y: cy))
needle.line(to: tip)
needle.lineWidth = S * 0.028
needle.lineCapStyle = .round
NSColor.white.setStroke()
needle.stroke()

// Hub
let hubR = S * 0.05
let hub = NSBezierPath(ovalIn: NSRect(x: cx - hubR, y: cy - hubR, width: hubR * 2, height: hubR * 2))
NSColor.white.setFill(); hub.fill()
let hubInner = NSBezierPath(ovalIn: NSRect(x: cx - hubR * 0.45, y: cy - hubR * 0.45,
                                           width: hubR * 0.9, height: hubR * 0.9))
NSColor(srgbRed: 0.85, green: 0.30, blue: 0.22, alpha: 1).setFill(); hubInner.fill()

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
