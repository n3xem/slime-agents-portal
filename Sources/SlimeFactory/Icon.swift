import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// アプリのアイコンを、画面と同じ Metal の描画とスライムの顔で書き出す（`--icon <out.png>`）。
@MainActor
enum IconRenderer {
    static let canvas = 1024
    static let tile = 824
    static let corner: CGFloat = 185

    static func run(out: URL) {
        let world = World(templates: [])
        world.bodies.removeAll()
        let units: Float = 206
        let scale = Float(tile) / units
        // 上部の帯はカメラに関係なく画面の上に描かれるので、その下だけを切り出す。
        let skip: Float = 140
        world.layout(size: V2(units, units + skip))

        let green = Template(id: "icon", name: "icon", symbol: "hammer.fill", color: V3(0.30, 0.82, 0.38))
        let b = SoftBody(id: 1, template: green, name: "icon", center: V2(0, 0), radius: 54)
        b.faceStyle = .standard
        b.badge = Badge(kind: .done, time: 0, summary: "")
        world.bodies.append(b)
        for _ in 0..<90 { world.update(dt: 1.0 / 60.0) }

        world.zoom = 1.3
        world.camera = b.com - (V2(units * 0.5, skip + units * 0.5) + V2(0, 4)) / world.zoom

        let renderer = Renderer(device: MTLCreateSystemDefaultDevice()!, format: .bgra8Unorm)
        guard let full = renderer.renderImage(world: world, scale: scale),
              let base = full.cropping(to: CGRect(x: 0, y: Int(skip * scale), width: tile, height: tile)) else { return }

        var face = FaceState()
        face.pose = FaceState.target(b)
        let faceView = FaceView(face: face, style: .standard, tint: Color(b.template.color), time: 0)
        let ir = ImageRenderer(content: faceView)
        ir.scale = CGFloat(scale * world.zoom * 1.35)

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let inset = CGFloat(canvas - tile) / 2
        let tileRect = CGRect(x: inset, y: inset, width: CGFloat(tile), height: CGFloat(tile))
        let shape = CGPath(roundedRect: tileRect, cornerWidth: corner, cornerHeight: corner, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.45))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.055, blue: 0.08, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.draw(base, in: tileRect)
        if let f = ir.cgImage {
            let c = ((b.com - world.camera) * world.zoom - V2(0, skip)) * scale
            let w = CGFloat(f.width), h = CGFloat(f.height)
            let cx = inset + CGFloat(c.x), cy = CGFloat(canvas) - (inset + CGFloat(c.y))
            ctx.draw(f, in: CGRect(x: cx - w / 2, y: cy - h / 2 + CGFloat(b.radius * world.zoom * scale) * 0.08, width: w, height: h))
        }
        ctx.restoreGState()

        ctx.addPath(shape)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
        ctx.setLineWidth(4)
        ctx.strokePath()

        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        print("wrote \(out.path)")
    }
}
