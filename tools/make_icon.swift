#!/usr/bin/env swift
import Cocoa

// Generates Resources/AppIcon.icns from an SF Symbol on a rounded gradient.
// Run from the repo root: swift tools/make_icon.swift

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// (size, scale, filename) per Apple's iconset convention
let entries: [(Int, Int, String)] = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

func render(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Rounded-square gradient background.
    let r = s * 0.22
    let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: r, yRadius: r)
    let gradient = NSGradient(starting: NSColor(red: 0.20, green: 0.55, blue: 1.00, alpha: 1),
                              ending:   NSColor(red: 0.05, green: 0.30, blue: 0.85, alpha: 1))!
    gradient.draw(in: path, angle: -90)

    // SF Symbol "safari" tinted white.
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.62, weight: .regular)
        .applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let w = sym.size.width, h = sym.size.height
        let rect = NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h)
        sym.draw(in: rect)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (size, scale, name) in entries {
    let pixels = size * scale
    let data = render(pixels: pixels)
    let url = iconset.appendingPathComponent(name)
    try data.write(to: url)
}

// iconutil --convert icns AppIcon.iconset -> AppIcon.icns
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["--convert", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()

try? fm.removeItem(at: iconset)
print("Wrote Resources/AppIcon.icns")
