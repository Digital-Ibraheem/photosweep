import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Deterministic image edits used to build the labeled fixture set.
public enum ImageTransforms {
    // CIContext is documented as thread-safe; older SDKs do not mark it Sendable.
    nonisolated(unsafe) static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func load(_ path: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    public static func write(_ image: CGImage, to path: String, type: UTType = .jpeg, quality: Double = 0.88, orientation: Int? = nil) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func context(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    public static func resized(_ image: CGImage, scale: Double) -> CGImage {
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        let ctx = context(w, h)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Rotates the pixels 90° clockwise.
    public static func rotatedClockwise(_ image: CGImage) -> CGImage {
        let ctx = context(image.height, image.width)
        ctx.translateBy(x: 0, y: CGFloat(image.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()!
    }

    public static func centerCropped(_ image: CGImage, keep fraction: Double) -> CGImage {
        let w = Double(image.width) * fraction, h = Double(image.height) * fraction
        let rect = CGRect(x: (Double(image.width) - w) / 2, y: (Double(image.height) - h) / 2, width: w, height: h).integral
        return image.cropping(to: rect)!
    }

    static func filtered(_ image: CGImage, _ build: (CIImage) -> CIImage) -> CGImage {
        let input = CIImage(cgImage: image)
        let output = build(input).cropped(to: input.extent)
        return ciContext.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: sRGB)!
    }

    public static func colorControls(_ image: CGImage, brightness: Double = 0, contrast: Double = 1, saturation: Double = 1) -> CGImage {
        filtered(image) {
            $0.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation,
            ])
        }
    }

    /// Shifts white balance toward warmer tones.
    public static func warmer(_ image: CGImage) -> CGImage {
        filtered(image) {
            $0.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 4800, y: 0),
            ])
        }
    }
}
