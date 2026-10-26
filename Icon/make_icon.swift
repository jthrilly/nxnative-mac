// Renders nxnative Converter's app icon, a 1024 x 1024 PNG on the macOS icon grid (an 824 px square with continuous corners, 100 px margins, a soft drop shadow):
// a Mac window between two controller halves in red and blue, a game that plays on the Mac. scripts/build_app.py runs it and makes AppIcon.icns from the PNG.
// Usage: swift Icon/make_icon.swift <out.png>
import CoreGraphics
import Foundation
import ImageIO

let canvas: CGFloat = 1024

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func add(_ p: CGPoint, _ v: CGVector, _ s: CGFloat) -> CGPoint { CGPoint(x: p.x + v.dx * s, y: p.y + v.dy * s) }

// A rounded rectangle with continuous ("squircle") corners: each corner is a circular arc between two cubic easings (Figma's corner smoothing; 0.6 is close to Apple's shapes)
func squircle(_ r: CGRect, radius: CGFloat, smoothing: CGFloat = 0.6) -> CGPath {
    let budget = min(r.width, r.height) / 2
    let s = min(smoothing, max(0, budget / radius - 1)), p = min((1 + s) * radius, budget)
    let arcAngle = CGFloat.pi / 2 * (1 - s)
    let arcLength = sin(arcAngle / 2) * radius * 2.squareRoot()
    let alpha = (CGFloat.pi / 2 - arcAngle) / 2
    let c = radius * tan(alpha / 2) * cos(CGFloat.pi / 4 * s), d = c * tan(CGFloat.pi / 4 * s)
    let b = (p - arcLength - c - d) / 3, a = 2 * b
    let k = 4 / 3 * tan(arcAngle / 4) * radius   // the arc as one cubic
    // corner point, the direction of travel into it, the direction out of it
    let corners: [(CGPoint, CGVector, CGVector)] = [(CGPoint(x: r.maxX, y: r.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
                                                     (CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
                                                     (CGPoint(x: r.minX, y: r.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
                                                     (CGPoint(x: r.minX, y: r.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0))]
    let path = CGMutablePath()
    path.move(to: CGPoint(x: r.minX + p, y: r.minY))
    for (corner, u, v) in corners {
        let start = add(corner, u, -p)
        path.addLine(to: start)
        let e1 = add(add(start, u, a + b + c), v, d), e2 = add(add(e1, u, arcLength), v, arcLength)
        path.addCurve(to: e1, control1: add(start, u, a), control2: add(start, u, a + b))
        let center = add(add(corner, u, -radius), v, radius)
        // tangents along the direction of travel: the radius turned a quarter, towards the next edge
        func tangent(_ q: CGPoint) -> CGVector {
            let n = CGVector(dx: q.x - center.x, dy: q.y - center.y), l = (n.dx * n.dx + n.dy * n.dy).squareRoot()
            let t = CGVector(dx: -n.dy / l, dy: n.dx / l)
            return t.dx * (u.dx + v.dx) + t.dy * (u.dy + v.dy) >= 0 ? t : CGVector(dx: -t.dx, dy: -t.dy)
        }
        path.addCurve(to: e2, control1: add(e1, tangent(e1), k), control2: add(e2, tangent(e2), -k))
        path.addCurve(to: add(add(e2, u, d), v, a + b + c), control1: add(add(e2, u, d), v, c), control2: add(add(e2, u, d), v, b + c))
    }
    path.closeSubpath()
    return path
}

// A rectangle with its own radius at each corner (top left, top right, bottom right, bottom left, in a y-down space)
func rounded(_ r: CGRect, _ tl: CGFloat, _ tr: CGFloat, _ br: CGFloat, _ bl: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: r.minX + tl, y: r.minY))
    path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: tr)
    path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: br)
    path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: bl)
    path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: tl)
    path.closeSubpath()
    return path
}

func star(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {   // five points, softened corners
    let path = CGMutablePath()
    for i in 0..<10 {
        let a = -CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi / 5, l = i % 2 == 0 ? r : r * 0.48
        let q = CGPoint(x: x + cos(a) * l, y: y + sin(a) * l)
        if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
    }
    path.closeSubpath()
    return path.copy(strokingWithWidth: r * 0.16, lineCap: .round, lineJoin: .round, miterLimit: 1).union(path)
}

func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil) }

let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

func fill(_ ctx: CGContext, _ path: CGPath, top: CGColor, bottom: CGColor) {   // a vertical gradient over the path's bounds
    guard let g = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) else { return }
    let box = path.boundingBox
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(g, start: CGPoint(x: box.midX, y: box.minY), end: CGPoint(x: box.midX, y: box.maxY), options: [])
    ctx.restoreGState()
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) { ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath() }

// One controller half: the rounded outer side away from the window, a stick and four buttons
func half(_ ctx: CGContext, _ r: CGRect, left: Bool, top: UInt32, bottom: UInt32) {
    let outer = r.width * 0.92, inner: CGFloat = 16
    let shape = left ? rounded(r, outer, inner, inner, outer) : rounded(r, inner, outer, outer, inner)
    fill(ctx, shape, top: rgb(top), bottom: rgb(bottom))
    let x = r.midX + (left ? 4 : -4), stickY = r.minY + (left ? 0.3 : 0.62) * r.height, buttonsY = r.minY + (left ? 0.62 : 0.3) * r.height
    fill(ctx, circle(x, stickY, 37), rgb(0x1E2128, 0.9))
    fill(ctx, circle(x, stickY, 27), rgb(0x3A3F49))
    for (dx, dy) in [(0, -1), (1, 0), (0, 1), (-1, 0)] as [(CGFloat, CGFloat)] { fill(ctx, circle(x + dx * 29, buttonsY + dy * 29, 12.5), rgb(0x1E2128, 0.9)) }
}

func window(_ ctx: CGContext, _ r: CGRect) {
    let frame = squircle(r, radius: 34)
    fill(ctx, frame, rgb(0xF4F5F7))
    ctx.saveGState(); ctx.addPath(frame); ctx.clip()
    let bar: CGFloat = 54
    fill(ctx, CGPath(rect: CGRect(x: r.minX, y: r.minY, width: r.width, height: bar), transform: nil), top: rgb(0xF7F7F9), bottom: rgb(0xE3E4E8))
    for (i, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() { fill(ctx, circle(r.minX + 34 + CGFloat(i) * 32, r.minY + bar / 2, 10.5), rgb(UInt32(color))) }
    // the screen: sky, a star, blocks and two hills
    let screen = CGRect(x: r.minX, y: r.minY + bar, width: r.width, height: r.height - bar)
    fill(ctx, CGPath(rect: screen, transform: nil), top: rgb(0x58B8FF), bottom: rgb(0xBFE7FF))
    fill(ctx, star(screen.maxX - 96, screen.minY + 78, 44), top: rgb(0xFFE16A), bottom: rgb(0xFFB321))
    for i in 0..<3 {   // floating blocks, each with a darker bottom edge
        let block = CGRect(x: screen.minX + 92 + CGFloat(i) * 52, y: screen.minY + 92, width: 48, height: 48)
        fill(ctx, squircle(block, radius: 10), rgb(0xC85A17))
        fill(ctx, squircle(CGRect(x: block.minX, y: block.minY, width: block.width, height: block.height - 7), radius: 10), top: rgb(0xFFB25E), bottom: rgb(0xF2802C))
    }
    let back = CGMutablePath()
    back.move(to: CGPoint(x: screen.minX, y: screen.maxY - 92))
    back.addCurve(to: CGPoint(x: screen.maxX, y: screen.maxY - 128), control1: CGPoint(x: screen.minX + 150, y: screen.maxY - 210), control2: CGPoint(x: screen.maxX - 170, y: screen.maxY - 40))
    back.addLine(to: CGPoint(x: screen.maxX, y: screen.maxY)); back.addLine(to: CGPoint(x: screen.minX, y: screen.maxY)); back.closeSubpath()
    fill(ctx, back, top: rgb(0x6FD47A), bottom: rgb(0x3FAF55))
    let front = CGMutablePath()
    front.move(to: CGPoint(x: screen.minX, y: screen.maxY - 30))
    front.addCurve(to: CGPoint(x: screen.maxX, y: screen.maxY - 52), control1: CGPoint(x: screen.minX + 190, y: screen.maxY - 130), control2: CGPoint(x: screen.maxX - 120, y: screen.maxY - 120))
    front.addLine(to: CGPoint(x: screen.maxX, y: screen.maxY)); front.addLine(to: CGPoint(x: screen.minX, y: screen.maxY)); front.closeSubpath()
    fill(ctx, front, top: rgb(0x3DB85A), bottom: rgb(0x23913F))
    ctx.restoreGState()
    ctx.addPath(frame); ctx.setStrokeColor(rgb(0x000000, 0.18)); ctx.setLineWidth(2); ctx.strokePath()
}

func render() -> CGImage? {
    guard let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.translateBy(x: 0, y: canvas); ctx.scaleBy(x: 1, y: -1)   // y down, as in a drawing program; shadow offsets stay in the bitmap's y-up space
    let body = squircle(CGRect(x: 100, y: 100, width: 824, height: 824), radius: 185.4)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    fill(ctx, body, rgb(0x2E2C7A))
    ctx.restoreGState()
    fill(ctx, body, top: rgb(0x5D5ED8), bottom: rgb(0x252163))
    ctx.saveGState(); ctx.addPath(body); ctx.clip()
    if let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1]) {
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 150), startRadius: 0, endCenter: CGPoint(x: 512, y: 150), endRadius: 560, options: [])
    }
    ctx.restoreGState()
    let height: CGFloat = 364, halfWidth: CGFloat = 122, gap: CGFloat = 12, windowWidth: CGFloat = 444
    let x0 = (canvas - (2 * halfWidth + 2 * gap + windowWidth)) / 2, y0 = (canvas - height) / 2 + 8
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: rgb(0x000000, 0.45))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    half(ctx, CGRect(x: x0, y: y0, width: halfWidth, height: height), left: true, top: 0xFF5D4B, bottom: 0xE5301F)
    window(ctx, CGRect(x: x0 + halfWidth + gap, y: y0, width: windowWidth, height: height))
    half(ctx, CGRect(x: x0 + halfWidth + 2 * gap + windowWidth, y: y0, width: halfWidth, height: height), left: false, top: 0x34CBF2, bottom: 0x0796C8)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    return ctx.makeImage()
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make_icon.swift <out.png>\n".utf8)); exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = render(), let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("make_icon: cannot render \(out.path)\n".utf8)); exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { FileHandle.standardError.write(Data("make_icon: cannot write \(out.path)\n".utf8)); exit(1) }
