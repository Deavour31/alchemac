import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = base * scale
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let factor = CGFloat(size) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(srgbRed: 0.06, green: 0.17, blue: 0.19, alpha: 1),
                   ending: NSColor(srgbRed: 0.03, green: 0.09, blue: 0.12, alpha: 1))!.draw(in: background, angle: -70)
        let leaf = NSBezierPath()
        leaf.move(to: NSPoint(x: 285, y: 245))
        leaf.curve(to: NSPoint(x: 755, y: 790), controlPoint1: NSPoint(x: 190, y: 655), controlPoint2: NSPoint(x: 510, y: 800))
        leaf.curve(to: NSPoint(x: 285, y: 245), controlPoint1: NSPoint(x: 825, y: 410), controlPoint2: NSPoint(x: 660, y: 205))
        NSColor(srgbRed: 0.39, green: 0.89, blue: 0.72, alpha: 1).setFill(); leaf.fill()
        let vein = NSBezierPath()
        vein.move(to: NSPoint(x: 260, y: 220)); vein.line(to: NSPoint(x: 651, y: 672))
        vein.lineWidth = 29; vein.lineCapStyle = .round
        NSColor(srgbRed: 0.07, green: 0.25, blue: 0.24, alpha: 1).setStroke(); vein.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
