#!/usr/bin/swift

import AppKit

struct RenderTarget {
    let path: String
    let size: Int
}

enum AssetError: Error, CustomStringConvertible {
    case missingImage(String)
    case failedToRender(String)
    case failedToWrite(String)

    var description: String {
        switch self {
        case .missingImage(let path):
            return "Missing image at \(path)"
        case .failedToRender(let path):
            return "Failed to render image for \(path)"
        case .failedToWrite(let path):
            return "Failed to write PNG to \(path)"
        }
    }
}

let repoRoot = FileManager.default.currentDirectoryPath
let appIconSourcePath = "\(repoRoot)/casper-logo.png"
let menuIconSourcePath = "\(repoRoot)/casper-plain.png"
let assetsRoot = "\(repoRoot)/Casper/Assets.xcassets"

let appIconTargets = [
    RenderTarget(path: "\(assetsRoot)/AppIcon.appiconset/app-icon-16.png", size: 16),
    RenderTarget(path: "\(assetsRoot)/AppIcon.appiconset/app-icon-32.png", size: 32),
    RenderTarget(path: "\(assetsRoot)/AppIcon.appiconset/app-icon-64.png", size: 64),
    RenderTarget(path: "\(assetsRoot)/AppIcon.appiconset/app-icon-128.png", size: 128),
    RenderTarget(path: "\(assetsRoot)/AppIcon.appiconset/app-icon-256.png", size: 256),
    RenderTarget(path: "\(assetsRoot)/AppIcon.appiconset/app-icon-512.png", size: 512),
    RenderTarget(path: "\(assetsRoot)/AppIcon.appiconset/app-icon-1024.png", size: 1024)
]

let menuTargets = [
    RenderTarget(path: "\(assetsRoot)/MenuBarIcon.imageset/menubar-icon.png", size: 18),
    RenderTarget(path: "\(assetsRoot)/MenuBarIcon.imageset/menubar-icon@2x.png", size: 36)
]

let menuOrangeTargets = [
    RenderTarget(path: "\(assetsRoot)/MenuBarIconOrange.imageset/menubar-icon-orange.png", size: 18),
    RenderTarget(path: "\(assetsRoot)/MenuBarIconOrange.imageset/menubar-icon-orange@2x.png", size: 36)
]

let menuRedTargets = [
    RenderTarget(path: "\(assetsRoot)/MenuBarIconRed.imageset/menubar-icon-red.png", size: 18),
    RenderTarget(path: "\(assetsRoot)/MenuBarIconRed.imageset/menubar-icon-red@2x.png", size: 36)
]

let menuRedDimTargets = [
    RenderTarget(path: "\(assetsRoot)/MenuBarIconRedDim.imageset/menubar-icon-red-dim.png", size: 18),
    RenderTarget(path: "\(assetsRoot)/MenuBarIconRedDim.imageset/menubar-icon-red-dim@2x.png", size: 36)
]

func loadImage(at path: String) throws -> NSImage {
    guard let image = NSImage(contentsOfFile: path) else {
        throw AssetError.missingImage(path)
    }
    return image
}

func bitmapRep(size: Int) -> NSBitmapImageRep? {
    NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
}

func renderOriginal(source: NSImage, target: RenderTarget) throws {
    guard let rep = bitmapRep(size: target.size) else {
        throw AssetError.failedToRender(target.path)
    }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw AssetError.failedToRender(target.path)
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: target.size, height: target.size)).fill()
    source.draw(in: NSRect(x: 0, y: 0, width: target.size, height: target.size))
    NSGraphicsContext.restoreGraphicsState()

    try writePNG(rep: rep, to: target.path)
}

func renderTinted(source: NSImage, target: RenderTarget, tint: NSColor, insetRatio: CGFloat = 0.06) throws {
    guard let rep = bitmapRep(size: target.size) else {
        throw AssetError.failedToRender(target.path)
    }

    let inset = CGFloat(target.size) * insetRatio
    let drawRect = NSRect(
        x: inset,
        y: inset,
        width: CGFloat(target.size) - (inset * 2),
        height: CGFloat(target.size) - (inset * 2)
    )

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw AssetError.failedToRender(target.path)
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: target.size, height: target.size)).fill()
    tint.setFill()
    NSBezierPath(rect: drawRect).fill()
    source.draw(in: drawRect, from: .zero, operation: .destinationIn, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    try writePNG(rep: rep, to: target.path)
}

func writePNG(rep: NSBitmapImageRep, to path: String) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw AssetError.failedToWrite(path)
    }
    let url = URL(fileURLWithPath: path)
    try data.write(to: url)
}

do {
    let appIconSource = try loadImage(at: appIconSourcePath)
    let menuIconSource = try loadImage(at: menuIconSourcePath)

    for target in appIconTargets {
        try renderOriginal(source: appIconSource, target: target)
    }

    for target in menuTargets {
        try renderTinted(
            source: menuIconSource,
            target: target,
            tint: NSColor(white: 1.0, alpha: 1.0)
        )
    }

    for target in menuOrangeTargets {
        try renderTinted(
            source: menuIconSource,
            target: target,
            tint: NSColor(calibratedRed: 1.0, green: 0.66, blue: 0.20, alpha: 1.0)
        )
    }

    for target in menuRedTargets {
        try renderTinted(
            source: menuIconSource,
            target: target,
            tint: NSColor(calibratedRed: 1.0, green: 0.29, blue: 0.29, alpha: 1.0)
        )
    }

    for target in menuRedDimTargets {
        try renderTinted(
            source: menuIconSource,
            target: target,
            tint: NSColor(calibratedRed: 0.92, green: 0.27, blue: 0.27, alpha: 0.80)
        )
    }

    print("Brand assets generated successfully.")
} catch {
    fputs("ERROR: \(error)\n", stderr)
    exit(1)
}
