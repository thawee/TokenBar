// Draws the 1024 px app icon master: the side dock as a bar of three ring gauges, in
// the rail's navy and the system metric tints. Run via scripts/make-icon.sh.
import AppKit

let size: CGFloat = 1024
// macOS icon grid: an 824 pt body centered on the 1024 canvas, corner radius 185.4.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let shape = CGPath(roundedRect: body, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)

// Body with the template's soft drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(shape)
ctx.setFillColor(color(0.06, 0.11, 0.22))
ctx.fillPath()
ctx.restoreGState()

// The rail's gradient, a little lighter at the top for depth. Drawn row by row:
// with drawLinearGradient the 1024 px PNG was 240 KB, with rows 91 KB.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
for y in Int(body.minY)..<Int(body.maxY) {
    let t = (CGFloat(y) - body.minY) / body.height
    ctx.setFillColor(color(0.06 + 0.10 * t, 0.11 + 0.17 * t, 0.22 + 0.30 * t))
    ctx.fill(CGRect(x: body.minX, y: CGFloat(y), width: body.width, height: 1))
}
ctx.restoreGState()

// Hairline edge, as on the rail.
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183.4, cornerHeight: 183.4, transform: nil))
ctx.setStrokeColor(color(1, 1, 1, 0.14))
ctx.setLineWidth(4)
ctx.strokePath()

// The rail: a lighter bar holding three gauges, as the side dock shows them.
let bar = CGRect(x: 512 - 150, y: 168, width: 300, height: 688)
ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 150, cornerHeight: 150, transform: nil))
ctx.setFillColor(color(1, 1, 1, 0.08))
ctx.fillPath()
let gauges: [(y: CGFloat, fill: CGFloat, tint: CGColor)] = [
    (722, 0.72, color(0.33, 0.82, 0.80)),
    (512, 0.45, color(0.96, 0.45, 0.70)),
    (302, 0.88, color(0.98, 0.72, 0.30)),
]
ctx.setLineWidth(40)
ctx.setLineCap(.round)
for gauge in gauges {
    let c = CGPoint(x: 512, y: gauge.y)
    ctx.addArc(center: c, radius: 78, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.setStrokeColor(color(1, 1, 1, 0.12))
    ctx.strokePath()
    let start = CGFloat.pi / 2
    ctx.addArc(center: c, radius: 78, startAngle: start, endAngle: start - 2 * .pi * gauge.fill, clockwise: true)
    ctx.setStrokeColor(gauge.tint)
    ctx.strokePath()
}

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
