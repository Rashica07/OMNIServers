// Renders the icon masters to PNG (and a multi-size .ico) with AppKit's
// built-in SVG support — no external tools. Usage (from Branding/):
//   swiftc -O src/render.swift -o /tmp/cp-render && /tmp/cp-render .
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let out = root.appending(path: "png")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func png(_ svg: String, _ px: Int) -> Data {
    guard let img = NSImage(contentsOf: root.appending(path: svg)) else { fatalError("can't load \(svg)") }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ d: Data, _ name: String) { try! d.write(to: out.appending(path: name)) }

// macOS AppIcon slots. 16/32 px use the simplified cube-only artwork.
let slots: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                              ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
                              ("512x512", 512), ("512x512@2x", 1024)]
for (variant, svg) in [("", "icon-default.svg"), ("-dark", "icon-dark.svg"), ("-tinted", "icon-tinted.svg")] {
    for (slot, px) in slots {
        let src = px <= 32 && variant != "-tinted" ? "icon-small.svg" : svg
        write(png(src, px), "icon\(variant)_\(slot).png")
    }
}
for px in [64, 128, 256, 512, 1024] { write(png("glyph.svg", px), "glyph-\(px).png") }

// Windows .ico: PNG-compressed entries (Vista+), sizes 16…256.
let entries: [(Int, Data)] = [16, 24, 32, 48, 64, 128, 256].map { ($0, png($0 <= 32 ? "icon-small.svg" : "icon-default.svg", $0)) }
var ico = Data([0, 0, 1, 0, UInt8(entries.count), 0])
var offset = 6 + 16 * entries.count
for (px, d) in entries {
    ico += [UInt8(px == 256 ? 0 : px), UInt8(px == 256 ? 0 : px), 0, 0, 1, 0, 32, 0]
    ico += withUnsafeBytes(of: UInt32(d.count).littleEndian, Array.init)
    ico += withUnsafeBytes(of: UInt32(offset).littleEndian, Array.init)
    offset += d.count
}
for (_, d) in entries { ico += d }
try! ico.write(to: root.appending(path: "craftpanel.ico"))
print("rendered", slots.count * 3 + 5, "PNGs + craftpanel.ico")
