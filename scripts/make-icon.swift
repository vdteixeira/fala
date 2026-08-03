#!/usr/bin/env swift
//
// Draws Resources/Fala.icns from the brand mark, at every size macOS asks for.
//
// The mark is not invented here: it is the logo defined in design/CLAUDE.md and
// DESIGN-HANDOFF.md §5 — four waveform bars forming a speech quote mark — using
// the same proportions the menu-bar icon and the popover lockup already use
// (Sources/FalaKit/MenuBar/MenuBarStatusIcon.swift: heights 6/12/9/5, width 2.5,
// gap 2). Colours come from design/tokens/tokens.json, so the icon cannot drift
// from the rest of the product.
//
// Run: swift scripts/make-icon.swift
//
import AppKit
import Foundation

// MARK: - Brand values (design/tokens/tokens.json)

/// violet.500 → violet.700, the same gradient the popover's logo lockup uses.
let gradientTop = NSColor(srgbRed: 0x6C / 255, green: 0x5C / 255, blue: 0xE7 / 255, alpha: 1)
let gradientBottom = NSColor(srgbRed: 0x42 / 255, green: 0x33 / 255, blue: 0xA6 / 255, alpha: 1)
/// amber.300 — the one warm bar in the lockup.
let accentBar = NSColor(srgbRed: 0xFF / 255, green: 0xC0 / 255, blue: 0x77 / 255, alpha: 1)

/// heights 6/12/9/5 at width 2.5 with 2pt gaps — the mark's own proportions.
let barHeights: [CGFloat] = [6, 12, 9, 5]
let barWidth: CGFloat = 2.5
let barGap: CGFloat = 2
/// The bar that carries the warm accent. Third from the left, as in the lockup.
let accentIndex = 2

// MARK: - Drawing

func drawIcon(size: CGFloat) -> NSImage {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  defer { image.unlockFocus() }

  guard let context = NSGraphicsContext.current?.cgContext else { return image }
  context.setShouldAntialias(true)
  context.interpolationQuality = .high

  // macOS app icons do not fill their canvas: the rounded rect sits inset, which
  // is what makes an icon look the right size next to Apple's own in the Dock.
  let inset = size * 0.086
  let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
  // 22.37% is the Big Sur squircle's corner ratio; a plain rounded rect at that
  // radius is indistinguishable at icon sizes.
  let radius = plate.width * 0.2237
  let platePath = CGPath(
    roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

  context.saveGState()
  context.addPath(platePath)
  context.clip()
  let colors = [gradientTop.cgColor, gradientBottom.cgColor] as CFArray
  if let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
  {
    // 160° matches `markGradientAngle` in the theme.
    context.drawLinearGradient(
      gradient,
      start: CGPoint(x: plate.minX, y: plate.maxY),
      end: CGPoint(x: plate.maxX, y: plate.minY),
      options: [])
  }
  context.restoreGState()

  // The mark, centred on the plate and scaled to ~46% of its width — enough to
  // read at 16pt without crowding the corners at 1024.
  let unitWidth = barWidth * CGFloat(barHeights.count) + barGap * CGFloat(barHeights.count - 1)
  let scale = (plate.width * 0.46) / unitWidth
  let markWidth = unitWidth * scale
  let tallest = barHeights.max() ?? 1
  let markHeight = tallest * scale
  let originX = plate.midX - markWidth / 2
  let originY = plate.midY - markHeight / 2

  for (index, height) in barHeights.enumerated() {
    let x = originX + CGFloat(index) * (barWidth + barGap) * scale
    let barHeight = height * scale
    // Each bar is centred on the mark's midline, exactly as
    // `MenuBarStatusIcon.geometry` lays them out. Sitting them on a shared
    // baseline instead turns the waveform into a bar chart — which is what the
    // first render of this icon looked like.
    let barRect = CGRect(
      x: x,
      y: originY + (markHeight - barHeight) / 2,
      width: barWidth * scale,
      height: barHeight)
    let corner = min(barRect.width / 2, barRect.height / 2)
    let path = CGPath(
      roundedRect: barRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    context.addPath(path)
    context.setFillColor(index == accentIndex ? accentBar.cgColor : NSColor.white.cgColor)
    context.fillPath()
  }

  return image
}

func png(_ image: NSImage, size: CGFloat) -> Data? {
  guard
    let representation = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(size),
      pixelsHigh: Int(size),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0)
  else { return nil }

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
  image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
  NSGraphicsContext.restoreGraphicsState()
  return representation.representation(using: .png, properties: [:])
}

// MARK: - Emit the iconset

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/Fala.iconset", isDirectory: true)
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

/// The ten files `iconutil` expects. Omitting any of them makes it fail.
let variants: [(name: String, pixels: CGFloat)] = [
  ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for variant in variants {
  guard let data = png(drawIcon(size: variant.pixels), size: variant.pixels) else {
    FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
    exit(1)
  }
  try data.write(to: iconset.appendingPathComponent(variant.name))
}

let icns = root.appendingPathComponent("Resources/Fala.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
  FileHandle.standardError.write(Data("iconutil failed\n".utf8))
  exit(1)
}

try? fileManager.removeItem(at: iconset)
print("Wrote \(icns.path)")
