import AppKit

// Input-menu icons must retain a 16-point logical size at both display scales.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (name, color) in [("CursorMenu.tiff", NSColor.black), ("CursorMenuAlternate.tiff", NSColor.white)] {
    let representations = [1, 2].map { scale -> NSBitmapImageRep in
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16 * scale, pixelsHigh: 16 * scale,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = AffineTransform(scale: CGFloat(scale))
        (transform as NSAffineTransform).concat()
        color.setStroke()
        let cursor = NSBezierPath()
        cursor.lineWidth = 1.5
        cursor.move(to: NSPoint(x: 8, y: 2))
        cursor.line(to: NSPoint(x: 8, y: 14))
        cursor.move(to: NSPoint(x: 5, y: 2))
        cursor.line(to: NSPoint(x: 11, y: 2))
        cursor.move(to: NSPoint(x: 5, y: 14))
        cursor.line(to: NSPoint(x: 11, y: 14))
        cursor.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    let image = NSImage(size: NSSize(width: 16, height: 16))
    image.addRepresentations(representations)
    try image.tiffRepresentation!.write(to: directory.appendingPathComponent(name))
}
