import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

enum Variant { case standard, dark, tinted }

func cloudPath(dy: CGFloat = 0) -> CGPath {
    let p = CGMutablePath()
    p.addRoundedRect(in: CGRect(x: 196, y: 370 + dy, width: 632, height: 210), cornerWidth: 105, cornerHeight: 105)
    p.addEllipse(in: CGRect(x: 262, y: 430 + dy, width: 270, height: 270))
    p.addEllipse(in: CGRect(x: 420, y: 450 + dy, width: 340, height: 340))
    return p
}

func render(_ v: Variant, to url: URL) {
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let full = CGRect(x: 0, y: 0, width: size, height: size)

    // Background: the board's warm charcoal with a faint dot grid.
    if v == .tinted {
        ctx.setFillColor(color(0x000000)); ctx.fill(full)
    } else {
        let g = CGGradient(colorsSpace: nil, colors: [color(v == .dark ? 0x262421 : 0x3c3a37), color(v == .dark ? 0x161513 : 0x262421)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 0, y: 0), options: [])
        ctx.setFillColor(color(0xffffff, 0.07))
        for x in stride(from: 64, to: 1024, by: 64) { for y in stride(from: 64, to: 1024, by: 64) {
            ctx.fillEllipse(in: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
        } }
    }

    // Chunky cloud: darker bottom edge offset below, like the app's buttons.
    let main = v == .tinted ? color(0xffffff) : color(0x81b64c)
    let shadow = v == .tinted ? color(0x9a9a9a) : color(0x45753c)
    ctx.addPath(cloudPath(dy: -34)); ctx.setFillColor(shadow); ctx.fillPath()
    ctx.addPath(cloudPath()); ctx.setFillColor(main); ctx.fillPath()

    // Architecture inside: three services wired together.
    let ink = v == .tinted ? color(0x3a3a3a) : color(0xffffff)
    let a = CGPoint(x: 352, y: 488), b = CGPoint(x: 590, y: 630), c = CGPoint(x: 672, y: 470)
    ctx.setStrokeColor(ink); ctx.setLineWidth(26); ctx.setLineCap(.round)
    ctx.move(to: a); ctx.addLine(to: b); ctx.move(to: b); ctx.addLine(to: c); ctx.move(to: a); ctx.addLine(to: c)
    ctx.strokePath()
    for (p, r) in [(a, 62.0), (b, 72.0), (c, 58.0)] {
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r * 0.45, cornerHeight: r * 0.45, transform: nil))
        ctx.setFillColor(ink); ctx.fillPath()
    }
    // Service colours on the nodes (compute, CDN, database) — the app's category palette.
    if v != .tinted {
        for (p, r, hex) in [(a, 34.0, UInt32(0xed7100)), (b, 40.0, 0x8c4fff), (c, 32.0, 0xc925d1)] {
            ctx.setFillColor(color(hex))
            ctx.addPath(CGPath(roundedRect: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2), cornerWidth: r * 0.4, cornerHeight: r * 0.4, transform: nil))
            ctx.fillPath()
        }
    }

    // Traffic bars rising under the cloud: the load it has to survive.
    let bars: [(CGFloat, CGFloat)] = [(330, 60), (421, 100), (512, 170), (603, 120), (694, 80)]
    for (i, (x, h)) in bars.enumerated() {
        let hex: UInt32 = i == 2 ? 0xffaa00 : 0xa3d160
        ctx.setFillColor(v == .tinted ? color(0xffffff, i == 2 ? 1 : 0.6) : color(hex))
        ctx.addPath(CGPath(roundedRect: CGRect(x: x - 30, y: 130, width: 60, height: h), cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()
    }

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
render(.standard, to: out.appendingPathComponent("AppIcon.png"))
render(.dark, to: out.appendingPathComponent("AppIcon-Dark.png"))
render(.tinted, to: out.appendingPathComponent("AppIcon-Tinted.png"))
