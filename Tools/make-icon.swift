// Renders the ShortVid app icon: a film frame catching a down arrow, on a coral tile,
// in the same glass style as the other beardfm.app icons (see Captioner/Tools/make-icon.swift).
//
// Usage: swift Tools/make-icon.swift <output-dir>          icon_<size>.png for 16…1024 (rounded macOS tile with shadow)
//        swift Tools/make-icon.swift --site <output-file>  320×320 tile cropped to its bounds, for the website
import AppKit

let canvas: CGFloat = 1024
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// macOS-style continuous-corner tile (superellipse) inside the standard 824pt icon grid.
func tilePath() -> CGPath {
    let rect = tileRect
    let path = CGMutablePath()
    let n: CGFloat = 5
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / n), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / n), s)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func fill(_ path: CGPath, in context: CGContext, gradient colors: [CGColor], locations: [CGFloat], from start: CGPoint, to end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip(using: .winding)
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

// The glyph was designed on a 160-unit, y-down grid; map it onto the tile.
let unit = tileRect.width / 160
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: tileRect.minX + x * unit, y: tileRect.maxY - y * unit)
}
func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: tileRect.minX + x * unit, y: tileRect.maxY - (y + h) * unit, width: w * unit, height: h * unit)
}

/// Film frame (stroked), its two sprocket strips (translucent), and the arrow (shaft + head).
struct Glyph {
    let frame: CGPath          // stroke
    let strips: [CGPath]       // fill, translucent
    let shaft: CGPath          // fill
    let head: CGPath           // stroke
    let strokeWidth: CGFloat
}

func glyph() -> Glyph {
    let stroke: CGFloat = 9 * unit
    let frame = CGPath(roundedRect: r(34, 52, 92, 64), cornerWidth: 10 * unit, cornerHeight: 10 * unit, transform: nil)
    let strips = [r(34, 52, 14, 64), r(112, 52, 14, 64)].map {
        CGPath(roundedRect: $0, cornerWidth: 4 * unit, cornerHeight: 4 * unit, transform: nil)
    }
    let shaft = CGPath(roundedRect: r(75.5, 22, 9, 66), cornerWidth: 4.5 * unit, cornerHeight: 4.5 * unit, transform: nil)
    let head = CGMutablePath()
    head.move(to: p(60, 70))
    head.addLine(to: p(80, 92))
    head.addLine(to: p(100, 70))
    return Glyph(frame: frame, strips: strips, shaft: shaft, head: head, strokeWidth: stroke)
}

let tileTop = color(0xF47A62), tileMid = color(0xE2503F), tileBottom = color(0xA3241B)
let glyphShadow = color(0x5A0E08, 0.45)

func drawTileContents(_ context: CGContext, clip: CGPath) {
    // Tile: deep red at the bottom, warm coral at the top.
    fill(clip, in: context, gradient: [tileTop, tileMid, tileBottom], locations: [0, 0.5, 1],
         from: CGPoint(x: 512, y: tileRect.maxY), to: CGPoint(x: 512, y: tileRect.minY))

    // Soft glow behind the glyph.
    context.saveGState()
    context.addPath(clip)
    context.clip()
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFD9CC, 0.35), color(0xFFD9CC, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 540), startRadius: 0, endCenter: CGPoint(x: 512, y: 540), endRadius: 430, options: [])
    context.restoreGState()

    let g = glyph()

    // Sprocket strips: translucent white, no shadow, so they read as part of the frame.
    for strip in g.strips {
        context.saveGState()
        context.addPath(strip)
        context.setFillColor(color(0xFFFFFF, 0.45))
        context.fillPath()
        context.restoreGState()
    }

    // Frame outline: shadow pass, then a white → pale gradient through the stroke.
    let frameStroke = g.frame.copy(strokingWithWidth: g.strokeWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let headStroke = g.head.copy(strokingWithWidth: g.strokeWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    for path in [frameStroke, g.shaft, headStroke] {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: glyphShadow)
        context.addPath(path)
        context.setFillColor(color(0xFFFFFF))
        context.fillPath()
        context.restoreGState()
        fill(path, in: context, gradient: [color(0xFFFFFF), color(0xFFE9E3)], locations: [0, 1],
             from: CGPoint(x: 512, y: 800), to: CGPoint(x: 512, y: 224))
    }
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    context.setShouldAntialias(true)

    let tile = tilePath()

    // Drop shadow under the tile, as on system icons.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    context.addPath(tile)
    context.setFillColor(tileBottom)
    context.fillPath()
    context.restoreGState()

    drawTileContents(context, clip: tile)

    // Subtle inner rim on the tile.
    context.saveGState()
    context.addPath(tile)
    context.setStrokeColor(color(0xFFFFFF, 0.14))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()

    return rep.representation(using: .png, properties: [:])!
}

/// The website icon: the tile alone, cropped to its bounds, no drop shadow.
func renderSite(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    context.scaleBy(x: CGFloat(size) / tileRect.width, y: CGFloat(size) / tileRect.height)
    context.translateBy(x: -tileRect.minX, y: -tileRect.minY)
    context.setShouldAntialias(true)
    let tile = tilePath()
    drawTileContents(context, clip: tile)
    context.saveGState()
    context.addPath(tile)
    context.setStrokeColor(color(0xFFFFFF, 0.14))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()
    return rep.representation(using: .png, properties: [:])!
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--site" {
    let output = URL(fileURLWithPath: arguments.dropFirst().first ?? "shortvid.png")
    try renderSite(size: 320).write(to: output)
    print("Wrote \(output.path)")
} else {
    let output = URL(fileURLWithPath: arguments.first ?? ".")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        try render(size: size).write(to: output.appending(path: "icon_\(size).png"))
    }
    print("Wrote icons to \(output.path)")
}
