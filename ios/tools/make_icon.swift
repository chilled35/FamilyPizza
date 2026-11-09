// Draws the App Store icon (1024x1024, opaque PNG): a top-down pizza with one slice pulled out,
// painted by the app's own pizza renderer (FamilyPizza/PizzaArt.swift), on a dark, oven-glow ground.
//
// Usage (from ios/):
//   swiftc -O -parse-as-library -o /tmp/make_icon tools/make_icon.swift FamilyPizza/PizzaArt.swift
//   /tmp/make_icon FamilyPizza/Assets.xcassets/AppIcon.appiconset/icon-1024.png
import AppKit
import SwiftUI

private let size: CGFloat = 1024

/// A slice: centre to rim between two angles (degrees, clockwise from 3 o'clock).
private struct Slice: Shape {
    var from: Double
    var to: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.move(to: c)
        p.addArc(center: c, radius: rect.width, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// Everything except the slice (even-odd), to cut the gap out of the pizza.
private struct WithoutSlice: Shape {
    var slice: Slice

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        p.addPath(slice.path(in: rect))
        return p
    }
}

private struct Icon: View {
    let slice = Slice(from: 0, to: 45)
    let spec = PizzaSpec(sauceHex: "#b5321e", layers: [
        PizzaLayer(toppingId: 1, style: .cheese),
        PizzaLayer(toppingId: 3, style: .pepperoni),
        PizzaLayer(toppingId: 11, style: .basil),
    ])

    var body: some View {
        let pizza = PizzaView(spec: spec, showsDivider: false).frame(width: 800, height: 800)
        let mid = (slice.from + slice.to) / 2 * .pi / 180
        ZStack {
            // Wood-fired oven: dark warm ground, glowing behind the pizza.
            Color(red: 0.13, green: 0.06, blue: 0.035)
            RadialGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.12).opacity(0.85),
                                    Color(red: 0.55, green: 0.16, blue: 0.05).opacity(0.5), .clear],
                           center: UnitPoint(x: 0.45, y: 0.47), startRadius: 200, endRadius: 640)
            pizza
                .mask(WithoutSlice(slice: slice).fill(style: FillStyle(eoFill: true)))
                .offset(x: -50, y: -30)
            pizza
                .mask(slice)
                .shadow(color: .black.opacity(0.4), radius: 22, x: 6, y: 14)
                .offset(x: -50 + 110 * cos(mid), y: -30 + 110 * sin(mid))
        }
        .frame(width: size, height: size)
    }
}

@main
struct MakeIcon {
    @MainActor static func main() throws {
        let out = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"
        let renderer = ImageRenderer(content: Icon())
        renderer.scale = 1
        guard let image = renderer.cgImage else { fatalError("render failed") }
        // App Store icons must be opaque: redraw into a bitmap with no alpha channel.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                   bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current!.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.current = nil
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("Wrote \(out)")
    }
}
