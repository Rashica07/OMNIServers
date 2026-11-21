import AppKit

/// Server branding: the 64×64 `server-icon.png` shown in the multiplayer
/// list. Direct port of `branding.rs`, using `NSImage`/`NSBitmapImageRep`
/// in place of the Rust side's `image` crate. MOTD itself is a plain
/// `server.properties` key (edited via `Properties` from the Branding
/// card) — same split the Tauri app makes between `branding.rs` and the
/// generic settings editor.
nonisolated enum BrandingManager {
    static let iconFile = "server-icon.png"

    static func hasIcon(serverDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: serverDir.appendingPathComponent(iconFile).path)
    }

    /// Load any common image, square-crop-to-fit, resize to exactly
    /// 64×64 so it never looks stretched, write `server-icon.png`.
    static func setIcon(serverDir: URL, source: URL) throws {
        guard let image = NSImage(contentsOf: source) else {
            throw RconServiceError.message("Couldn't read that image.")
        }
        try setIcon(serverDir: serverDir, image: image)
    }

    static func setIcon(serverDir: URL, image: NSImage) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RconServiceError.message("Couldn't read that image.")
        }
        let w = cgImage.width, h = cgImage.height
        let side = min(w, h)
        guard side > 0,
              let cropped = cgImage.cropping(to: CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side))
        else {
            throw RconServiceError.message("Couldn't process that image.")
        }

        // Draw into a bitmap context with explicit pixel dimensions —
        // `NSImage.lockFocus()` draws at the screen's backing scale
        // (128×128 on any Retina display, silently wrong), so this is
        // the only way to guarantee the exact 64×64 the Rust side's own
        // `image::imageops::resize(..., 64, 64, ...)` produces.
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            throw RconServiceError.message("Couldn't process that image.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cropped, size: NSSize(width: side, height: side))
            .draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = out.representation(using: .png, properties: [:]) else {
            throw RconServiceError.message("Couldn't write server-icon.png")
        }
        try png.write(to: serverDir.appendingPathComponent(iconFile))
    }

    /// The icon every OMNIHost server starts with: the OMNI app icon, as `server-icon.png`.
    /// Never replaces an icon the user already set. Returns whether one was written.
    @discardableResult
    static func installOmniHostIcon(serverDir: URL) -> Bool {
        guard !hasIcon(serverDir: serverDir),
              let icon = NSImage(named: NSImage.applicationIconName) else { return false }
        return (try? setIcon(serverDir: serverDir, image: icon)) != nil
    }

    static func clearIcon(serverDir: URL) throws {
        let p = serverDir.appendingPathComponent(iconFile)
        if FileManager.default.fileExists(atPath: p.path) {
            try FileManager.default.removeItem(at: p)
        }
    }
}
