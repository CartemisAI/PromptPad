// Draws the PromptPad app icon: a keycap with a voice waveform on an indigo-to-teal tile.
// Usage: swift make_icon.swift <output.png> [size]
import AppKit

let out = CommandLine.arguments[1]
let S = CGFloat(Double(CommandLine.arguments.dropFirst(2).first ?? "1024") ?? 1024)
// Draw into a bitmap of exactly S x S pixels (lockFocus would double it on Retina screens).
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Tile with macOS-style margins and corner radius.
let inset = S * 0.098
let tile = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
ctx.saveGState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = S * 0.03; shadow.shadowOffset = NSSize(width: 0, height: -S * 0.012); shadow.set()
NSColor.black.setFill(); tilePath.fill()
ctx.restoreGState()
NSGradient(colors: [NSColor(srgbRed: 0.24, green: 0.20, blue: 0.56, alpha: 1),
                    NSColor(srgbRed: 0.10, green: 0.52, blue: 0.55, alpha: 1)])!
    .draw(in: tilePath, angle: -60)

// Keycap.
let capW = tile.width * 0.62
let cap = NSRect(x: tile.midX - capW / 2, y: tile.midY - capW / 2 - tile.width * 0.02, width: capW, height: capW)
let capPath = NSBezierPath(roundedRect: cap, xRadius: capW * 0.2, yRadius: capW * 0.2)
ctx.saveGState()
let s2 = NSShadow(); s2.shadowColor = NSColor.black.withAlphaComponent(0.30)
s2.shadowBlurRadius = S * 0.025; s2.shadowOffset = NSSize(width: 0, height: -S * 0.02); s2.set()
NSColor(white: 0.97, alpha: 1).setFill(); capPath.fill()
ctx.restoreGState()
let top = cap.insetBy(dx: capW * 0.07, dy: capW * 0.07).offsetBy(dx: 0, dy: capW * 0.03)
NSGradient(colors: [NSColor.white, NSColor(white: 0.90, alpha: 1)])!
    .draw(in: NSBezierPath(roundedRect: top, xRadius: capW * 0.15, yRadius: capW * 0.15), angle: -90)

// Waveform bars on the keycap.
let heights: [CGFloat] = [0.28, 0.55, 0.85, 0.55, 0.28]
let barW = top.width * 0.085, gap = top.width * 0.07
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = top.midX - total / 2
let barColor = NSColor(srgbRed: 0.20, green: 0.30, blue: 0.62, alpha: 1)
for h in heights {
    let bh = top.height * 0.62 * h
    let r = NSRect(x: x, y: top.midY - bh / 2, width: barW, height: bh)
    barColor.setFill(); NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
    x += barW + gap
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
