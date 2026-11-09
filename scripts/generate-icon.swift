#!/usr/bin/env swift
// Generates docs/assets/icon.png (1024 x 1024).
//
// A hand-drawn gopher peeking up from the bottom; its eyes spell "og".
// The Go gopher was designed by Renée French and is licensed under CC BY 4.0.
//
// usage: swift scripts/generate-icon.swift [out.png]
import AppKit

let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context") }

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((v >> 16) & 255) / 255, CGFloat((v >> 8) & 255) / 255, CGFloat(v & 255) / 255, a])
        ?? CGColor(gray: 0, alpha: 1)
}

let ink = hex(0x101114)
let lime = hex(0xC8FF2E)

// macOS icon grid: 824 px tile centered in 1024, continuous-corner radius ~185.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// MARK: - Hand-drawn lines

/// Low-frequency wobble with integer harmonics, so a closed loop meets itself exactly (no lump at the seam).
func wobble(_ th: CGFloat, _ amp: CGFloat, _ phase: CGFloat) -> CGFloat {
    amp * (0.6 * sin(2 * th + phase) + 0.3 * sin(3 * th + phase * 1.7) + 0.1 * sin(5 * th + phase * 2.3))
}

/// A slightly uneven loop, drawn as a smooth curve through many samples.
func loop(_ c: CGPoint, _ r: CGFloat, squash: CGFloat = 1, amp: CGFloat = 0.018, phase: CGFloat) -> CGPath {
    let n = 96
    var pts: [CGPoint] = []
    for i in 0..<n {
        let th = 2 * .pi * CGFloat(i) / CGFloat(n)
        let k = 1 + wobble(th, amp, phase)
        pts.append(CGPoint(x: c.x + r * k * cos(th), y: c.y + r * squash * k * sin(th)))
    }
    return smoothClosed(pts)
}

/// Catmull-Rom through closed points -> cubic Béziers.
func smoothClosed(_ p: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    let n = p.count
    path.move(to: p[0])
    for i in 0..<n {
        let p0 = p[(i - 1 + n) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: c1, control2: c2)
    }
    path.closeSubpath()
    return path
}

func stroke(_ path: CGPath, _ width: CGFloat, _ color: CGColor = lime) {
    ctx.addPath(path)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}

func fill(_ path: CGPath, _ color: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

// MARK: - Tile

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: hex(0x000000, 0.35))
fill(tilePath, ink)
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
// A faint top light so the black tile is not flat.
if let g = CGGradient(colorsSpace: cs, colors: [hex(0x1A1C21), hex(0x0E0F12)] as CFArray, locations: [0, 1]) {
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
}

let line: CGFloat = 24    // head and ears
let letter: CGFloat = 42  // the "og" eyes

// MARK: - Ears (behind the head)

let leftEar = loop(CGPoint(x: 214, y: 640), 70, squash: 1.04, amp: 0.03, phase: 0.8)
let rightEar = loop(CGPoint(x: 812, y: 652), 68, squash: 1.04, amp: 0.03, phase: 2.4)
for ear in [leftEar, rightEar] {
    fill(ear, ink)
    stroke(ear, line)
}

// MARK: - Head: one dome rising from below the tile

let head = CGMutablePath()
head.move(to: CGPoint(x: 152, y: 60))
head.addCurve(to: CGPoint(x: 512, y: 776), control1: CGPoint(x: 150, y: 560), control2: CGPoint(x: 262, y: 780))
head.addCurve(to: CGPoint(x: 872, y: 60), control1: CGPoint(x: 768, y: 772), control2: CGPoint(x: 880, y: 556))
fill(head, ink)
stroke(head, line)

// MARK: - Eyes: "o" and "g"

let oCenter = CGPoint(x: 374, y: 566), oR: CGFloat = 106
let gCenter = CGPoint(x: 650, y: 566), gR: CGFloat = 100

// g's stem and hook, drawn first so the bowl overlaps it cleanly.
let stemX = gCenter.x + gR
let hookR: CGFloat = 74
let hookY: CGFloat = 430
let tail = CGMutablePath()
// Geometric g: the stem rises to the top of the bowl, tangent to it.
tail.move(to: CGPoint(x: stemX, y: gCenter.y + gR))
tail.addLine(to: CGPoint(x: stemX, y: hookY))
tail.addArc(center: CGPoint(x: stemX - hookR, y: hookY), radius: hookR, startAngle: 0, endAngle: -.pi * 0.86, clockwise: true)
stroke(tail, letter)

for (c, r, ph) in [(oCenter, oR, CGFloat(0.4)), (gCenter, gR, CGFloat(2.1))] {
    let ring = loop(c, r, squash: 1.02, phase: ph)
    fill(ring, ink)
    stroke(ring, letter)
}

// Pupils look up and to the right, like the original gopher.
for (c, r) in [(oCenter, oR), (gCenter, gR)] {
    let p = CGPoint(x: c.x + r * 0.30, y: c.y + r * 0.26)
    let pr: CGFloat = 30
    ctx.setFillColor(lime)
    ctx.fillEllipse(in: CGRect(x: p.x - pr, y: p.y - pr, width: pr * 2, height: pr * 2))
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: p.x + 6, y: p.y + 8, width: 15, height: 15))
}

ctx.restoreGState()

// MARK: - Write

guard let image = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("encode") }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/assets/icon.png"
let url = URL(fileURLWithPath: out)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: url)
print("Generated icon at \(out)")
