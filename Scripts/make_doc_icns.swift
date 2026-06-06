#!/usr/bin/env swift
/// Renders the mug-with-carved-note icon into an .iconset directory, then
/// converts it to an .icns file using iconutil.
///
/// Usage (from repo root):
///   swift Scripts/make_doc_icns.swift
///
/// Output: Resources/StudioRunnerDoc.icns
import AppKit
import Foundation

// Initialise the AppKit graphics subsystem so SF Symbols and compositing work.
let _ = NSApplication.shared

/// Renders the mug-with-carved-music-note into a square bitmap at `pixels` resolution.
func render(pixels: Int) -> NSBitmapImageRep {
    let f = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: f, height: f)

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: f, height: f).fill()

    let mugConf = NSImage.SymbolConfiguration(pointSize: f * 0.82, weight: .medium)
    if let mug = NSImage(systemSymbolName: "mug.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(mugConf) {
        mug.draw(in: NSRect(x: 0, y: 0, width: f, height: f),
                 from: .zero, operation: .sourceOver, fraction: 1)
    }

    let noteConf = NSImage.SymbolConfiguration(pointSize: f * 0.38, weight: .bold)
    if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(noteConf) {
        note.draw(in: NSRect(x: f * 0.20, y: f * 0.08, width: f * 0.50, height: f * 0.62),
                  from: .zero, operation: .destinationOut, fraction: 1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// ── iconutil naming: icon_WxH[@2x].png ──────────────────────────────────────
let entries: [(file: String, pixels: Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",   128),
    ("icon_128x128@2x.png",256),
    ("icon_256x256.png",   256),
    ("icon_256x256@2x.png",512),
    ("icon_512x512.png",   512),
    ("icon_512x512@2x.png",1024),
]

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset  = repoRoot.appendingPathComponent("Resources/StudioRunnerDoc.iconset")
let icns     = repoRoot.appendingPathComponent("Resources/StudioRunnerDoc.icns")

try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (file, pixels) in entries {
    let png = render(pixels: pixels).representation(using: .png, properties: [:])!
    try! png.write(to: iconset.appendingPathComponent(file))
    print("  \(file)  (\(pixels)px)")
}

let result = Process()
result.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
result.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! result.run()
result.waitUntilExit()

try! FileManager.default.removeItem(at: iconset)
print("==> \(icns.lastPathComponent)")
