import Foundation
import UIKit

/// M13.1 harness. Shared helpers for E3 onward.
enum ImageProbe {
    static func solid(_ color: UIColor, side: CGFloat = 64) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    /// Centre pixel as sRGB 0...255.
    static func centrePixel(_ image: UIImage) -> (r: Int, g: Int, b: Int, a: Int)? {
        guard let cg = image.cgImage else { return nil }
        let rect = CGRect(x: cg.width / 2, y: cg.height / 2, width: 1, height: 1)
        guard let crop = cg.cropping(to: rect) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
    }

    static let named: [String: UIColor] = [
        "red": UIColor(red: 1, green: 0, blue: 0, alpha: 1),
        "green": UIColor(red: 0, green: 1, blue: 0, alpha: 1),
        "blue": UIColor(red: 0, green: 0, blue: 1, alpha: 1),
        "logo": UIColor(red: 1, green: 1, blue: 0, alpha: 1)
    ]

    /// Which named colour is the centre pixel (tolerance 2/255), or its raw RGB.
    static func name(of image: UIImage) -> String {
        guard let p = centrePixel(image) else { return "unreadable" }
        for (name, c) in named {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            if abs(p.r - Int((r * 255).rounded())) <= 2, abs(p.g - Int((g * 255).rounded())) <= 2, abs(p.b - Int((b * 255).rounded())) <= 2 {
                return name
            }
        }
        return "rgb(\(p.r),\(p.g),\(p.b))"
    }
}
