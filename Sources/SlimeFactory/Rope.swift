import Foundation
import simd

final class Rope {
    let id: Int
    let from: Int
    var to: Int?
    var free: V2
    var pts: [V2]
    var prev: [V2]
    var retracting = false
    var alpha: Float = 1
    var length: Float = 0
    var autoSend = false

    static let count = 16

    init(id: Int, from: Int, start: V2) {
        self.id = id
        self.from = from
        self.free = start
        self.pts = Array(repeating: start, count: Rope.count)
        self.prev = pts
    }

    func endpoints(world: World) -> (V2, V2)? {
        guard let a = world.body(from) else { return nil }
        var target = free
        var b: SoftBody?
        if let to, !retracting, let tb = world.body(to) {
            b = tb
            target = tb.com
        }
        let dir = norm(target - a.com)
        let offset: Float = hasReverse(world) ? 0.42 : 0
        let start = a.com + rot(dir, offset) * a.radius * a.scale * 0.6
        if let b {
            let end = b.com + rot(-dir, offset) * b.radius * b.scale * 0.6
            return (start, end)
        }
        return (start, free)
    }

    func update(dt: Float, world: World) {
        guard let (s, e) = endpoints(world: world) else {
            retracting = true
            alpha = 0
            return
        }
        if retracting {
            free = mixv(free, s, min(1, dt * 9))
            alpha = max(0, alpha - dt * 1.5)
        }
        let m = pts.count
        pts[0] = s
        pts[m - 1] = e
        let bow: Float = hasReverse(world) ? 1 : 0
        let dir = norm(e - s)
        let perp = V2(-dir.y, dir.x)
        let g = V2(0, 420) * dt * dt
        for i in 1..<(m - 1) {
            let u = Float(i) / Float(m - 1)
            let vel = (pts[i] - prev[i]) * 0.975
            prev[i] = pts[i]
            pts[i] += vel + g + perp * (900 * sin(.pi * u) * bow * dt * dt)
        }
        let total = len(e - s)
        let segL = max(total * (1.06 + 0.05 * bow), 10) / Float(m - 1)
        for _ in 0..<12 {
            for i in 0..<(m - 1) {
                let d = pts[i + 1] - pts[i]
                let l = len(d)
                if l < 1e-4 { continue }
                let corr = d * ((l - segL) / l)
                if i == 0 {
                    pts[1] -= corr
                } else if i + 1 == m - 1 {
                    pts[i] += corr
                } else {
                    pts[i] += corr * 0.5
                    pts[i + 1] -= corr * 0.5
                }
            }
        }
        var l: Float = 0
        for i in 0..<(m - 1) { l += len(pts[i + 1] - pts[i]) }
        length = l
    }

    func hasReverse(_ world: World) -> Bool {
        guard let to, !retracting else { return false }
        return world.ropes.contains { $0.from == to && $0.to == from && !$0.retracting }
    }

    var isDead: Bool {
        retracting && (alpha <= 0.01 || len(free - pts[0]) < 3)
    }

    func point(at s: Float) -> (V2, V2) {
        let m = pts.count
        var lens: [Float] = [0]
        for i in 0..<(m - 1) { lens.append(lens[i] + len(pts[i + 1] - pts[i])) }
        let target = clampf(s, 0, 1) * (lens[m - 1])
        for i in 0..<(m - 1) where lens[i + 1] >= target {
            let segLen = max(lens[i + 1] - lens[i], 1e-4)
            let t = (target - lens[i]) / segLen
            return (mixv(pts[i], pts[i + 1], t), norm(pts[i + 1] - pts[i]))
        }
        return (pts[m - 1], norm(pts[m - 1] - pts[m - 2]))
    }

    func distance(to p: V2) -> Float {
        var best: Float = 1e9
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let ba = b - a
            let h = clampf(simd_dot(p - a, ba) / max(simd_dot(ba, ba), 1e-4), 0, 1)
            best = min(best, len(p - (a + ba * h)))
        }
        return best
    }
}
