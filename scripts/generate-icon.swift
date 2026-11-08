#!/usr/bin/env swift
import AppKit
import CoreGraphics

let size = 1024
let width = CGFloat(size)
let height = CGFloat(size)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: size * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Failed to create CGContext")
}

ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r / 255.0, g / 255.0, b / 255.0, a])!
}

// 1. macOS Squircle Background (matching Fleet's exact dark slate material)
let squircleRect = CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: 8, dy: 8)
let cornerRadius: CGFloat = 224
let squirclePath = CGPath(roundedRect: squircleRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

ctx.saveGState()
ctx.addPath(squirclePath)
ctx.clip()

let bgColors = [
    rgba(25, 29, 36),
    rgba(17, 20, 26)
] as CFArray
if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: 120, y: height),
        end: CGPoint(x: width, y: 0),
        options: []
    )
}

// Ambient Go-Cyan / Mint glow around the live cursor beacon
let activeNode = CGPoint(x: 648, y: 364)
let glowColors = [
    rgba(0, 216, 245, 0.12),
    rgba(45, 224, 182, 0.04),
    rgba(17, 20, 26, 0.0)
] as CFArray
if let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 0.45, 1.0]) {
    ctx.drawRadialGradient(
        glowGrad,
        startCenter: activeNode,
        startRadius: 0,
        endCenter: activeNode,
        endRadius: 340,
        options: []
    )
}
ctx.restoreGState()

// Squircle border
ctx.saveGState()
ctx.addPath(squirclePath)
ctx.setStrokeColor(rgba(42, 47, 57))
ctx.setLineWidth(14)
ctx.strokePath()
ctx.restoreGState()

// 2. Editor + Terminal Frame (same #2D333F dark structural stroke as Fleet's rings)
let frameRect = CGRect(x: 204, y: 214, width: 616, height: 596)
let framePath = CGPath(roundedRect: frameRect, cornerWidth: 110, cornerHeight: 110, transform: nil)

ctx.saveGState()
ctx.addPath(framePath)
ctx.setStrokeColor(rgba(45, 51, 63))
ctx.setLineWidth(20)
ctx.strokePath()

// Subtle inner header divider
ctx.setStrokeColor(rgba(40, 46, 58))
ctx.setLineWidth(16)
ctx.move(to: CGPoint(x: 204, y: 656))
ctx.addLine(to: CGPoint(x: 820, y: 656))
ctx.strokePath()
ctx.restoreGState()

// Window header dots (muted slate)
ctx.saveGState()
ctx.setFillColor(rgba(72, 81, 98))
for i in 0..<3 {
    let dotX = CGFloat(292 + i * 48)
    ctx.fillEllipse(in: CGRect(x: dotX - 13, y: 724 - 13, width: 26, height: 26))
}
ctx.restoreGState()

// 3. Inside Editor: Prompt Chevron `>` + Indented Code / AST Lines
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// Bold chevron `>` on the left (Go / Terminal prompt)
ctx.setStrokeColor(rgba(110, 120, 139))
ctx.setLineWidth(28)
ctx.move(to: CGPoint(x: 294, y: 558))
ctx.addLine(to: CGPoint(x: 382, y: 478))
ctx.addLine(to: CGPoint(x: 294, y: 398))
ctx.strokePath()

// Top code bar (muted slate)
ctx.setStrokeColor(rgba(110, 120, 139))
ctx.setLineWidth(28)
ctx.move(to: CGPoint(x: 452, y: 558))
ctx.addLine(to: CGPoint(x: 704, y: 558))
ctx.strokePath()

// Middle code bar (structural slate)
ctx.setStrokeColor(rgba(78, 88, 106))
ctx.setLineWidth(28)
ctx.move(to: CGPoint(x: 452, y: 468))
ctx.addLine(to: CGPoint(x: 564, y: 468))
ctx.strokePath()

// Bottom code bar (subtle slate)
ctx.setStrokeColor(rgba(68, 77, 94))
ctx.setLineWidth(26)
ctx.move(to: CGPoint(x: 304, y: 314))
ctx.addLine(to: CGPoint(x: 484, y: 314))
ctx.strokePath()
ctx.restoreGState()

// 4. Fleet-style Glowing Active Beacon (Go Cyan -> Mint with translucent halo ring)
let haloRadius: CGFloat = 86
let coreRadius: CGFloat = 50

ctx.saveGState()
// Translucent outer halo ring (exactly like Fleet: no opaque cutout, blends over structure)
ctx.setStrokeColor(rgba(45, 224, 182, 0.36))
ctx.setLineWidth(18)
ctx.strokeEllipse(in: CGRect(x: activeNode.x - haloRadius, y: activeNode.y - haloRadius, width: haloRadius * 2, height: haloRadius * 2))

// Bright core dot (Go Cyan-Mint)
let coreRect = CGRect(x: activeNode.x - coreRadius, y: activeNode.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2)
ctx.saveGState()
ctx.addEllipse(in: coreRect)
ctx.clip()
let coreColors = [
    rgba(0, 214, 246),
    rgba(45, 228, 182)
] as CFArray
if let coreGrad = CGGradient(colorsSpace: colorSpace, colors: coreColors, locations: [0.0, 1.0]) {
    ctx.drawLinearGradient(
        coreGrad,
        start: CGPoint(x: activeNode.x - coreRadius, y: activeNode.y + coreRadius),
        end: CGPoint(x: activeNode.x + coreRadius, y: activeNode.y - coreRadius),
        options: []
    )
}
ctx.restoreGState()
ctx.restoreGState()

guard let cgImage = ctx.makeImage() else {
    fatalError("Failed to make CGImage")
}
let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to encode PNG")
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/assets/icon.png"
let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try pngData.write(to: outputURL)
print("Generated icon at \(outputPath)")
