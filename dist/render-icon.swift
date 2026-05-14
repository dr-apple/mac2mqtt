import AppKit

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fputs("No graphics context\n", stderr)
    exit(1)
}

ctx.setFillColor(NSColor.clear.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

ctx.setStrokeColor(NSColor.black.cgColor)
ctx.setLineWidth(62)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * 1024.0, y: y * 1024.0) }
func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x * 1024.0, y: y * 1024.0, width: w * 1024.0, height: h * 1024.0)
}

// Outer hybrid shell.
let outer = NSBezierPath(roundedRect: r(0.08, 0.08, 0.84, 0.84), xRadius: 0.2 * 1024.0, yRadius: 0.2 * 1024.0)
outer.stroke()

// Finder-like split.
let split = NSBezierPath()
split.move(to: p(0.5, 0.14))
split.line(to: p(0.5, 0.86))
split.stroke()

// Left eye + smile.
NSBezierPath(ovalIn: r(0.30, 0.60, 0.08, 0.08)).fill()
let smile = NSBezierPath()
smile.move(to: p(0.28, 0.36))
smile.curve(to: p(0.44, 0.33), controlPoint1: p(0.33, 0.30), controlPoint2: p(0.39, 0.30))
smile.stroke()

// Right remote ring + center.
NSBezierPath(ovalIn: r(0.58, 0.56, 0.20, 0.20)).stroke()
NSBezierPath(ovalIn: r(0.66, 0.64, 0.04, 0.04)).fill()

// Remote lower buttons.
NSBezierPath(ovalIn: r(0.61, 0.34, 0.06, 0.06)).fill()
NSBezierPath(ovalIn: r(0.71, 0.34, 0.06, 0.06)).fill()

image.unlockFocus()

let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: "./dist/icon-1024.png"))
