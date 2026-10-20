// Renders Clawd (the classic pose) into build/AppIcon.icns.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let rows = [
    "...#############..", "...#############..", "...##o#######o##..", "...##o#######o##..",
    ".#################", ".#################", "...#############..", "...#############..",
    "...#.#.......#.#..", "...#.#.......#.#..",
]
func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let bg = NSBezierPath(roundedRect: NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8), xRadius: s * 0.18, yRadius: s * 0.18)
    NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1).setFill()
    bg.fill()
    let px = s * 0.6 / 18, py = px * 1.1
    let ox = s * 0.2, oy = s * 0.5 + 5 * py
    for (y, row) in rows.enumerated() {
        for (x, c) in row.enumerated() where c != "." {
            (c == "o" ? NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1) : NSColor(srgbRed: 0.84, green: 0.47, blue: 0.34, alpha: 1)).setFill()
            NSRect(x: ox + CGFloat(x) * px, y: oy - CGFloat(y + 1) * py, width: px + 0.5, height: py + 0.5).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let iconset = "\(out)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                     ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(size).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "\(out)/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print("\(out)/AppIcon.icns")
