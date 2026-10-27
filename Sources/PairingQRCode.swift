import AppKit
import CoreImage.CIFilterBuiltins

enum PairingQRCode {
    static func image(_ value: String) -> NSImage? {
        guard let cg = bitmap(value) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    static func png(_ value: String) -> Data? {
        guard let cg = bitmap(value) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
    private static func bitmap(_ value: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 4, y: 4)) else { return nil }
        let extent = output.extent.insetBy(dx: -16, dy: -16)
        let white = CIImage(color: CIColor.white).cropped(to: extent)
        return CIContext().createCGImage(output.composited(over: white), from: extent)
    }
}
