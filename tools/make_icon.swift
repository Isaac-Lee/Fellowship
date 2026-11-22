// Usage: swift tools/make_icon.swift <AppIcon.appiconset dir>
// Renders icon-light/dark/tinted.png (1024x1024): red name-seal with 「通」.
import AppKit
import CoreText

let S: CGFloat = 1024
let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func rgb(_ h: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
}
let paper = rgb(0xF4EFE6), ink = rgb(0x1C1B1A), red = rgb(0xB5361F)

let fontName = ["PingFangTC-Semibold", "Heiti TC"].first { NSFont(name: $0, size: 10) != nil } ?? "Heiti TC"

enum Variant { case light, dark, tinted }

func render(_ v: Variant, to name: String) {
    let alpha: CGImageAlphaInfo = v == .tinted ? .premultipliedLast : .noneSkipLast
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)!
    switch v {
    case .light: ctx.setFillColor(paper); ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
    case .dark: ctx.setFillColor(ink); ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
    case .tinted: break // transparent
    }
    let side = S * 0.62, r = side * 0.14
    let seal = CGRect(x: (S - side) / 2, y: (S - side) / 2, width: side, height: side)
    ctx.setFillColor(v == .tinted ? CGColor(gray: 1, alpha: 1) : red)
    ctx.addPath(CGPath(roundedRect: seal, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.fillPath()

    // glyph: size so its ink bounds fill ~70% of the seal, then center on those bounds
    let attr = { (size: CGFloat) in NSAttributedString(string: "通", attributes: [
        .font: CTFontCreateWithName(fontName as CFString, size, nil), kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true]) }
    let probe = CTLineCreateWithAttributedString(attr(100))
    let pb = CTLineGetBoundsWithOptions(probe, .useGlyphPathBounds)
    let size = 100 * (side * 0.70) / max(pb.width, pb.height)
    let line = CTLineCreateWithAttributedString(attr(size))
    let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textPosition = CGPoint(x: seal.midX - b.midX, y: seal.midY - b.midY)
    if v == .tinted { ctx.setBlendMode(.clear) }  // cut the glyph out of the seal
    ctx.setFillColor(paper)
    CTLineDraw(line, ctx)

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir + "/" + name))
}
render(.light, to: "icon-light.png")
render(.dark, to: "icon-dark.png")
render(.tinted, to: "icon-tinted.png")
print("font:", fontName)
