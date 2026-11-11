// Draws the DMG window background. Run: swift dmg/background.swift  (writes dmg/background.tiff, 1x + 2x)
// Icon centers (must match dmg/settings.py): app (150,180), Applications (450,180); window 600x420.
import AppKit

let W = 600.0, H = 420.0
let navyTop = NSColor(srgbRed: 0.13, green: 0.20, blue: 0.29, alpha: 1)
let navyEdge = NSColor(srgbRed: 0.04, green: 0.06, blue: 0.10, alpha: 1)
let accent = NSColor(srgbRed: 0.37, green: 0.71, blue: 1.0, alpha: 1)

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, at p: CGPoint, center: Bool = true, width: CGFloat = 0) {
    let style = NSMutableParagraphStyle()
    style.alignment = center ? .center : .left
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color, .paragraphStyle: style]
    let str = NSAttributedString(string: s, attributes: attrs)
    let w = width > 0 ? width : W
    let h = str.boundingRect(with: CGSize(width: w, height: 200), options: .usesLineFragmentOrigin).height
    str.draw(with: CGRect(x: center ? p.x - w / 2 : p.x, y: p.y, width: w, height: h), options: .usesLineFragmentOrigin)
}

func draw() {
    // Flipped coordinates: y grows downward, like Finder's icon positions.
    NSGradient(colors: [navyTop, NSColor(srgbRed: 0.08, green: 0.11, blue: 0.16, alpha: 1), navyEdge])!
        .draw(in: NSBezierPath(rect: CGRect(x: 0, y: 0, width: W, height: H)), relativeCenterPosition: NSPoint(x: 0, y: 0.2))

    NSColor(srgbRed: 0.55, green: 0.75, blue: 1, alpha: 0.09).setFill()
    for x in stride(from: 9.0, to: W, by: 18) { for y in stride(from: 9.0, to: H, by: 18) {
        NSBezierPath(ovalIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)).fill()
    } }

    text("Mount Point", 22, .semibold, NSColor(srgbRed: 0.91, green: 0.95, blue: 1, alpha: 1), at: CGPoint(x: W / 2, y: 24))
    text("Your network shares, mounted automatically", 13, .regular,
         NSColor(srgbRed: 0.56, green: 0.64, blue: 0.76, alpha: 1), at: CGPoint(x: W / 2, y: 56))

    // Light plates keep Finder's dark icon labels readable.
    for cx in [150.0, 450.0] {
        let plate = NSBezierPath(roundedRect: CGRect(x: cx - 76, y: 104, width: 152, height: 170), xRadius: 22, yRadius: 22)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 24; shadow.shadowOffset = .init(width: 0, height: -8)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4); shadow.set()
        NSColor.white.withAlphaComponent(0.9).setFill(); plate.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Chevrons between the plates, fading in toward Applications.
    for (i, x) in [272.0, 300.0, 328.0].enumerated() {
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow(); glow.shadowBlurRadius = 10; glow.shadowColor = accent; glow.set()
        let p = NSBezierPath(); p.lineWidth = 3.5; p.lineCapStyle = .round; p.lineJoinStyle = .round
        p.move(to: CGPoint(x: x - 5, y: 180 - 9)); p.line(to: CGPoint(x: x + 5, y: 180)); p.line(to: CGPoint(x: x - 5, y: 180 + 9))
        accent.withAlphaComponent([0.35, 0.65, 1][i]).setStroke(); p.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Steps strip.
    NSColor.white.withAlphaComponent(0.05).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: H - 96, width: W, height: 96)).fill()
    NSColor.white.withAlphaComponent(0.10).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: H - 96, width: W, height: 1)).fill()
    NSBezierPath(rect: CGRect(x: W / 2, y: H - 78, width: 1, height: 60)).fill()
    let steps = [("1", "Drag to Applications", "Drop Mount Point onto the folder."),
                 ("2", "First launch", "System Settings → Privacy & Security → Open Anyway.")]
    for (i, (n, title, body)) in steps.enumerated() {
        let x = 26.0 + Double(i) * W / 2, y = H - 74
        accent.setFill(); NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 22, height: 22)).fill()
        text(n, 12, .bold, NSColor(srgbRed: 0.04, green: 0.06, blue: 0.10, alpha: 1), at: CGPoint(x: x + 11, y: y + 3.5))
        text(title, 13, .semibold, NSColor(srgbRed: 0.91, green: 0.95, blue: 1, alpha: 1), at: CGPoint(x: x + 34, y: y + 1), center: false, width: 230)
        text(body, 12, .regular, NSColor(srgbRed: 0.62, green: 0.70, blue: 0.82, alpha: 1), at: CGPoint(x: x + 34, y: y + 20), center: false, width: 230)
    }
}

func render(scale: Double) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)   // flip so y matches Finder
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let tiff = NSBitmapImageRep.tiffRepresentationOfImageReps(in: [render(scale: 1), render(scale: 2)], using: .lzw, factor: 0)!
try! tiff.write(to: dir.appendingPathComponent("background.tiff"))
print("Wrote dmg/background.tiff")
