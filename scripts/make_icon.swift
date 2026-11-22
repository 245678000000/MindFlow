import AppKit
import CoreGraphics

// MindFlow app icon: deep indigo glass squircle, glowing core, tapered flowing branches.

let S = 1024
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((h >> 16) & 255) / 255, CGFloat((h >> 8) & 255) / 255, CGFloat(h & 255) / 255, a])!
}
func gradient(_ colors: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}

// Apple-like continuous squircle
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let n: CGFloat = 4.2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        let pt = CGPoint(x: r.midX + x * r.width / 2, y: r.midY + y * r.height / 2)
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40, color: rgb(0x0B0820, 0.45))
ctx.addPath(shape); ctx.setFillColor(rgb(0x2A2474)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()

// Background: indigo → deep night
ctx.drawLinearGradient(gradient([rgb(0x5A55F0), rgb(0x3B2FB8), rgb(0x1C1554)], [0, 0.45, 1]),
                       start: CGPoint(x: 180, y: 924), end: CGPoint(x: 844, y: 100), options: [])
// Soft central bloom
ctx.drawRadialGradient(gradient([rgb(0x9C8CFF, 0.55), rgb(0x7A6BFF, 0.18), rgb(0x7A6BFF, 0)], [0, 0.45, 1]),
                       startCenter: CGPoint(x: 512, y: 520), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 520), endRadius: 470, options: [])

let c = CGPoint(x: 512, y: 512)

struct Branch { let end: CGPoint; let color: UInt32; let bend: CGFloat }
let branches: [Branch] = [
    Branch(end: CGPoint(x: 786, y: 712), color: 0xFFC567, bend: 1),
    Branch(end: CGPoint(x: 822, y: 520), color: 0x52E5C2, bend: 1),
    Branch(end: CGPoint(x: 778, y: 322), color: 0x5BC6FF, bend: 1),
    Branch(end: CGPoint(x: 236, y: 646), color: 0xFF7E9D, bend: 1),
    Branch(end: CGPoint(x: 246, y: 368), color: 0xC6A0FF, bend: 1),
]

func taper(from s: CGPoint, to e: CGPoint, w0: CGFloat, w1: CGFloat) -> CGPath {
    let mx = (e.x - s.x) * 0.58
    let p = CGMutablePath()
    p.move(to: CGPoint(x: s.x, y: s.y + w0 / 2))
    p.addCurve(to: CGPoint(x: e.x, y: e.y + w1 / 2),
               control1: CGPoint(x: s.x + mx, y: s.y + w0 / 2),
               control2: CGPoint(x: e.x - mx, y: e.y + w1 / 2))
    p.addLine(to: CGPoint(x: e.x, y: e.y - w1 / 2))
    p.addCurve(to: CGPoint(x: s.x, y: s.y - w0 / 2),
               control1: CGPoint(x: e.x - mx, y: e.y - w1 / 2),
               control2: CGPoint(x: s.x + mx, y: s.y - w0 / 2))
    p.closeSubpath()
    return p
}

// Branch glow pass
for b in branches {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 34, color: rgb(b.color, 0.75))
    ctx.addPath(taper(from: c, to: b.end, w0: 50, w1: 16))
    ctx.setFillColor(rgb(b.color, 0.55))
    ctx.fillPath()
    ctx.restoreGState()
}
// Branch body: gradient from pale core tint to branch color
for b in branches {
    ctx.saveGState()
    ctx.addPath(taper(from: c, to: b.end, w0: 50, w1: 16))
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xF3EEFF), rgb(b.color)], [0.15, 0.85]),
                           start: c, end: b.end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// End nodes
for b in branches {
    let r: CGFloat = 31
    let rect = CGRect(x: b.end.x - r, y: b.end.y - r, width: r * 2, height: r * 2)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: rgb(b.color, 0.95))
    ctx.setFillColor(rgb(b.color)); ctx.fillEllipse(in: rect)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: rect); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.75), rgb(b.color, 0), rgb(0x000000, 0.12)], [0, 0.55, 1]),
                           start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()
}

// Core orb
let R: CGFloat = 108
let core = CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 70, color: rgb(0xC9BEFF, 0.9))
ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillEllipse(in: core)
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: core); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF), rgb(0xEAE4FF), rgb(0xBDB0FF)], [0, 0.5, 1]),
                       start: CGPoint(x: c.x - R * 0.6, y: c.y + R), end: CGPoint(x: c.x + R * 0.6, y: c.y - R), options: [])
// inner four-point star (the AI mark)
func star(_ r: CGRect, k: CGFloat = 0.14) -> CGPath {
    let m = CGPoint(x: r.midX, y: r.midY)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: m.x, y: r.maxY))
    p.addQuadCurve(to: CGPoint(x: r.maxX, y: m.y), control: CGPoint(x: m.x + r.width * k, y: m.y + r.height * k))
    p.addQuadCurve(to: CGPoint(x: m.x, y: r.minY), control: CGPoint(x: m.x + r.width * k, y: m.y - r.height * k))
    p.addQuadCurve(to: CGPoint(x: r.minX, y: m.y), control: CGPoint(x: m.x - r.width * k, y: m.y - r.height * k))
    p.addQuadCurve(to: CGPoint(x: m.x, y: r.maxY), control: CGPoint(x: m.x - r.width * k, y: m.y + r.height * k))
    p.closeSubpath()
    return p
}
ctx.restoreGState()
ctx.saveGState()
let st = CGRect(x: c.x - 62, y: c.y - 62, width: 124, height: 124)
ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 10, color: rgb(0x4B32C8, 0.35))
ctx.addPath(star(st)); ctx.setFillColor(rgb(0x7A62F5)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(star(st)); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x7F8CFF), rgb(0x8E58F2)]),
                       start: CGPoint(x: st.minX, y: st.maxY), end: CGPoint(x: st.maxX, y: st.minY), options: [])
ctx.restoreGState()
let st2 = CGRect(x: c.x + 30, y: c.y + 30, width: 34, height: 34)
ctx.saveGState()
ctx.addPath(star(st2)); ctx.setFillColor(rgb(0x9A7BFF)); ctx.fillPath()
ctx.restoreGState()

// Top gloss
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
ctx.restoreGState()

// Hairline rim
ctx.saveGState()
ctx.addPath(shape)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.16)); ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
