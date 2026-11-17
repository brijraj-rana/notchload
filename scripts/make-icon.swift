// Renders Resources/AppIcon.icns: a notch hanging from the top of a graphite tile, with a load trace below it.
// Usage: swift scripts/make-icon.swift [repo root]
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        let s = size / 1024
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: srgb, components: [r, g, b, a])!
        }
        let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 186 * s, cornerHeight: 186 * s, transform: nil)

        // Drop shadow + graphite body.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: color(0, 0, 0, 0.35))
        ctx.addPath(tilePath); ctx.setFillColor(color(0.1, 0.1, 0.11)); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tilePath); ctx.clip()
        let body = CGGradient(colorsSpace: srgb, colors: [color(0.21, 0.21, 0.23), color(0.08, 0.08, 0.09)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(body, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

        // The trace: one line of CPU history with a spike, filled underneath.
        let points: [(CGFloat, CGFloat)] = [
            (100, 330), (220, 350), (300, 318), (372, 372), (440, 352), (506, 452),
            (566, 600), (626, 470), (690, 506), (760, 412), (840, 436), (924, 400),
        ]
        let line = CGMutablePath()
        for (i, p) in points.enumerated() {
            let pt = CGPoint(x: p.0 * s, y: p.1 * s)
            if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
        }
        let area = line.mutableCopy()!
        area.addLine(to: CGPoint(x: 924 * s, y: 100 * s))
        area.addLine(to: CGPoint(x: 100 * s, y: 100 * s))
        area.closeSubpath()
        ctx.saveGState()
        ctx.addPath(area); ctx.clip()
        let fill = CGGradient(colorsSpace: srgb, colors: [color(0.27, 0.87, 0.55, 0.34), color(0.27, 0.87, 0.55, 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: 600 * s), end: CGPoint(x: 0, y: 120 * s), options: [])
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 28 * s, color: color(0.25, 0.9, 0.55, 0.6))
        ctx.addPath(line)
        ctx.setStrokeColor(color(0.36, 0.92, 0.62)); ctx.setLineWidth(26 * s)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()

        // The notch: pure black, hanging from the top edge.
        let notch = CGMutablePath()
        let left = 332 * s, right = 692 * s, top = tile.maxY, bottom = 762 * s, r = 46 * s
        notch.move(to: CGPoint(x: left, y: top))
        notch.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: right, y: bottom), radius: r)
        notch.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right, y: top), radius: r)
        notch.addLine(to: CGPoint(x: right, y: top))
        notch.closeSubpath()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 22 * s, color: color(0, 0, 0, 0.5))
        ctx.addPath(notch); ctx.setFillColor(color(0, 0, 0)); ctx.fillPath()
        ctx.restoreGState()

        // Hairline edge highlight.
        ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5 * s, dy: 1.5 * s), cornerWidth: 184 * s, cornerHeight: 184 * s, transform: nil))
        ctx.setStrokeColor(color(1, 1, 1, 0.10)); ctx.setLineWidth(3 * s); ctx.strokePath()
        return true
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawIcon(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run(); task.waitUntilExit()
let docs = root.appendingPathComponent("docs")
try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: docs.appendingPathComponent("icon.png"))
try FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_256x256@2x.png"), to: docs.appendingPathComponent("icon.png"))
print("Wrote \(output.path)")
