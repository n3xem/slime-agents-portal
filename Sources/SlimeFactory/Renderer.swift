import Foundation
import Metal
import CoreGraphics
import simd

struct GBlob { var p: V2; var r: Float; var pad: Float = 0; var c: SIMD4<Float> }
struct GSeg { var a: V2; var b: V2; var ra: Float; var rb: Float; var ua: Float; var ub: Float }
struct GGroup {
    var box: SIMD4<Float>
    var kind: UInt32
    var start: UInt32
    var count: UInt32
    var flags: UInt32 = 0
    var color: SIMD4<Float>
    var color2: SIMD4<Float>
    var params: SIMD4<Float>
}
struct GUniforms {
    var size: V2
    var scale: Float
    var time: Float
    var groupCount: UInt32
    var lumpCount: UInt32
    var bandY: Float
    var islandCount: UInt32 = 0
    var cam: V2 = V2(0, 0)
    var zoom: Float = 1
    var pad: Float = 0
}

struct SceneData {
    var groups: [GGroup] = []
    var blobs: [GBlob] = []
    var segs: [GSeg] = []
    var lumps: [SIMD4<Float>] = []
    var islands: [SIMD4<Float>] = []
    var islandBlobs: [SIMD4<Float>] = []
    var ripples: [SIMD4<Float>] = []
}

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    private let dummy: MTLBuffer

    init(device: MTLDevice, format: MTLPixelFormat) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            fatalError("shader compile failed: \(error)")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vmain")
        desc.fragmentFunction = library.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = format
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)
        dummy = device.makeBuffer(length: 256, options: .storageModeShared)!
    }

    private var cam = V2(0, 0)
    private var zoom: Float = 1

    private func S(_ p: V2) -> V2 { (p - cam) * zoom }

    private func appendBody(_ b: SoftBody, color: V3, into blobs: inout [GBlob], world: Bool = true) {
        let c = SIMD4<Float>(color, 1)
        let s = b.scale
        if s < 0.01 { return }
        let k: Float = world ? zoom : 1
        blobs.append(GBlob(p: world ? S(b.com) : b.com, r: b.radius * 0.66 * s * k, c: c))
        for i in 0..<b.n {
            blobs.append(GBlob(p: world ? S(b.x[i]) : b.x[i], r: b.radius * 0.42 * s * k, c: c))
        }
    }

    private func addGroup(_ scene: inout SceneData, kind: UInt32, start: Int, color: SIMD4<Float> = .zero,
                          color2: SIMD4<Float> = .zero, params: SIMD4<Float> = .zero, fullTop: Bool = false, width: Float = 0) {
        let count = scene.blobs.count - start
        if count <= 0 && !fullTop { return }
        var mn = V2(1e9, 1e9), mx = V2(-1e9, -1e9)
        for i in start..<scene.blobs.count {
            let b = scene.blobs[i]
            let R = b.r * 2.0
            mn = simd_min(mn, b.p - R)
            mx = simd_max(mx, b.p + R)
        }
        if fullTop {
            mn = V2(-10, -200)
            mx = V2(width + 10, max(mx.y, 120))
        }
        let box = SIMD4<Float>(mn.x - 8, mn.y - 8, mx.x + 30, mx.y + 40)
        scene.groups.append(GGroup(box: box, kind: kind, start: UInt32(start), count: UInt32(max(count, 0)),
                                   color: color, color2: color2, params: params))
    }

    func buildScene(_ w: World) -> SceneData {
        var s = SceneData()
        cam = w.camera
        zoom = w.zoom
        for i in w.islands + w.poppingIslands {
            let blobStart = s.islandBlobs.count
            for b in w.bodies where b.islandId == i.id && b.absorbInto == nil {
                let c = S(b.com)
                s.islandBlobs.append(SIMD4<Float>(c.x, c.y, (b.radius * b.scale + 26) * zoom, 1))
            }
            for d in i.detaching {
                let age = w.time - d.t0
                let k = max(0, 1 - age / 0.6)
                let wobble = 1 + 0.35 * sin(age * 30) * k
                let c = S(d.p)
                s.islandBlobs.append(SIMD4<Float>(c.x, c.y, d.r * k * k * wobble * zoom, 1))
            }
            let rippleStart = s.ripples.count
            for r in i.ripples {
                let c = S(r.p)
                s.ripples.append(SIMD4<Float>(c.x, c.y, r.t0, r.strength))
            }
            let o = S(V2(Float(i.rect.minX), Float(i.rect.minY)))
            s.islands.append(SIMD4<Float>(o.x, o.y, Float(i.rect.width) * zoom, Float(i.rect.height) * zoom))
            s.islands.append(SIMD4<Float>(i.color, i.glow))
            s.islands.append(SIMD4<Float>(max(0.001, i.appear), Float(i.id % 97), Float(blobStart), Float(s.islandBlobs.count - blobStart)))
            s.islands.append(SIMD4<Float>(Float(rippleStart), Float(s.ripples.count - rippleStart), i.pop, 0))
        }
        for l in w.lumps {
            s.lumps.append(SIMD4<Float>(l.anchor.x, l.template.color.x, l.template.color.y, l.template.color.z))
        }

        let start0 = s.blobs.count
        for l in w.lumps { appendBody(l, color: l.template.color, into: &s.blobs, world: false) }
        if let p = w.pull {
            let c = SIMD4<Float>(w.lump(p.lumpId)?.template.color ?? V3(0.6, 0.6, 0.6), 1)
            for (pos, r) in w.neckBlobs() { s.blobs.append(GBlob(p: pos, r: r, c: c)) }
        }
        for t in w.transients {
            if case .lump = t.target { s.blobs.append(GBlob(p: t.p, r: t.r, c: SIMD4<Float>(t.color, 1))) }
        }
        for b in w.bodies where b.absorbInto != nil && b.popTime == nil { appendBody(b, color: b.template.color, into: &s.blobs) }
        addGroup(&s, kind: 2, start: start0, fullTop: true, width: w.size.x)

        var splashIds = Set(w.bodies.filter { $0.popTime != nil }.map(\.id))
        for t in w.transients { if case .splash(let id) = t.target { splashIds.insert(id) } }
        for id in splashIds.sorted() {
            let st = s.blobs.count
            var center = w.pops.first { $0.seed == id }?.p ?? V2(0, 0)
            if let b = w.body(id), b.popTime != nil {
                appendBody(b, color: b.template.color, into: &s.blobs)
                center = b.com
            }
            for t in w.transients {
                if case .splash(let sid) = t.target, sid == id {
                    s.blobs.append(GBlob(p: S(t.p), r: t.r * zoom, c: SIMD4<Float>(t.color, 1)))
                }
            }
            let sc = S(center)
            addGroup(&s, kind: 0, start: st, color: SIMD4<Float>(sc.x, sc.y, 0, 0))
        }

        for b in w.bodies where b.absorbInto == nil {
            let st = s.blobs.count
            appendBody(b, color: b.template.color, into: &s.blobs)
            if b.knob > 0.02 {
                s.blobs.append(GBlob(p: S(b.knobPosition), r: 12 * b.knob * b.scale * zoom, c: SIMD4<Float>(b.template.color, 1)))
            }
            for t in w.transients {
                if case .body(let id) = t.target, id == b.id {
                    s.blobs.append(GBlob(p: S(t.p), r: t.r * zoom, c: SIMD4<Float>(t.color, 1)))
                }
            }
            for d in w.droplets where d.targetId == b.id && d.s > 0.8 {
                if let pos = w.dropletPosition(d) { s.blobs.append(GBlob(p: S(pos), r: 11 * zoom, c: SIMD4<Float>(d.color, 1))) }
            }
            let sc = S(b.com)
            addGroup(&s, kind: 0, start: st, color: SIMD4<Float>(sc.x, sc.y, 0, 0),
                     params: SIMD4<Float>(b.hover, b.glow, b.running, b.isConductor ? 1 : 0))
        }

        for d in w.droplets where d.s <= 0.8 {
            guard let pos = w.dropletPosition(d) else { continue }
            let st = s.blobs.count
            let grow = smooth(0, 0.12, d.s)
            s.blobs.append(GBlob(p: S(pos), r: (11 * grow + 2) * zoom, c: SIMD4<Float>(d.color, 1)))
            addGroup(&s, kind: 0, start: st)
        }

        for r in w.ropes {
            guard let a = w.body(r.from) else { continue }
            let col2: V3 = r.to.flatMap { w.body($0)?.template.color } ?? a.template.color
            let segStart = s.segs.count
            let m = r.pts.count
            var mn = V2(1e9, 1e9), mx = V2(-1e9, -1e9)
            for i in 0..<(m - 1) {
                let ua = Float(i) / Float(m - 1), ub = Float(i + 1) / Float(m - 1)
                func rad(_ u: Float) -> Float {
                    let e = min(u, 1 - u)
                    return (4.2 + 6.5 * (1 - smooth(0, 0.16, e))) * zoom
                }
                let pa = S(r.pts[i]), pb = S(r.pts[i + 1])
                s.segs.append(GSeg(a: pa, b: pb, ra: rad(ua), rb: rad(ub), ua: ua, ub: ub))
                mn = simd_min(mn, simd_min(pa, pb))
                mx = simd_max(mx, simd_max(pa, pb))
            }
            let box = SIMD4<Float>(mn.x - 16, mn.y - 16, mx.x + 40, mx.y + 50)
            s.groups.append(GGroup(box: box, kind: 1, start: UInt32(segStart), count: UInt32(m - 1),
                                   color: SIMD4<Float>(a.template.color, 1), color2: SIMD4<Float>(col2, 1),
                                   params: SIMD4<Float>(r.length * zoom, r.alpha, r.autoSend ? 1 : 0, 0)))
        }
        return s
    }

    private func buffer<T>(_ arr: [T]) -> MTLBuffer {
        if arr.isEmpty { return dummy }
        return arr.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
    }

    func encode(world: World, pass: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer, scale: Float) {
        let scene = buildScene(world)
        var u = GUniforms(size: world.size, scale: scale, time: world.time, groupCount: UInt32(scene.groups.count),
                          lumpCount: UInt32(scene.lumps.count), bandY: world.bandY, islandCount: UInt32(scene.islands.count / 4),
                          cam: world.camera, zoom: world.zoom)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<GUniforms>.stride, index: 0)
        enc.setFragmentBuffer(buffer(scene.groups), offset: 0, index: 1)
        enc.setFragmentBuffer(buffer(scene.blobs), offset: 0, index: 2)
        enc.setFragmentBuffer(buffer(scene.segs), offset: 0, index: 3)
        enc.setFragmentBuffer(buffer(scene.lumps), offset: 0, index: 4)
        enc.setFragmentBuffer(buffer(scene.islands), offset: 0, index: 5)
        enc.setFragmentBuffer(buffer(scene.islandBlobs), offset: 0, index: 6)
        enc.setFragmentBuffer(buffer(scene.ripples), offset: 0, index: 7)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    func renderImage(world: World, scale: Float) -> CGImage? {
        let w = Int(world.size.x * scale), h = Int(world.size.y * scale)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget]
        td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        encode(world: world, pass: pass, commandBuffer: cb, scale: scale)
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: cs,
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
