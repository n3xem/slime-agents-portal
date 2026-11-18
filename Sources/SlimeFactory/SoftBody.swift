import Foundation
import simd

enum BodyStatus {
    case idle, received
}

enum SessionState {
    case none, starting, waiting, busy, exited
}

struct BubbleConfig {
    var workdir: String?
    var sandbox: SandboxMode?
    var permissionMode: String?
    var worktree: Bool?
    var chrome: Bool??
}

enum BadgeKind: String {
    case done, needDecision, blocked, permission, question, plan, error, idle

    var emoji: String {
        switch self {
        case .done: return "👍"
        case .needDecision: return "🙋"
        case .blocked: return "🧱"
        case .permission: return "🔐"
        case .question: return "🙋"
        case .plan: return "📋"
        case .error: return "⚠️"
        case .idle: return "💤"
        }
    }

    var label: String {
        switch self {
        case .done: return "完了"
        case .needDecision: return "判断を求めています"
        case .blocked: return "進められません"
        case .permission: return "許可を待っています"
        case .question: return "質問しています"
        case .plan: return "計画の確認待ち"
        case .error: return "エラーで止まりました"
        case .idle: return "入力待ち"
        }
    }

    var needsAttention: Bool {
        switch self {
        case .done, .idle: return false
        default: return true
        }
    }
}

struct Badge {
    var kind: BadgeKind
    var time: Float
    var summary: String
}

struct Speech {
    var text: String
    var time: Float
}

struct Activity {
    var text: String
    var symbol: String
    var time: Float
    var finished: Bool = false
}

final class PendingSend {
    let targetId: Int
    let targetName: String
    let ropeId: Int
    let message: String
    let summary: String
    let color: V3
    var approvalTitle: String?
    private var resolver: ((Bool) -> Void)?

    init(targetId: Int, targetName: String, ropeId: Int, message: String, summary: String, color: V3,
         approvalTitle: String? = nil, resolver: @escaping (Bool) -> Void) {
        self.approvalTitle = approvalTitle
        self.targetId = targetId
        self.targetName = targetName
        self.ropeId = ropeId
        self.message = message
        self.summary = summary
        self.color = color
        self.resolver = resolver
    }

    func resolve(_ ok: Bool) {
        resolver?(ok)
        resolver = nil
    }
}

final class SoftBody {
    let id: Int
    var template: Template
    var name: String
    let radius: Float
    let isLump: Bool
    let n: Int
    var rest: [V2]
    var x: [V2]
    var v: [V2]
    var pinned: [Bool]
    var anchor: V2

    var com = V2(0, 0)
    var vcom = V2(0, 0)
    var angle: Float = 0

    var scale: Float = 1
    var scaleV: Float = 0
    var scaleTarget: Float = 1
    var contextTokens = 0
    var girth: Float { 0.8 + 0.7 * min(Float(contextTokens) / 200_000, 1) }
    let phase = Float.random(in: 0...10)

    var grabbed = false
    var grabOffsets: [V2] = []
    var grabWeights: [Float] = []

    var knob: Float = 0
    var knobTarget: Float = 0
    var knobAngle: Float = 0
    var hover: Float = 0
    var hoverTarget: Float = 0
    var glow: Float = 0
    var running: Float = 0

    var absorbInto: String?
    var sessionState: SessionState = .none
    var status: BodyStatus = .idle
    var statusTime: Float = 0
    var pending: [PendingSend] = []
    var config = BubbleConfig()
    var isConductor = false
    var activity: Activity?
    var topic: String?
    var speech: Speech?
    var homeTarget: V2?
    var restSpot: V2?
    var dirName = ""
    var sandboxMode: SandboxMode = .inherit
    var domeTime: Float = 0
    var usesWorktree = false
    var dirMismatch = false
    var islandId: Int?
    var destIslandId: Int?
    var badge: Badge?
    var reportedThisTurn = false
    var savedSession: SavedSession?
    var title: String?
    var titleLocked = false
    var titleFromClaude = false

    var displayName: String { title ?? template.name }
    var engine: Engine { savedSession?.engine ?? template.engine }
    var lastHop: Float = 0
    var face = FaceState()
    var faceStyle: FaceStyle = FaceStyle.allCases.randomElement() ?? .standard

    var pullDir = V2(0, 1)
    var pullStretch: Float = 0

    init(id: Int, template: Template, name: String, center: V2, radius: Float, isLump: Bool = false) {
        self.id = id
        self.template = template
        self.name = name
        self.radius = radius
        self.isLump = isLump
        self.anchor = center
        let n = 10
        self.n = n
        var rest: [V2] = []
        for i in 0..<n {
            let a = Float(i) / Float(n) * 2 * .pi
            rest.append(V2(cos(a), sin(a)) * radius * 0.6)
        }
        self.rest = rest
        self.x = rest.map { center + $0 }
        self.v = Array(repeating: V2(0, 0), count: n)
        self.pinned = rest.map { isLump && $0.y < -radius * 0.15 }
        self.com = center
    }

    func computeCom() {
        var c = V2(0, 0), vc = V2(0, 0)
        for i in 0..<n { c += x[i]; vc += v[i] }
        com = c / Float(n)
        vcom = vc / Float(n)
    }

    func startGrab(at p: V2) {
        grabbed = true
        grabOffsets = x.map { $0 - p }
        let r2 = radius * radius * 0.55
        grabWeights = grabOffsets.map { 0.16 + 0.84 * exp(-simd_length_squared($0) / r2) }
    }

    func kick(_ amount: Float) {
        scaleV += amount
    }

    func step(h: Float, t: Float, world: World) {
        scaleV += (170 * (scaleTarget - scale) - 9 * scaleV) * h
        scale += scaleV * h
        if isLump {
            stepLump(h: h, t: t)
        } else {
            stepBody(h: h, t: t, world: world)
        }
    }

    private func stepLump(h: Float, t: Float) {
        let breathe = 1 + 0.025 * sin(1.7 * t + phase)
        for i in 0..<n {
            if pinned[i] {
                x[i] = anchor + rest[i] * scale
                v[i] = V2(0, 0)
                continue
            }
            var goal = anchor + rest[i] * scale * breathe
            if pullStretch > 0 {
                let w = pow(max(0, simd_dot(norm(rest[i]), pullDir)), 2)
                goal += pullDir * pullStretch * w
            }
            var acc = 360 * (goal - x[i]) - 4.0 * v[i]
            acc.x += 22 * sin(t * 1.3 + phase + Float(i) * 0.4)
            v[i] += acc * h
            x[i] += v[i] * h
        }
        computeCom()
    }

    private func stepBody(h: Float, t: Float, world: World) {
        computeCom()
        let s = scale * (1 + 0.014 * sin(1.9 * t + phase))
        var a: Float = 0, b: Float = 0
        for i in 0..<n {
            let q = x[i] - com
            let r = rest[i] * s
            a += r.x * q.y - r.y * q.x
            b += simd_dot(r, q)
        }
        angle = atan2(a, b)
        let ga = angle * 0.92
        let c = cos(ga), sn = sin(ga)

        let k: Float = 520
        let damp: Float = 3.6
        let air = exp(-1.6 * h)
        var target = world.mouse
        if let lump = absorbInto {
            target = world.lump(lump).map { world.toWorld($0.com) } ?? world.toWorld(V2(world.toScreen(com).x, -60))
        }
        for i in 0..<n {
            let r = rest[i] * s
            let goal = com + V2(c * r.x - sn * r.y, sn * r.x + c * r.y)
            var acc = k * (goal - x[i]) - damp * (v[i] - vcom)
            if grabbed {
                let w = grabWeights[i]
                acc += 620 * w * (target + grabOffsets[i] - x[i]) + 34 * w * (world.mouseVel - v[i])
            }
            if absorbInto != nil {
                acc += 140 * (target - com) - 6 * vcom
            }
            if let home = homeTarget, !grabbed, absorbInto == nil {
                acc += (isConductor ? 90 : 60) * (home - com) - (isConductor ? 7 : 5) * vcom
            }
            v[i] += acc * h
            v[i] *= air
            x[i] += v[i] * h
        }
        if absorbInto == nil {
            confine(world: world)
        }
        computeCom()
    }

    private func confine(world: World) {
        let skin = radius * 0.42 * scale
        guard !grabbed, !isConductor, let id = islandId, destIslandId == nil || destIslandId == id,
              let island = world.island(id), island.contains(com) else { return }
        let r = island.rect
        let x0 = Float(r.minX) + skin, x1 = Float(r.maxX) - skin
        let y0 = Float(r.minY + Island.headerHeight) + skin, y1 = Float(r.maxY) - skin
        guard x1 > x0, y1 > y0 else { return }
        for i in 0..<n {
            if x[i].x < x0 { x[i].x = x0; if v[i].x < 0 { v[i].x *= -0.35 } }
            if x[i].x > x1 { x[i].x = x1; if v[i].x > 0 { v[i].x *= -0.35 } }
            if x[i].y < y0 { x[i].y = y0; if v[i].y < 0 { v[i].y *= -0.35 } }
            if x[i].y > y1 { x[i].y = y1; if v[i].y > 0 { v[i].y *= -0.35 } }
        }
    }

    func tip(toward dir: V2) -> V2 {
        var best = 0
        var bestD: Float = -1e9
        for i in 0..<n where !pinned[i] {
            let d = simd_dot(x[i] - anchor, dir)
            if d > bestD { bestD = d; best = i }
        }
        return x[best] - norm(x[best] - anchor) * radius * 0.12
    }

    var knobPosition: V2 {
        com + V2(cos(knobAngle), sin(knobAngle)) * radius * scale * 0.98
    }
}

func collide(_ a: SoftBody, _ b: SoftBody) {
    let d = len(b.com - a.com)
    let reach = (a.radius * a.scale + b.radius * b.scale) * 1.1
    if d > reach { return }
    pushParticles(of: a, outOf: b)
    pushParticles(of: b, outOf: a)
}

private func pushParticles(of a: SoftBody, outOf b: SoftBody) {
    let lim = b.radius * b.scale * 0.92 + a.radius * a.scale * 0.36
    let nb = Float(b.n)
    for i in 0..<a.n {
        let q = a.x[i] - b.com
        let dd = len(q)
        if dd >= lim || dd < 1e-4 { continue }
        let nrm = q / dd
        let pen = lim - dd
        a.x[i] += nrm * pen * 0.5
        for j in 0..<b.n { b.x[j] -= nrm * pen * 0.5 / nb }
        let rel = simd_dot(a.v[i] - b.vcom, nrm)
        if rel < 0 {
            let imp = nrm * (-rel) * 0.9
            a.v[i] += imp * 0.6
            for j in 0..<b.n { b.v[j] -= imp * 0.6 / nb }
        }
    }
}
