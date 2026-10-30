// Makes Resources/AppIcon.icns from Resources/AppIcon-artwork.png, square
// artwork that fills its whole canvas. It's laid out on Apple's macOS icon
// grid: an 824-point rounded square (continuous corners) centred on a
// 1024-point canvas, with a soft shadow below it.
//   swift scripts/make-icon.swift
import AppKit
import SwiftUI

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let artwork = root.appendingPathComponent("Resources/AppIcon-artwork.png")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

guard let art = NSImage(contentsOf: artwork)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("can't read \(artwork.path)")
}

/// The icon drawn at `pixels` square.
func render(_ pixels: Int) -> Data {
    let scale = CGFloat(pixels) / 1024
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: body).cgPath

    // The shadow, cast by the shape filled once beneath the artwork. Its offset
    // and blur are in pixels, unscaled, so they're scaled here.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale, color: CGColor(gray: 0, alpha: 0.3))
    context.addPath(shape)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.addPath(shape)
    context.clip()
    context.draw(art, in: body)

    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try! render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(output.path)")
