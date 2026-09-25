#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Deliberately small SVG renderer for our geometric master: no web engine,
// external resource loading, downloaded assets, fonts, or random state.
final class Geometry: NSObject, XMLParserDelegate {
    var shapes: [(String, [String: String])] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if ["rect", "ellipse", "circle"].contains(name) { shapes.append((name, attributes)) }
    }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let master = root.appendingPathComponent("design/app-icon/petal-app-icon.svg")
let geometry = Geometry()
let parser = XMLParser(data: try Data(contentsOf: master))
parser.delegate = geometry
guard parser.parse(), geometry.shapes.count == 7 else { fatalError("Invalid geometric master") }
let output = root.appendingPathComponent("apple/PetalChecklist/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        context.translateBy(x: 0, y: 1024); context.scaleBy(x: 1, y: -1)
        for (shape, a) in geometry.shapes {
            func n(_ key: String) -> CGFloat { CGFloat(Double(a[key] ?? "0")!) }
            func color(_ key: String) -> CGColor {
                let hex = UInt32(a[key]!.dropFirst(), radix: 16)!
                return CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255)/255,
                    CGFloat((hex >> 8) & 255)/255, CGFloat(hex & 255)/255, 1])!
            }
            context.saveGState()
            if let transform = a["transform"] {
                let angle = Double(transform.dropFirst(7).split(separator: " ").first!)!
                context.translateBy(x: 512, y: 512); context.rotate(by: angle * .pi / 180)
                context.translateBy(x: -512, y: -512)
            }
            let path: CGPath
            if shape == "rect" {
                path = CGPath(roundedRect: CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height")),
                    cornerWidth: n("rx"), cornerHeight: n("rx"), transform: nil)
            } else {
                let rx = n(shape == "circle" ? "r" : "rx"), ry = n(shape == "circle" ? "r" : "ry")
                path = CGPath(ellipseIn: CGRect(x: n("cx")-rx, y: n("cy")-ry, width: rx*2, height: ry*2), transform: nil)
            }
            context.setFillColor(color("fill")); context.setStrokeColor(color("stroke")); context.setLineWidth(n("stroke-width"))
            context.addPath(path); context.drawPath(using: .fillStroke); context.restoreGState()
        }
        let name = "icon-\(size)@\(scale)x.png"
        let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("PNG export failed") }
        images.append(["idiom":"mac", "size":"\(size)x\(size)", "scale":"\(scale)x", "filename":name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author":"xcode", "version":1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
