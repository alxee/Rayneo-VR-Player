// make-icon.swift — draws the Rayneo VR Player app icon: a refined pair of
// AR smart glasses (RayNeo Air style) in glossy white on a deep-black
// squircle. Everything is centered on the canvas: the glasses' bounding box
// sits at the exact optical center (512, 512).
//
// Outputs Resources/AppIcon.png (1024²) for build.sh → iconset → icns.
import AppKit

let size: CGFloat = 1024
let cx = size / 2
let cy = size / 2

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// ---- background: deep black squircle with a soft radial lift ------------
// Leave ~10% transparent padding around the squircle: macOS uses that margin
// for the standard drop shadow and tile spacing. Without it the icon renders
// edge-to-edge and looks larger than other apps in Launchpad.
let pad = size * 0.10
let squircleSize = size - 2 * pad
let radius = squircleSize * 0.2237
let squircle = NSBezierPath(roundedRect: NSRect(x: pad, y: pad,
                                                width: squircleSize, height: squircleSize),
                            xRadius: radius, yRadius: radius)
NSColor.black.setFill()
squircle.fill()

ctx.saveGState()
squircle.addClip()
// Radial charcoal lift so the glyph doesn't float on flat black — reads as
// a lit product backdrop at large sizes, still pure black at 16 px.
let bg = NSGradient(colors: [
    NSColor(calibratedWhite: 0.115, alpha: 1),
    NSColor(calibratedWhite: 0.045, alpha: 1),
    NSColor.black,
])!
bg.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
        relativeCenterPosition: NSPoint(x: 0, y: 0.16))
ctx.restoreGState()

ctx.saveGState()
squircle.addClip()

// ---- glasses geometry ---------------------------------------------------
// Front-view pair: two big rounded lenses, narrow bridge, short temples.
// Glyph width 612 = 60% of canvas; bounding box vertically centered.
let lensW: CGFloat = 282
let lensH: CGFloat = 176
let gap: CGFloat = 48
let corner: CGFloat = 64
let stroke: CGFloat = 15
let totalW = lensW * 2 + gap
let leftX = cx - totalW / 2
let rightX = leftX + lensW + gap
let topY = cy + lensH / 2
let bottomY = cy - lensH / 2

func lensPath(_ x: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: bottomY, width: lensW, height: lensH),
                 xRadius: corner, yRadius: corner)
}

// Soft white bloom behind the whole frame — gives the white ceramic a glow
// on black without washing out the edges.
let bloom = NSShadow()
bloom.shadowColor = NSColor(calibratedWhite: 1, alpha: 0.16)
bloom.shadowBlurRadius = 64
bloom.shadowOffset = .zero

// ---- temples: tapered arms sweeping out and slightly back/down ----------
for sign in [CGFloat(-1), CGFloat(1)] {
    let startX = sign < 0 ? leftX : rightX + lensW
    let startY = topY - lensH * 0.20
    let dir = sign
    let tipX = startX + dir * 82
    let tipY = startY - 16
    let arm = NSBezierPath()
    arm.move(to: NSPoint(x: startX, y: startY + 8))
    arm.curve(to: NSPoint(x: tipX, y: tipY + 3),
              controlPoint1: NSPoint(x: startX + dir * 38, y: startY + 10),
              controlPoint2: NSPoint(x: tipX - dir * 24, y: tipY + 5))
    arm.curve(to: NSPoint(x: tipX, y: tipY - 4),
              controlPoint1: NSPoint(x: tipX + dir * 6, y: tipY - 1),
              controlPoint2: NSPoint(x: tipX + dir * 4, y: tipY - 4))
    arm.curve(to: NSPoint(x: startX, y: startY - 7),
              controlPoint1: NSPoint(x: tipX - dir * 28, y: tipY - 9),
              controlPoint2: NSPoint(x: startX + dir * 34, y: startY - 9))
    arm.close()
    NSGraphicsContext.saveGraphicsState()
    bloom.set()
    NSColor.white.setFill()
    arm.fill()
    NSGraphicsContext.restoreGraphicsState()
}

// ---- bridge: slim arch joining the lenses at the top --------------------
let bridge = NSBezierPath()
bridge.move(to: NSPoint(x: leftX + lensW - 3, y: topY - 8))
bridge.curve(to: NSPoint(x: rightX + 3, y: topY - 8),
             controlPoint1: NSPoint(x: cx - gap * 0.75, y: topY + 3),
             controlPoint2: NSPoint(x: cx + gap * 0.75, y: topY + 3))
bridge.line(to: NSPoint(x: rightX + 3, y: topY - 26))
bridge.curve(to: NSPoint(x: leftX + lensW - 3, y: topY - 26),
             controlPoint1: NSPoint(x: cx + gap * 0.75, y: topY - 15),
             controlPoint2: NSPoint(x: cx - gap * 0.75, y: topY - 15))
bridge.close()

// ---- lenses -------------------------------------------------------------
for x in [leftX, rightX] {
    let outer = lensPath(x)

    // 1. Glass: subtle top-lit gradient inside the frame.
    NSGraphicsContext.saveGraphicsState()
    outer.addClip()
    let glass = NSGradient(colors: [
        NSColor(calibratedWhite: 1, alpha: 0.16),
        NSColor(calibratedWhite: 1, alpha: 0.04),
    ])!
    glass.draw(in: NSRect(x: x, y: bottomY, width: lensW, height: lensH), angle: -90)

    // 2. Diagonal sheen across the upper half of the glass.
    let sheen = NSBezierPath()
    sheen.move(to: NSPoint(x: x - 40, y: bottomY + lensH * 0.55))
    sheen.line(to: NSPoint(x: x + lensW * 0.52, y: topY + 60))
    sheen.line(to: NSPoint(x: x + lensW * 0.78, y: topY + 60))
    sheen.line(to: NSPoint(x: x - 40, y: bottomY + lensH * 0.28))
    sheen.close()
    NSColor(calibratedWhite: 1, alpha: 0.05).setFill()
    sheen.fill()

    // 3. Top inner bevel: thin bright line suggesting a polished rim.
    let bevel = NSBezierPath(roundedRect: NSRect(x: x + 16, y: bottomY + 16,
                                                 width: lensW - 32, height: lensH - 32),
                             xRadius: corner - 12, yRadius: corner - 12)
    bevel.lineWidth = 2
    NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
    bevel.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // 4. The frame itself.
    NSGraphicsContext.saveGraphicsState()
    bloom.set()
    NSColor.white.setStroke()
    outer.lineWidth = stroke
    outer.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

// Bridge drawn after the lenses so it reads as one continuous frame.
NSGraphicsContext.saveGraphicsState()
bloom.set()
NSColor.white.setFill()
bridge.fill()
NSGraphicsContext.restoreGraphicsState()

ctx.restoreGState()
image.unlockFocus()

// Write PNG (alpha preserved outside the squircle).
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png encode failed")
}
let out = URL(fileURLWithPath: "Resources/AppIcon.png")
try! FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
try! png.write(to: out)
print("wrote \(out.path)")
