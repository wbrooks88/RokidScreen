// Icon concepts for Rokid Screen, drawn as full-bleed 1024 squares (macOS
// rounds them), plus a preview sheet with them masked the way macOS shows them.
import AppKit
import CoreGraphics

let S: CGFloat = 1024
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}

func canvas(_ draw: (CGContext) -> Void) -> CGImage {
    let c = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                      space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left origin, like a design tool
    c.translateBy(x: 0, y: S)
    c.scaleBy(x: 1, y: -1)
    draw(c)
    return c.makeImage()!
}

func linear(_ c: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: nil)!
    c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ c: CGContext, _ colors: [CGColor], at: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: nil)!
    c.drawRadialGradient(g, startCenter: at, startRadius: 0, endCenter: at, endRadius: radius, options: [])
}

// A curved screen: the top and bottom edges bow the same way, like a wrap-around monitor
func curvedScreen(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, bow: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x, y: y))
    p.addQuadCurve(to: CGPoint(x: x + w, y: y), control: CGPoint(x: x + w / 2, y: y + bow))
    p.addLine(to: CGPoint(x: x + w, y: y + h))
    p.addQuadCurve(to: CGPoint(x: x, y: y + h), control: CGPoint(x: x + w / 2, y: y + h + bow))
    p.closeSubpath()
    return p
}

// Glasses seen from the front: two rounded lenses joined by a bridge
func glasses(cx: CGFloat, cy: CGFloat, lensW: CGFloat, lensH: CGFloat, gap: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let r = lensH * 0.42
    p.addRoundedRect(in: CGRect(x: cx - gap / 2 - lensW, y: cy - lensH / 2, width: lensW, height: lensH),
                     cornerWidth: r, cornerHeight: r)
    p.addRoundedRect(in: CGRect(x: cx + gap / 2, y: cy - lensH / 2, width: lensW, height: lensH),
                     cornerWidth: r, cornerHeight: r)
    return p
}

func bridge(_ c: CGContext, cx: CGFloat, cy: CGFloat, gap: CGFloat, lensH: CGFloat, width: CGFloat) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx - gap / 2 - 4, y: cy - lensH * 0.22))
    p.addQuadCurve(to: CGPoint(x: cx + gap / 2 + 4, y: cy - lensH * 0.22),
                   control: CGPoint(x: cx, y: cy - lensH * 0.42))
    c.addPath(p)
    c.setLineWidth(width)
    c.setLineCap(.round)
    c.strokePath()
}

// Small desktop inside a screen: menu bar, two windows, a dock
func miniDesktop(_ c: CGContext, in r: CGRect, path: CGPath) {
    c.saveGState()
    c.addPath(path)
    c.clip()
    linear(c, [color(0x7F5AF0), color(0x2CB1F5)], from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.maxX, y: r.maxY))
    c.setFillColor(color(0xFFFFFF, 0.35))
    c.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.07))
    c.setFillColor(color(0xFFFFFF, 0.92))
    c.addPath(CGPath(roundedRect: CGRect(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.2,
                                         width: r.width * 0.42, height: r.height * 0.45),
                     cornerWidth: 14, cornerHeight: 14, transform: nil))
    c.fillPath()
    c.setFillColor(color(0xFFFFFF, 0.75))
    c.addPath(CGPath(roundedRect: CGRect(x: r.minX + r.width * 0.46, y: r.minY + r.height * 0.32,
                                         width: r.width * 0.40, height: r.height * 0.42),
                     cornerWidth: 14, cornerHeight: 14, transform: nil))
    c.fillPath()
    c.setFillColor(color(0xFFFFFF, 0.45))
    c.addPath(CGPath(roundedRect: CGRect(x: r.minX + r.width * 0.3, y: r.maxY - r.height * 0.15,
                                         width: r.width * 0.4, height: r.height * 0.07),
                     cornerWidth: 10, cornerHeight: 10, transform: nil))
    c.fillPath()
    c.restoreGState()
}

// 1. Wrap: a glowing curved screen floating above simple glasses, on deep navy
let wrap = canvas { c in
    linear(c, [color(0x1B1F3B), color(0x0B0D1A)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: S))
    radial(c, [color(0x5B6CFF, 0.45), color(0x5B6CFF, 0)], at: CGPoint(x: 512, y: 380), radius: 460)
    let screen = curvedScreen(x: 172, y: 210, w: 680, h: 330, bow: 70)
    c.saveGState()
    c.setShadow(offset: .zero, blur: 60, color: color(0x6C8CFF, 0.9))
    c.addPath(screen); c.setFillColor(color(0x6C8CFF)); c.fillPath()
    c.restoreGState()
    miniDesktop(c, in: CGRect(x: 172, y: 210, width: 680, height: 400), path: screen)
    c.setFillColor(color(0xE9ECF5))
    let g = glasses(cx: 512, cy: 760, lensW: 230, lensH: 130, gap: 70)
    c.addPath(g); c.fillPath()
    c.setFillColor(color(0x2A2F4A))
    c.addPath(glasses(cx: 512, cy: 760, lensW: 200, lensH: 104, gap: 100)); c.fillPath()
    c.setStrokeColor(color(0xE9ECF5))
    bridge(c, cx: 512, cy: 760, gap: 70, lensH: 130, width: 22)
}

// 2. Lens: one big pair of glasses with the desktop showing in the lenses, on a bright gradient
let lens = canvas { c in
    linear(c, [color(0x36D1DC), color(0x5B86E5)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: S, y: S))
    let frame = glasses(cx: 512, cy: 540, lensW: 380, lensH: 300, gap: 60)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 24), blur: 50, color: color(0x10224A, 0.45))
    c.setFillColor(color(0x15182A)); c.addPath(frame); c.fillPath()
    c.restoreGState()
    let inner = glasses(cx: 512, cy: 540, lensW: 340, lensH: 262, gap: 100)
    miniDesktop(c, in: CGRect(x: 72, y: 409, width: 880, height: 262), path: inner)
    // glass sheen
    c.saveGState(); c.addPath(inner); c.clip()
    linear(c, [color(0xFFFFFF, 0.35), color(0xFFFFFF, 0)], from: CGPoint(x: 0, y: 400), to: CGPoint(x: 0, y: 560))
    c.restoreGState()
    c.setStrokeColor(color(0x15182A))
    bridge(c, cx: 512, cy: 540, gap: 60, lensH: 300, width: 34)
}

// 2b. Lens on black (Will's pick): the frame turns light graphite so it shows on black
let lensBlack = canvas { c in
    linear(c, [color(0x1C1C1E), color(0x000000)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: S))
    radial(c, [color(0x3B5BDB, 0.30), color(0x3B5BDB, 0)], at: CGPoint(x: 512, y: 540), radius: 520)
    let frame = glasses(cx: 512, cy: 540, lensW: 380, lensH: 300, gap: 60)
    c.saveGState()
    c.addPath(frame); c.clip()
    linear(c, [color(0x8A8F9C), color(0x3C404A)], from: CGPoint(x: 0, y: 390), to: CGPoint(x: 0, y: 690))
    c.restoreGState()
    let inner = glasses(cx: 512, cy: 540, lensW: 340, lensH: 262, gap: 100)
    miniDesktop(c, in: CGRect(x: 72, y: 409, width: 880, height: 262), path: inner)
    c.saveGState(); c.addPath(inner); c.clip()
    linear(c, [color(0xFFFFFF, 0.35), color(0xFFFFFF, 0)], from: CGPoint(x: 0, y: 400), to: CGPoint(x: 0, y: 560))
    c.restoreGState()
    let br = CGMutablePath()
    br.move(to: CGPoint(x: 512 - 34, y: 540 - 300 * 0.22))
    br.addQuadCurve(to: CGPoint(x: 512 + 34, y: 540 - 300 * 0.22), control: CGPoint(x: 512, y: 540 - 300 * 0.42))
    c.addPath(br); c.setLineWidth(34); c.setLineCap(.round)
    c.setStrokeColor(color(0x7A7F8C)); c.strokePath()
}

// 3. Orbit: a single tilted screen with a head-tracking orbit ring, violet
let orbit = canvas { c in
    linear(c, [color(0x3A1C71), color(0xD76D77)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: S, y: S))
    // orbit ring behind
    c.saveGState()
    c.translateBy(x: 512, y: 530); c.rotate(by: -0.28)
    c.setStrokeColor(color(0xFFFFFF, 0.55)); c.setLineWidth(18)
    c.strokeEllipse(in: CGRect(x: -400, y: -150, width: 800, height: 300))
    c.restoreGState()
    let screen = curvedScreen(x: 232, y: 330, w: 560, h: 330, bow: 50)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 30), blur: 50, color: color(0x1A0B2E, 0.6))
    c.addPath(screen); c.setFillColor(color(0xFFFFFF)); c.fillPath()
    c.restoreGState()
    miniDesktop(c, in: CGRect(x: 232, y: 330, width: 560, height: 380), path: screen)
    // front half of the ring passes in front of the screen
    c.saveGState()
    c.translateBy(x: 512, y: 530); c.rotate(by: -0.28)
    c.clip(to: CGRect(x: -500, y: 0, width: 1000, height: 300))
    c.setStrokeColor(color(0xFFFFFF)); c.setLineWidth(18)
    c.strokeEllipse(in: CGRect(x: -400, y: -150, width: 800, height: 300))
    c.setFillColor(color(0xFFFFFF))
    c.fillEllipse(in: CGRect(x: 250, y: 60, width: 56, height: 56))
    c.restoreGState()
}

// 4. Glyph: minimal, white background, black glasses with a blue curved screen line above
let glyph = canvas { c in
    linear(c, [color(0xFFFFFF), color(0xE8ECF3)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: S))
    let arc = CGMutablePath()
    arc.move(to: CGPoint(x: 210, y: 360))
    arc.addQuadCurve(to: CGPoint(x: 814, y: 360), control: CGPoint(x: 512, y: 250))
    c.addPath(arc)
    c.setStrokeColor(color(0x0A84FF)); c.setLineWidth(56); c.setLineCap(.round); c.strokePath()
    let arc2 = CGMutablePath()
    arc2.move(to: CGPoint(x: 300, y: 450))
    arc2.addQuadCurve(to: CGPoint(x: 724, y: 450), control: CGPoint(x: 512, y: 380))
    c.addPath(arc2)
    c.setStrokeColor(color(0x0A84FF, 0.45)); c.setLineWidth(36); c.strokePath()
    c.setFillColor(color(0x1C1C1E))
    c.addPath(glasses(cx: 512, cy: 660, lensW: 270, lensH: 180, gap: 70)); c.fillPath()
    c.setFillColor(color(0x3A3A3C))
    c.addPath(glasses(cx: 512, cy: 660, lensW: 236, lensH: 148, gap: 104)); c.fillPath()
    c.setStrokeColor(color(0x1C1C1E))
    bridge(c, cx: 512, cy: 660, gap: 70, lensH: 180, width: 30)
}

let out = CommandLine.arguments[1]
let named = CommandLine.arguments.count > 2
    ? [("2b-lens-black", lensBlack)]
    : [("1-wrap", wrap), ("2-lens", lens), ("3-orbit", orbit), ("4-glyph", glyph)]
for (name, img) in named {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}

// Preview sheet: each masked to the macOS icon shape, large and small, on light and dark
let cell: CGFloat = 300, pad: CGFloat = 40
let W = Int(pad + CGFloat(named.count) * (cell + pad)), H = 760
let sheet = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sheet.setFillColor(color(0xF2F2F7)); sheet.fill(CGRect(x: 0, y: 380, width: W, height: 380))
sheet.setFillColor(color(0x1C1C1E)); sheet.fill(CGRect(x: 0, y: 0, width: W, height: 380))
for (i, (_, img)) in named.enumerated() {
    let x = pad + CGFloat(i) * (cell + pad)
    for (y, size) in [(CGFloat(420), cell), (CGFloat(60), cell)] {
        let r = CGRect(x: x, y: y, width: size, height: size)
        sheet.saveGState()
        sheet.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x000000, 0.35))
        sheet.addPath(CGPath(roundedRect: r, cornerWidth: size * 0.225, cornerHeight: size * 0.225, transform: nil))
        sheet.setFillColor(color(0x000000)); sheet.fillPath()
        sheet.restoreGState()
        sheet.saveGState()
        sheet.addPath(CGPath(roundedRect: r, cornerWidth: size * 0.225, cornerHeight: size * 0.225, transform: nil))
        sheet.clip(); sheet.draw(img, in: r)
        sheet.restoreGState()
    }
    // Finder-list size
    let small = CGRect(x: x + cell / 2 - 16, y: 12, width: 32, height: 32)
    sheet.saveGState()
    sheet.addPath(CGPath(roundedRect: small, cornerWidth: 7, cornerHeight: 7, transform: nil))
    sheet.clip(); sheet.draw(img, in: small)
    sheet.restoreGState()
}
let rep = NSBitmapImageRep(cgImage: sheet.makeImage()!)
let sheetName = named.count == 1 ? "\(named[0].0)-preview.png" : "concepts-sheet.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(sheetName)"))
