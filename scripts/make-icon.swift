#!/usr/bin/env swift
// Zeichnet das DropNotch-App-Icon und erzeugt Resources/AppIcon.icns + docs/icon.png.
//   swift scripts/make-icon.swift
// Nur AppKit/CoreGraphics; alle Maße beziehen sich auf eine 1024er-Arbeitsfläche
// (Apple-Icon-Raster: 824er-Kachel mit 100 px Rand, kontinuierliche Ecken).
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default

// MARK: - Helfer

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: colors as CFArray, locations: locations)!
}

/// Superellipse ("Squircle") – nähert Apples kontinuierliche Ecken an.
func squircle(_ r: CGRect, exponent n: CGFloat = 5.2) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2
    let cx = r.midX, cy = r.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

/// MacBook-Notch: hängt an `top`, mit nach außen geschwungenen Schultern oben
/// und abgerundeten unteren Ecken. Koordinaten mit y nach unten.
func notchPath(centerX: CGFloat, top: CGFloat, width w: CGFloat, height h: CGFloat,
               shoulder s: CGFloat, radius r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let l = centerX - w / 2, rt = centerX + w / 2, bottom = top + h
    p.move(to: CGPoint(x: l - s, y: top))
    p.addLine(to: CGPoint(x: rt + s, y: top))
    p.addQuadCurve(to: CGPoint(x: rt, y: top + s), control: CGPoint(x: rt, y: top))
    p.addLine(to: CGPoint(x: rt, y: bottom - r))
    p.addQuadCurve(to: CGPoint(x: rt - r, y: bottom), control: CGPoint(x: rt, y: bottom))
    p.addLine(to: CGPoint(x: l + r, y: bottom))
    p.addQuadCurve(to: CGPoint(x: l, y: bottom - r), control: CGPoint(x: l, y: bottom))
    p.addLine(to: CGPoint(x: l, y: top + s))
    p.addQuadCurve(to: CGPoint(x: l - s, y: top), control: CGPoint(x: l, y: top))
    p.closeSubpath()
    return p
}

// MARK: - Zeichnen

func drawIcon(in ctx: CGContext) {
    // y-Achse nach unten, Einheiten = 1024er-Raster
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = squircle(tile)

    // Schlagschatten der Kachel
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 20, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x14161D))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    // Hintergrund: dunkler Verlauf mit leichtem Blau-Violett-Schimmer
    ctx.drawLinearGradient(gradient([rgb(0x2E3550), rgb(0x161A28), rgb(0x0B0D14)], [0, 0.55, 1]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // Lichtschein unterhalb der Notch
    ctx.drawRadialGradient(gradient([rgb(0x5B8CFF, 0.40), rgb(0x5B8CFF, 0)]),
                           startCenter: CGPoint(x: 512, y: 300), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 300), endRadius: 420, options: [])

    // Pfeil-Spur (Bewegung nach oben in die Notch)
    let arrowGrad = gradient([rgb(0x6FD3FF), rgb(0x4D7CFF)])
    let shaft = CGMutablePath()
    shaft.move(to: CGPoint(x: 512, y: 790))
    shaft.addLine(to: CGPoint(x: 512, y: 640))
    ctx.saveGState()
    ctx.addPath(shaft.copy(strokingWithWidth: 44, lineCap: .round, lineJoin: .round, miterLimit: 10))
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: 448, y: 690))
    chevron.addLine(to: CGPoint(x: 512, y: 626))
    chevron.addLine(to: CGPoint(x: 576, y: 690))
    ctx.addPath(chevron.copy(strokingWithWidth: 44, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.clip()
    ctx.drawLinearGradient(arrowGrad, start: CGPoint(x: 512, y: 810), end: CGPoint(x: 512, y: 600), options: [])
    ctx.restoreGState()

    // Dokument, das von unten in die Notch gleitet
    let docRect = CGRect(x: 512 - 118, y: 172, width: 236, height: 356)
    // Oberkante steckt in der Notch → schlichte Karte mit Textzeilen genügt
    let docPath = CGPath(roundedRect: docRect, cornerWidth: 30, cornerHeight: 30, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgb(0x000000, 0.5))
    ctx.addPath(docPath)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(docPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF), rgb(0xDCE3F2)]),
                           start: CGPoint(x: 512, y: docRect.minY), end: CGPoint(x: 512, y: docRect.maxY), options: [])
    // Textzeilen
    ctx.setFillColor(rgb(0xB4BFD6))
    for (i, w) in [CGFloat(140), 164, 110].enumerated() {
        let y = docRect.minY + 196 + CGFloat(i) * 40
        ctx.addPath(CGPath(roundedRect: CGRect(x: docRect.minX + 40, y: y, width: w, height: 18),
                           cornerWidth: 9, cornerHeight: 9, transform: nil))
    }
    ctx.fillPath()
    ctx.restoreGState()

    // Notch (über dem Dokument, damit es darin verschwindet)
    let notch = notchPath(centerX: 512, top: 100, width: 360, height: 132, shoulder: 40, radius: 52)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 24, color: rgb(0x000000, 0.55))
    ctx.addPath(notch)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.restoreGState()
    // feine Kante an der Notch-Unterseite
    ctx.saveGState()
    ctx.addPath(notch)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x000000), rgb(0x000000), rgb(0x1C2030)], [0, 0.82, 1]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 232), options: [])
    ctx.restoreGState()

    // Glanz oben auf der Kachel + feine Innenkante
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.07), rgb(0xFFFFFF, 0)]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 420), options: [])
    ctx.restoreGState()
    ctx.addPath(tilePath)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    ctx.setLineWidth(2)
    ctx.strokePath()
}

func render(size px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    drawIcon(in: ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG konnte nicht geschrieben werden: \(url.path)") }
}

// MARK: - Iconset + icns

let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    writePNG(render(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let resources = root.appendingPathComponent("Resources")
let icns = resources.appendingPathComponent("AppIcon.icns")
try fm.createDirectory(at: resources, withIntermediateDirectories: true)
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else { fatalError("iconutil fehlgeschlagen") }

let docs = root.appendingPathComponent("docs")
try fm.createDirectory(at: docs, withIntermediateDirectories: true)
writePNG(render(size: 512), to: docs.appendingPathComponent("icon.png"))

print("✓ \(icns.path)")
print("✓ \(docs.appendingPathComponent("icon.png").path)")
