import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// A join-address QR code. **Native win** over `net.rs`'s `qr_svg` (a
/// hand-rolled SVG-from-scratch encoder using the `qrcode` crate):
/// `CIFilter.qrCodeGenerator` is a real, built-in macOS API for exactly
/// this — no encoder to vendor or maintain.
nonisolated enum QRCode {
    @MainActor
    static func image(for text: String, scale: CGFloat = 8) -> NSImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: transformed)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
