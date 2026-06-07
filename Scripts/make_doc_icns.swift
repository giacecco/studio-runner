#!/usr/bin/env swift
/// Renders the mug-with-carved-note icon into an .iconset directory, then
/// converts it to an .icns file using iconutil.
///
/// Usage (from repo root):
///   swift Scripts/make_doc_icns.swift
///
/// Output:
///   Resources/StudioRunner.icns      (app icon — used in NSAlert dialogs)
///   Resources/StudioRunnerDoc.icns   (document icon — used by Finder for .studiorunner)
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
        // y lifted from the original 0.08 so the note sits higher on the
        // mug body. Visual centring inside the SF Symbol's bounding box
        // pushes the apparent position lower than the rect suggests.
        note.draw(in: NSRect(x: f * 0.20, y: f * 0.125, width: f * 0.50, height: f * 0.62),
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

/// The artwork is identical for both icons — same mug, same carved note.
/// We emit one .iconset, convert it to .icns once, then copy to the second
/// path. Done this way (rather than rendering twice) so the bitmaps are
/// byte-identical.
let stagingSet = repoRoot.appendingPathComponent("Resources/StudioRunner.iconset")
try? FileManager.default.removeItem(at: stagingSet)
try! FileManager.default.createDirectory(at: stagingSet, withIntermediateDirectories: true)

for (file, pixels) in entries {
    let png = render(pixels: pixels).representation(using: .png, properties: [:])!
    try! png.write(to: stagingSet.appendingPathComponent(file))
    print("  \(file)  (\(pixels)px)")
}

let appIcns = repoRoot.appendingPathComponent("Resources/StudioRunner.icns")
let docIcns = repoRoot.appendingPathComponent("Resources/StudioRunnerDoc.icns")

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", stagingSet.path, "-o", appIcns.path]
try! convert.run()
convert.waitUntilExit()

try? FileManager.default.removeItem(at: docIcns)
try! FileManager.default.copyItem(at: appIcns, to: docIcns)

try! FileManager.default.removeItem(at: stagingSet)
print("==> \(appIcns.lastPathComponent)")
print("==> \(docIcns.lastPathComponent)")
