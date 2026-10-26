//
//  GenerateIcons.swift
//  RouterWatch
//
//  Generates the asset catalogs for all three platforms.
//
//  Run from the project root:
//      swift Tools/GenerateIcons.swift
//
//  The artwork is drawn with Core Graphics rather than assembled from SF
//  Symbols: Apple's SF Symbols licence explicitly forbids using the symbols in
//  app icons, so a shipping icon has to be original. This draws a signal-arc
//  mark over a navy-to-teal gradient.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Drawing

let backgroundTop = CGColor(srgbRed: 0.043, green: 0.145, blue: 0.271, alpha: 1)      // deep navy
let backgroundBottom = CGColor(srgbRed: 0.122, green: 0.663, blue: 0.627, alpha: 1)   // teal

func makeContext(width: Int, height: Int) -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a \(width)×\(height) bitmap context")
    }
    return context
}

func fillGradient(in context: CGContext, rect: CGRect, clipPath: CGPath?) {
    context.saveGState()
    if let clipPath {
        context.addPath(clipPath)
        context.clip()
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [backgroundTop, backgroundBottom] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )
    context.restoreGState()
}

/// Three concentric arcs opening upward over a filled dot — a signal mark.
func drawSignalMark(in context: CGContext, box: CGRect) {
    let side = min(box.width, box.height)
    let origin = CGPoint(x: box.midX, y: box.minY + side * 0.26)

    context.saveGState()
    context.setLineCap(.round)
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
    context.setLineWidth(side * 0.062)

    for (index, factor) in [0.20, 0.32, 0.44].enumerated() {
        context.setAlpha(1.0 - Double(index) * 0.18)
        context.addArc(
            center: origin,
            radius: side * factor,
            startAngle: .pi * 0.18,
            endAngle: .pi * 0.82,
            clockwise: false
        )
        context.strokePath()
    }

    context.setAlpha(1)
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.addArc(
        center: origin,
        radius: side * 0.062,
        startAngle: 0,
        endAngle: .pi * 2,
        clockwise: false
    )
    context.fillPath()
    context.restoreGState()
}

enum Shape {
    /// iOS and tvOS mask the icon themselves, so the art runs to the edges.
    case fullBleed
    /// macOS icons sit in a rounded square with breathing room around it.
    case macRoundedSquare
}

func renderIcon(size: Int, shape: Shape) -> Data {
    let context = makeContext(width: size, height: size)
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    let side = CGFloat(size)

    switch shape {
    case .fullBleed:
        fillGradient(in: context, rect: canvas, clipPath: nil)
        drawSignalMark(in: context, box: canvas.insetBy(dx: side * 0.16, dy: side * 0.16))
    case .macRoundedSquare:
        let art = canvas.insetBy(dx: side * 0.094, dy: side * 0.094)
        let path = CGPath(
            roundedRect: art,
            cornerWidth: art.width * 0.225,
            cornerHeight: art.width * 0.225,
            transform: nil
        )
        fillGradient(in: context, rect: art, clipPath: path)
        drawSignalMark(in: context, box: art.insetBy(dx: art.width * 0.14, dy: art.width * 0.14))
    }

    return pngData(from: context)
}

func renderWide(width: Int, height: Int) -> Data {
    let context = makeContext(width: width, height: height)
    let canvas = CGRect(x: 0, y: 0, width: width, height: height)
    fillGradient(in: context, rect: canvas, clipPath: nil)
    drawSignalMark(in: context, box: markBox(in: canvas))
    return pngData(from: context)
}

/// Background only, for the back layer of a tvOS parallax stack.
func renderWideBackground(width: Int, height: Int) -> Data {
    let context = makeContext(width: width, height: height)
    fillGradient(in: context, rect: CGRect(x: 0, y: 0, width: width, height: height), clipPath: nil)
    return pngData(from: context)
}

/// The mark on transparency, for the front layer of a tvOS parallax stack.
/// tvOS requires at least two layers with real content, and splitting the art
/// this way is also what makes the parallax effect read as depth.
func renderWideMark(width: Int, height: Int) -> Data {
    let context = makeContext(width: width, height: height)
    drawSignalMark(in: context, box: markBox(in: CGRect(x: 0, y: 0, width: width, height: height)))
    return pngData(from: context)
}

func markBox(in canvas: CGRect) -> CGRect {
    let side = canvas.height * 0.72
    return CGRect(x: canvas.midX - side / 2, y: canvas.midY - side / 2, width: side, height: side)
}

func pngData(from context: CGContext) -> Data {
    guard
        let image = context.makeImage(),
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else {
        fatalError("Could not encode PNG")
    }
    return data
}

// MARK: - File helpers

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let catalog = root.appendingPathComponent("RouterWatch/Resources/Assets.xcassets")

func makeDirectory(_ url: URL) {
    try! fileManager.createDirectory(at: url, withIntermediateDirectories: true)
}

func write(_ data: Data, to url: URL) {
    makeDirectory(url.deletingLastPathComponent())
    try! data.write(to: url)
}

func write(json: String, to url: URL) {
    write(Data(json.utf8), to: url)
}

let catalogInfo = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

// MARK: - Catalog root

if fileManager.fileExists(atPath: catalog.path) {
    try! fileManager.removeItem(at: catalog)
}
makeDirectory(catalog)
write(json: catalogInfo, to: catalog.appendingPathComponent("Contents.json"))

// MARK: - Accent colour

let accent = catalog.appendingPathComponent("AccentColor.colorset")
write(json: """
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0.627",
          "green" : "0.663",
          "red" : "0.122"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""", to: accent.appendingPathComponent("Contents.json"))

// MARK: - AppIcon (iOS + macOS)

let appIcon = catalog.appendingPathComponent("AppIcon.appiconset")
makeDirectory(appIcon)

write(renderIcon(size: 1024, shape: .fullBleed), to: appIcon.appendingPathComponent("ios-1024.png"))

// (size in points, scale) pairs macOS expects.
let macEntries: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var macImageEntries: [String] = []
for (points, scale) in macEntries {
    let pixels = points * scale
    let filename = "mac-\(points)x\(points)@\(scale)x.png"
    write(renderIcon(size: pixels, shape: .macRoundedSquare), to: appIcon.appendingPathComponent(filename))
    macImageEntries.append("""
        {
          "filename" : "\(filename)",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(points)x\(points)"
        }
    """)
}

write(json: """
{
  "images" : [
    {
      "filename" : "ios-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
\(macImageEntries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""", to: appIcon.appendingPathComponent("Contents.json"))

// MARK: - tvOS brand assets

let brand = catalog.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
makeDirectory(brand)

write(json: """
{
  "assets" : [
    {
      "filename" : "App Icon.imagestack",
      "idiom" : "tv",
      "role" : "primary-app-icon",
      "size" : "400x240"
    },
    {
      "filename" : "App Icon - App Store.imagestack",
      "idiom" : "tv",
      "role" : "primary-app-icon",
      "size" : "1280x768"
    },
    {
      "filename" : "Top Shelf Image.imageset",
      "idiom" : "tv",
      "role" : "top-shelf-image",
      "size" : "1920x720"
    },
    {
      "filename" : "Top Shelf Image Wide.imageset",
      "idiom" : "tv",
      "role" : "top-shelf-image-wide",
      "size" : "2320x720"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""", to: brand.appendingPathComponent("Contents.json"))

/// Builds a layered tvOS icon: gradient on the back layer, mark on the front,
/// middle left empty. tvOS rejects a stack unless at least two layers carry
/// content.
func writeImageStack(named name: String, width: Int, height: Int) {
    let stack = brand.appendingPathComponent(name)
    makeDirectory(stack)
    write(json: """
    {
      "info" : {
        "author" : "xcode",
        "version" : 1
      },
      "layers" : [
        {
          "filename" : "Front.imagestacklayer"
        },
        {
          "filename" : "Middle.imagestacklayer"
        },
        {
          "filename" : "Back.imagestacklayer"
        }
      ]
    }
    """, to: stack.appendingPathComponent("Contents.json"))

    for layer in ["Front", "Middle", "Back"] {
        let layerURL = stack.appendingPathComponent("\(layer).imagestacklayer")
        makeDirectory(layerURL)
        write(json: catalogInfo, to: layerURL.appendingPathComponent("Contents.json"))

        let content = layerURL.appendingPathComponent("Content.imageset")
        makeDirectory(content)

        if layer == "Back" || layer == "Front" {
            let slug = name.replacingOccurrences(of: " ", with: "-")
            let one = "\(slug)-\(layer)-1x.png"
            let two = "\(slug)-\(layer)-2x.png"
            let render = layer == "Back" ? renderWideBackground : renderWideMark
            write(render(width, height), to: content.appendingPathComponent(one))
            write(render(width * 2, height * 2), to: content.appendingPathComponent(two))
            write(json: """
            {
              "images" : [
                {
                  "filename" : "\(one)",
                  "idiom" : "tv",
                  "scale" : "1x"
                },
                {
                  "filename" : "\(two)",
                  "idiom" : "tv",
                  "scale" : "2x"
                }
              ],
              "info" : {
                "author" : "xcode",
                "version" : 1
              }
            }
            """, to: content.appendingPathComponent("Contents.json"))
        } else {
            write(json: """
            {
              "images" : [
                {
                  "idiom" : "tv",
                  "scale" : "1x"
                },
                {
                  "idiom" : "tv",
                  "scale" : "2x"
                }
              ],
              "info" : {
                "author" : "xcode",
                "version" : 1
              }
            }
            """, to: content.appendingPathComponent("Contents.json"))
        }
    }
}

writeImageStack(named: "App Icon.imagestack", width: 400, height: 240)
writeImageStack(named: "App Icon - App Store.imagestack", width: 1280, height: 768)

func writeTopShelf(named name: String, width: Int, height: Int) {
    let imageSet = brand.appendingPathComponent(name)
    makeDirectory(imageSet)
    let one = "\(name.replacingOccurrences(of: " ", with: "-"))-1x.png"
    let two = "\(name.replacingOccurrences(of: " ", with: "-"))-2x.png"
    write(renderWide(width: width, height: height), to: imageSet.appendingPathComponent(one))
    write(renderWide(width: width * 2, height: height * 2), to: imageSet.appendingPathComponent(two))
    write(json: """
    {
      "images" : [
        {
          "filename" : "\(one)",
          "idiom" : "tv",
          "scale" : "1x"
        },
        {
          "filename" : "\(two)",
          "idiom" : "tv",
          "scale" : "2x"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """, to: imageSet.appendingPathComponent("Contents.json"))
}

writeTopShelf(named: "Top Shelf Image.imageset", width: 1920, height: 720)
writeTopShelf(named: "Top Shelf Image Wide.imageset", width: 2320, height: 720)

// MARK: - tvOS launch image

let launch = catalog.appendingPathComponent("Launch Image.imageset")
makeDirectory(launch)
write(renderWide(width: 1920, height: 1080), to: launch.appendingPathComponent("launch-1x.png"))
write(renderWide(width: 3840, height: 2160), to: launch.appendingPathComponent("launch-2x.png"))
write(json: """
{
  "images" : [
    {
      "filename" : "launch-1x.png",
      "idiom" : "tv",
      "scale" : "1x"
    },
    {
      "filename" : "launch-2x.png",
      "idiom" : "tv",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""", to: launch.appendingPathComponent("Contents.json"))

print("Wrote asset catalog to \(catalog.path)")
