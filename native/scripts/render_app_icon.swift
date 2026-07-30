#!/usr/bin/env swift

import AppKit
import Foundation

private let canvasSize = NSSize(width: 1024, height: 1024)
private let tileRect = NSRect(x: 96, y: 96, width: 832, height: 832)
private let artworkRect = NSRect(x: 132, y: 132, width: 760, height: 760)

guard CommandLine.arguments.count == 3 else {
  FileHandle.standardError.write(
    Data("Usage: render_app_icon.swift <foreground.png> <output.png>\n".utf8)
  )
  exit(64)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let foreground = NSImage(contentsOf: inputURL) else {
  FileHandle.standardError.write(Data("Unable to read \(inputURL.path)\n".utf8))
  exit(66)
}

let image = NSImage(size: canvasSize, flipped: false) { bounds in
  guard let context = NSGraphicsContext.current else { return false }
  context.imageInterpolation = .high

  NSColor.clear.setFill()
  bounds.fill()

  let tile = NSBezierPath(
    roundedRect: tileRect,
    xRadius: 188,
    yRadius: 188
  )

  context.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
  shadow.shadowBlurRadius = 30
  shadow.shadowOffset = NSSize(width: 0, height: -20)
  shadow.set()
  NSColor.white.setFill()
  tile.fill()
  context.restoreGraphicsState()

  context.saveGraphicsState()
  tile.addClip()
  let background = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0), 0.0),
    (NSColor(calibratedRed: 0.965, green: 0.976, blue: 0.988, alpha: 1.0), 0.68),
    (NSColor(calibratedRed: 0.91, green: 0.93, blue: 0.95, alpha: 1.0), 1.0)
  )
  background?.draw(in: tileRect, angle: -90)
  context.restoreGraphicsState()

  NSColor(calibratedWhite: 0.58, alpha: 0.34).setStroke()
  tile.lineWidth = 2
  tile.stroke()

  let highlightRect = tileRect.insetBy(dx: 4, dy: 4)
  let highlight = NSBezierPath(
    roundedRect: highlightRect,
    xRadius: 184,
    yRadius: 184
  )
  NSColor.white.withAlphaComponent(0.72).setStroke()
  highlight.lineWidth = 3
  highlight.stroke()

  foreground.draw(
    in: artworkRect,
    from: NSRect(origin: .zero, size: foreground.size),
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high]
  )

  return true
}

guard
  let tiff = image.tiffRepresentation,
  let bitmap = NSBitmapImageRep(data: tiff),
  let png = bitmap.representation(using: .png, properties: [.compressionFactor: 1.0])
else {
  FileHandle.standardError.write(Data("Unable to encode app icon\n".utf8))
  exit(70)
}

do {
  try png.write(to: outputURL, options: .atomic)
} catch {
  FileHandle.standardError.write(Data("Unable to write \(outputURL.path): \(error)\n".utf8))
  exit(73)
}
