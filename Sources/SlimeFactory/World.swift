import AppKit
import simd

struct Pull {
    var lumpId: String
    var proto: V2
    var protoV: V2
    var sag = V2(0, 0)
    var sagV = V2(0, 0)
    var protoR: Float = 14
}

enum TransientTarget {
    case lump(String)
    case body(Int)
}

struct Transient {
    var p: V2
    var v: V2
    var r: Float
    var color: V3
    var target: TransientTarget
    var age: Float = 0
}

struct Droplet {
    let ropeId: Int
    let targetId: Int
    let color: V3
    var s: Float = 0
}

struct PillLayout {
    let rect: CGRect
    let text: String
    let icon: String
    let color: V3
    let recommended: Bool
    let index: Int
}

enum DragMode {
    case none
    case body(Int)
    case pull
    case rope(Int)
    case island(Int, [Int])
    case islandResize(Int)
    case pan(V2, V2)
}

enum CursorKind {
    case arrow, openHand, closedHand, crosshair, pointingHand
}

final class World {
    var size = V2(1440, 900)
    var time: Float = 0
    let bandY: Float = 30
    let bubbleR: Float = 54
    let lumpR: Float = 42
    let breakDist: Float = 150

    var lumps: [SoftBody] = []
    var bodies: [SoftBody] = []
    var ropes: [Rope] = []
    var transients: [Transient] = []
    var droplets: [Droplet] = []
    var pull: Pull?

    var mouse = V2(-1000, -1000)
    var mouseVel = V2(0, 0)
    private var lastMouse = V2(-1000, -1000)
    var mouseScreen = V2(-1000, -1000)
    var mouseScreenVel = V2(0, 0)
    private var lastMouseScreen = V2(-1000, -1000)
    var zoom: Float = 1
    var camera = V2(0, 0)

    func toWorld(_ s: V2) -> V2 { camera + s / zoom }
    func toScreen(_ w: V2) -> V2 { (w - camera) * zoom }

    var visibleRect: CGRect {
        let a = toWorld(V2(0, bandY + 40)), b = toWorld(size)
        return CGRect(x: CGFloat(a.x), y: CGFloat(a.y), width: CGFloat(b.x - a.x), height: CGFloat(b.y - a.y))
    }

    private func refreshMouse() {
        if mouseScreen.x > -999 { mouse = toWorld(mouseScreen) }
    }

    func zoom(by factor: Float, around s: V2) {
        let anchor = toWorld(s)
        zoom = clampf(zoom * factor, 0.25, 2.5)
        camera = anchor - s / zoom
        refreshMouse()
    }

    func pan(byScreen d: V2) {
        camera -= d / zoom
        refreshMouse()
    }

    func resetView() {
        zoom = 1
        camera = V2(0, 0)
        refreshMouse()
    }
    var mouseIsDown = false
    var dragMode: DragMode = .none
    private var downTime: Float = 0
    private var downScreen = V2(0, 0)
    private var nextId = 100
    private var accumulator: Float = 0
    var hoverPill: (Int, Int)?
    var hoverLump: String?
    var hoverBody: Int?

    var islands: [Island] = []
    var poppingIslands: [Island] = []
    var islandsLoaded = false
    var onIslandsChanged: (() -> Void)?
    private var islandsSettling = false
    var onOpenBody: ((SoftBody) -> Void)?
    var onEditTemplate: ((String) -> Void)?
    var shouldConfirmRemove: ((SoftBody) -> Bool)?
    var onConfirmRemove: ((SoftBody) -> Void)?
    var onRemoved: ((SoftBody) -> Void)?
    var sessionStateProvider: ((Int) -> SessionState)?
    var sessionTitleProvider: ((Int) -> String?)?
    var launchInfoProvider: ((SoftBody) -> (String, SandboxMode, Bool, Bool))?

    static let pillFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    static func clipTitle(_ s: String) -> String {
        var width: Double = 0
        var out = ""
        for ch in s {
            width += ch.isASCII ? 0.55 : 1
            if width > 14 { return out + "…" }
            out.append(ch)
        }
        return out
    }

    static func sessionName(_ raw: String) -> String {
        let mapped = raw.unicodeScalars.map { c -> Character in
            let ch = Character(c)
            return (ch.isLetter || ch.isNumber || ch == "-" || ch == "_") ? ch : "-"
        }
        let s = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "bubble" : s
    }

    static let conductorTemplate = Template(id: "__conductor", name: "管理", symbol: "crown.fill", color: V3(0.52, 0.32, 0.9))

    var conductorSpot: V2?
    var conductorHome: V2 {
        conductorSpot ?? V2(92, size.y - 110)
    }

    func placeConductor(at p: V2) {
        conductorSpot = p
        guard let c = conductor else { return }
        let home = conductorHome
        c.homeTarget = home
        if !c.grabbed {
            let shift = home - c.com
            for k in 0..<c.n { c.x[k] += shift }
            c.computeCom()
        }
    }
    var conductor: SoftBody? { bodies.first { $0.isConductor } }

    init(templates: [Template]) {
        syncTemplates(templates)
        layout(size: size)
        let c = SoftBody(id: nextId, template: World.conductorTemplate, name: "管理", center: conductorHome, radius: 64)
        nextId += 1
        c.isConductor = true
        c.faceStyle = .standard
        c.homeTarget = conductorHome
        bodies.append(c)
    }

    func uniqueName(_ raw: String, avoiding taken: Set<String> = [], except: SoftBody? = nil) -> String {
        let base = World.sessionName(raw)
        var name = base
        var count = 1
        while taken.contains(name) || bodies.contains(where: { $0 !== except && $0.name == name }) {
            count += 1
            name = "\(base)-\(count)"
        }
        return name
    }

    // MARK: - Islands

    func island(_ id: Int) -> Island? { islands.first { $0.id == id } }

    func islandAt(_ p: V2) -> Island? { islands.last { $0.contains(p) } }

    func islandFor(path: String) -> Island? { islands.first { $0.path == path } }

    func freeIslandRect(size want: CGSize = CGSize(width: 620, height: 320)) -> CGRect {
        let vis = visibleRect
        let top = vis.minY + 70
        var y = top
        while y + want.height < vis.maxY - 60 {
            var x: CGFloat = vis.minX + 40
            while x + want.width < vis.maxX - 40 {
                let r = CGRect(x: x, y: y, width: want.width, height: want.height)
                if !islands.contains(where: { $0.rect.insetBy(dx: -24, dy: -24).intersects(r) }) { return r }
                x += 40
            }
            y += 40
        }
        return CGRect(x: vis.minX + 60 + CGFloat(islands.count * 30), y: top + CGFloat(islands.count * 30), width: want.width, height: want.height)
    }

    @discardableResult
    func addIsland(path: String, rect: CGRect? = nil) -> Island {
        if let existing = islandFor(path: path) { return existing }
        let i = Island(id: nextId, path: path, rect: rect ?? freeIslandRect())
        nextId += 1
        i.appearV = 2
        for b in bodies where !b.isConductor && b.islandId == nil && b.destIslandId == nil && i.contains(b.com) { b.islandId = i.id }
        islands.append(i)
        onIslandsChanged?()
        return i
    }

    private func distance(_ p: V2, outside r: CGRect) -> Float {
        let dx = max(Float(r.minX) - p.x, 0, p.x - Float(r.maxX))
        let dy = max(Float(r.minY) - p.y, 0, p.y - Float(r.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }

    private func nearestEdgePoint(_ p: V2, _ r: CGRect) -> V2 {
        let x = clampf(p.x, Float(r.minX), Float(r.maxX)), y = clampf(p.y, Float(r.minY), Float(r.maxY))
        if !r.contains(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))) { return V2(x, y) }
        let dl = p.x - Float(r.minX), dr = Float(r.maxX) - p.x, dt = p.y - Float(r.minY), db = Float(r.maxY) - p.y
        let m = min(dl, dr, dt, db)
        if m == dl { return V2(Float(r.minX), p.y) }
        if m == dr { return V2(Float(r.maxX), p.y) }
        if m == dt { return V2(p.x, Float(r.minY)) }
        return V2(p.x, Float(r.maxY))
    }

    private func enter(_ b: SoftBody, _ i: Island) {
        b.islandId = i.id
        i.ripples.append(Ripple(p: b.com, t0: time, strength: 1))
        i.glow = 1
        if b.scale > 0.9 { b.kick(3) }
        for k in 0..<7 {
            let a = Float(k) / 7 * 2 * .pi + Float.random(in: -0.3...0.3)
            let dir = V2(cos(a), sin(a))
            transients.append(Transient(p: b.com + dir * b.radius * b.scale * 0.7, v: dir * Float.random(in: 220...340),
                                        r: Float.random(in: 6...10), color: b.template.color, target: .body(b.id)))
        }
    }

    private func leave(_ b: SoftBody, _ i: Island) {
        b.islandId = nil
        let edge = nearestEdgePoint(b.com, i.rect)
        i.ripples.append(Ripple(p: edge, t0: time, strength: 0.8))
        i.detaching.append(Detach(p: mixv(edge, b.com, 0.5), r: b.radius * b.scale * 0.9, t0: time))
        i.glow = max(i.glow, 0.5)
        b.kick(3)
    }

    private func updateIslands(dt: Float) {
        for i in islands {
            i.appearV += (150 * (1 - i.appear) - 11 * i.appearV) * dt
            i.appear += i.appearV * dt
            i.glow = max(0, i.glow - dt * 0.9)
            let over: Float = (islandAt(mouse)?.id == i.id || {
                if case .island(let id, _) = dragMode { return id == i.id }
                if case .islandResize(let id) = dragMode { return id == i.id }
                return false
            }()) ? 1 : 0
            i.hover += (over - i.hover) * min(1, dt * 8)
            i.ripples.removeAll { time - $0.t0 > 2.6 }
            i.detaching.removeAll { time - $0.t0 > 0.6 }
        }
        for i in poppingIslands {
            let age = time - (i.popT0 ?? time)
            let swell: Float = age < 0.14 ? 1.05 : 1
            i.appearV += (150 * (swell - i.appear) - 11 * i.appearV) * dt
            i.appear += i.appearV * dt
            i.pop = clampf((age - 0.14) / 0.5, 0, 1)
            i.glow = max(0, i.glow - dt * 0.9)
        }
        poppingIslands.removeAll { $0.pop >= 1 }
        separateIslands(dt: dt)
        for b in bodies where !b.isConductor && b.absorbInto == nil {
            if let id = b.islandId, let cur = island(id) {
                if cur.contains(b.com) { continue }
                if distance(b.com, outside: cur.rect) < 70 { continue }
                leave(b, cur)
            } else if b.islandId != nil {
                b.islandId = nil
            }
            if let dest = b.destIslandId, island(dest) == nil { b.destIslandId = nil }
            if let next = islandAt(b.com), b.destIslandId == nil || b.destIslandId == next.id {
                enter(b, next)
                b.destIslandId = nil
            }
        }
    }

    private func separateIslands(dt: Float) {
        let gap: CGFloat = 28
        var pinned: Int?
        if case .island(let id, _) = dragMode { pinned = id }
        if case .islandResize(let id) = dragMode { pinned = id }
        let rate = CGFloat(min(1, dt * 10))
        var moved = false
        for a in 0..<islands.count {
            for c in (a + 1)..<islands.count {
                let i = islands[a], j = islands[c]
                let ri = i.rect.insetBy(dx: -gap / 2, dy: -gap / 2), rj = j.rect.insetBy(dx: -gap / 2, dy: -gap / 2)
                guard ri.intersects(rj) else { continue }
                let ox = min(ri.maxX, rj.maxX) - max(ri.minX, rj.minX)
                let oy = min(ri.maxY, rj.maxY) - max(ri.minY, rj.minY)
                if min(ox, oy) < 0.5 { continue }
                let px = CGPoint(x: i.rect.midX < j.rect.midX ? -ox : ox, y: 0)
                let py = CGPoint(x: 0, y: i.rect.midY < j.rect.midY ? -oy : oy)
                let wi: CGFloat = i.id == pinned ? 0 : (j.id == pinned ? 1 : 0.5)
                let order = ox < oy ? [px, py] : [py, px]
                pair: for w in wi == 0.5 ? [wi] : [wi, 1 - wi] {
                    for d in order {
                        let k = abs(d.x + d.y) < 1 ? 1 : (w == wi ? rate : 1)
                        let a = shiftIsland(i, by: CGPoint(x: d.x * k * w, y: d.y * k * w))
                        let b = shiftIsland(j, by: CGPoint(x: -d.x * k * (1 - w), y: -d.y * k * (1 - w)))
                        if a || b { moved = true; break pair }
                    }
                }
            }
        }
        if moved {
            islandsSettling = true
        } else if islandsSettling {
            islandsSettling = false
            onIslandsChanged?()
        }
    }

    private func shiftIsland(_ i: Island, by d: CGPoint) -> Bool {
        let r = i.rect
        let nx = r.minX + d.x, ny = r.minY + d.y
        let delta = V2(Float(nx - r.minX), Float(ny - r.minY))
        if abs(delta.x) < 0.01 && abs(delta.y) < 0.01 { return false }
        i.rect = CGRect(x: nx, y: ny, width: r.width, height: r.height)
        for b in bodies where b.islandId == i.id && b.destIslandId == nil && !b.grabbed && b.absorbInto == nil {
            for k in 0..<b.n { b.x[k] += delta }
            if let h = b.homeTarget { b.homeTarget = h + delta }
            b.computeCom()
        }
        for b in bodies where b.destIslandId == i.id && !b.grabbed {
            if let h = b.homeTarget { b.homeTarget = h + delta }
        }
        return true
    }

    func removeIsland(_ i: Island) {
        let members = bodiesInside(i)
        islands.removeAll { $0.id == i.id }
        i.popT0 = time
        i.glow = 1
        i.appearV += 1.6
        poppingIslands.append(i)
        let c = V2(Float(i.rect.midX), Float(i.rect.midY))
        for id in members {
            guard let b = body(id) else { continue }
            b.islandId = nil
            b.face.surprise = 1
            b.kick(3)
            let dir = norm(b.com - c)
            for k in 0..<b.n { b.v[k] += dir * 90 }
        }
        onIslandsChanged?()
    }

    func send(_ b: SoftBody, to island: Island) {
        let c = V2(Float(island.rect.midX), Float(island.rect.midY))
        b.homeTarget = freeSpot(near: c, in: island.rect)
        if b.islandId != island.id {
            b.islandId = nil
            b.destIslandId = island.id
        }
        b.kick(3)
    }

    func bodiesInside(_ i: Island) -> [Int] {
        bodies.filter { !$0.isConductor && $0.absorbInto == nil && i.contains($0.com) }.map(\.id)
    }

    func freeSpot(near: V2, in area: CGRect? = nil) -> V2 {
        var best = near
        var bestScore: Float = .infinity
        let minGap = bubbleR * 2.7
        let bounds = area.map { $0.insetBy(dx: CGFloat(bubbleR) + 14, dy: CGFloat(bubbleR) + 10) }
        let vis = visibleRect
        let y0: Float = bounds.map { Float($0.minY) + Float(Island.headerHeight) } ?? Float(vis.minY) + 130
        let y1: Float = bounds.map { Float($0.maxY) } ?? Float(vis.maxY) - 150
        let x0: Float = bounds.map { Float($0.minX) } ?? 130
        let x1: Float = bounds.map { Float($0.maxX) } ?? Float(vis.maxX) - 130
        var y: Float = y0
        while y <= y1 {
            var x: Float = x0
            while x <= x1 {
                let p = V2(x, y)
                let clear = bodies.allSatisfy { len(($0.homeTarget ?? $0.com) - p) > minGap }
                if clear {
                    let score = len(p - near)
                    if score < bestScore { bestScore = score; best = p }
                }
                x += 30
            }
            y += 30
        }
        return best
    }

    @discardableResult
    func spawnFromLump(templateId: String, name: String?, near: V2? = nil, in island: Island? = nil) -> SoftBody? {
        guard let lump = lump(templateId) else { return nil }
        let start = toWorld(lump.tip(toward: V2(0, 1)) + V2(0, 12))
        let b = SoftBody(id: nextId, template: lump.template, name: uniqueName(name ?? lump.template.name, avoiding: ClaudeSessionRegistry.namesInUse()), center: start, radius: bubbleR)
        nextId += 1
        b.scale = 0.25
        b.scaleV = 2
        if let island {
            let c = V2(Float(island.rect.midX), Float(island.rect.midY))
            b.homeTarget = freeSpot(near: near ?? c, in: island.rect)
            b.destIslandId = island.id
        } else {
            b.homeTarget = freeSpot(near: near ?? toWorld(V2(lump.anchor.x, size.y * 0.45)))
        }
        bodies.append(b)
        for i in 0..<lump.n where !lump.pinned[i] { lump.v[i] += V2(0, 260) }
        lump.kick(3)
        return b
    }

    func syncTemplates(_ templates: [Template]) {
        var next: [SoftBody] = []
        for t in templates {
            if let existing = lumps.first(where: { $0.template.id == t.id }) {
                existing.template = t
                existing.name = t.name
                next.append(existing)
            } else {
                let l = SoftBody(id: nextId, template: t, name: t.name, center: V2(size.x / 2, bandY + 6), radius: lumpR, isLump: true)
                nextId += 1
                l.scale = 0.05
                next.append(l)
            }
        }
        let ids = Set(templates.map { $0.id })
        if let p = pull, !ids.contains(p.lumpId) { pull = nil; dragMode = .none }
        lumps = next
        for b in bodies {
            if let t = templates.first(where: { $0.id == b.template.id }) { b.template = t }
        }
        placeLumps(snap: false)
    }

    private func placeLumps(snap: Bool) {
        let count = Float(lumps.count)
        guard count > 0 else { return }
        let spacing = count > 1 ? min(176, (size.x - 260) / (count - 1)) : 0
        let x0 = size.x / 2 - spacing * (count - 1) / 2
        for (i, l) in lumps.enumerated() {
            let a = V2(x0 + spacing * Float(i), bandY + 6)
            let shift = a - l.anchor
            l.anchor = a
            if snap {
                for j in 0..<l.n { l.x[j] += shift }
            }
            l.computeCom()
        }
    }

    func layout(size: V2) {
        self.size = size
        placeLumps(snap: true)
        if let c = bodies.first(where: { $0.isConductor }) { c.homeTarget = conductorHome }
    }

    func body(_ id: Int) -> SoftBody? { bodies.first { $0.id == id } }
    func lump(_ id: String) -> SoftBody? { lumps.first { $0.template.id == id } }

    // MARK: - Simulation

    func update(dt rawDt: Float) {
        let dt = min(rawDt, 1.0 / 20.0)
        time += dt
        if dt > 0 {
            let mv = (mouse - lastMouse) / dt
            if len(lastMouse - V2(-1000, -1000)) > 1 && len(mv) < 20000 {
                mouseVel = mixv(mouseVel, mv, 0.35)
            }
            lastMouse = mouse
            let ms = (mouseScreen - lastMouseScreen) / dt
            if len(lastMouseScreen - V2(-1000, -1000)) > 1 && len(ms) < 20000 {
                mouseScreenVel = mixv(mouseScreenVel, ms, 0.35)
            }
            lastMouseScreen = mouseScreen
        }
        if !mouseIsDown {
            mouseVel *= 0.8
            mouseScreenVel *= 0.8
        }

        let h: Float = 1.0 / 240.0
        accumulator += dt
        var steps = 0
        while accumulator >= h && steps < 14 {
            substep(h: h)
            accumulator -= h
            steps += 1
        }
        if steps == 14 { accumulator = 0 }

        for r in ropes { r.update(dt: dt, world: self) }
        ropes.removeAll { $0.isDead }
        updateDroplets(dt: dt)
        updateIslands(dt: dt)
        updateHover(dt: dt)
        updateStatus(dt: dt)

        var removed: [SoftBody] = []
        bodies.removeAll { b in
            if b.absorbInto != nil && b.scale < 0.06 {
                if let l = b.absorbInto { lump(l)?.kick(3.5) }
                removed.append(b)
                return true
            }
            return false
        }
        for b in removed { onRemoved?(b) }
        for b in bodies where !b.isConductor {
            if let h = b.homeTarget, len(b.com - h) < 8, len(b.vcom) < 40 {
                b.homeTarget = nil
                b.restSpot = h
                let vc = b.vcom
                for i in 0..<b.n { b.v[i] -= vc }
            }
        }
    }

    private func substep(h: Float) {
        if var p = pull {
            guard let lump = lump(p.lumpId) else { pull = nil; return }
            let base = lump.tip(toward: norm(p.proto - lump.anchor))
            var acc = 760 * (mouseScreen - p.proto) + 30 * (mouseScreenVel - p.protoV)
            acc += -7 * (p.proto - base)
            p.protoV += acc * h
            p.proto += p.protoV * h
            let targetSag = clampLen(-p.protoV * 0.06, 70)
            p.sagV += (150 * (targetSag - p.sag) - 8 * p.sagV) * h
            p.sag += p.sagV * h
            let dist = len(p.proto - base)
            p.protoR = mixf(13, bubbleR * 0.78, smooth(0, breakDist, dist))
            lump.pullDir = norm(p.proto - lump.anchor)
            lump.pullStretch = min(dist * 0.4, 46)
            pull = p
            if dist > breakDist { snap() }
        }
        for l in lumps { l.step(h: h, t: time, world: self) }
        for b in bodies { b.step(h: h, t: time, world: self) }
        for i in 0..<bodies.count {
            if bodies[i].absorbInto != nil { continue }
            for j in (i + 1)..<max(bodies.count, i + 1) where bodies[j].absorbInto == nil {
                collide(bodies[i], bodies[j])
            }
        }
        for i in transients.indices {
            var t = transients[i]
            var tp = t.p
            switch t.target {
            case .lump(let l): if let lp = lump(l) { tp = lp.com } else { t.r = 0 }
            case .body(let id): if let b = body(id) { tp = b.com } else { t.r = 0 }
            }
            let acc = 260 * (tp - t.p) - 13 * t.v
            t.v += acc * h
            t.p += t.v * h
            t.age += h
            if t.age > 0.05 { t.r *= exp(-h * 5.5) }
            transients[i] = t
        }
        transients.removeAll { $0.r < 1.2 }
    }

    func neckBlobs() -> [(V2, Float)] {
        guard let p = pull, let lump = lump(p.lumpId) else { return [] }
        let base = lump.tip(toward: norm(p.proto - lump.anchor))
        let end = p.proto
        let mid = (base + end) * 0.5 + p.sag
        let dist = len(end - base)
        let thin = mixf(1, 0.34, smooth(0, breakDist, dist))
        let m = max(4, Int(dist / 11) + 3)
        var out: [(V2, Float)] = []
        for j in 0..<m {
            let t = (Float(j) + 0.5) / Float(m)
            let a = mixv(base, mid, t), b = mixv(mid, end, t)
            let pos = mixv(a, b, t)
            let r = mixf(lump.radius * 0.42, p.protoR * 0.62, t) * mixf(1, thin, sin(.pi * t))
            out.append((pos, r))
        }
        out.append((end, p.protoR))
        return out
    }

    private func snap() {
        guard let p = pull, let lump = lump(p.lumpId) else { return }
        let base = lump.tip(toward: norm(p.proto - lump.anchor))
        let dir = norm(p.proto - base)
        let blobs = neckBlobs()
        let id = nextId
        nextId += 1
        let tpl = lump.template
        let name = uniqueName(tpl.name, avoiding: ClaudeSessionRegistry.namesInUse())
        let body = SoftBody(id: id, template: tpl, name: name, center: toWorld(p.proto + dir * 8), radius: bubbleR)
        for i in 0..<body.n {
            let r0 = body.rest[i]
            let along = simd_dot(r0, dir)
            let perp = r0 - dir * along
            body.x[i] = toWorld(p.proto) + dir * (8 + along * 1.5) + perp * 0.72
            body.v[i] = p.protoV / zoom
        }
        body.scale = 0.72
        body.scaleV = 4.5
        body.computeCom()
        bodies.append(body)
        for (j, b) in blobs.dropLast().enumerated() {
            let t = Float(j) / Float(blobs.count)
            if t < 0.55 {
                transients.append(Transient(p: b.0, v: -dir * 160, r: b.1, color: tpl.color, target: .lump(p.lumpId)))
            } else {
                transients.append(Transient(p: toWorld(b.0), v: p.protoV * 0.5 / zoom, r: b.1 / zoom, color: tpl.color, target: .body(id)))
            }
        }
        for i in 0..<lump.n where !lump.pinned[i] { lump.v[i] += -dir * 240 }
        lump.pullStretch = 0
        lump.kick(2.5)
        pull = nil
        body.startGrab(at: mouse)
        dragMode = .body(id)
    }

    private func cancelPull() {
        guard let p = pull else { return }
        if let lump = lump(p.lumpId) {
            for b in neckBlobs() {
                transients.append(Transient(p: b.0, v: V2(0, -60), r: b.1, color: lump.template.color, target: .lump(p.lumpId)))
            }
            lump.pullStretch = 0
            lump.kick(1.5)
        }
        pull = nil
    }

    private func updateDroplets(dt: Float) {
        for i in droplets.indices {
            droplets[i].s += dt * 0.8
        }
        let arrived = droplets.filter { $0.s >= 1 }
        droplets.removeAll { $0.s >= 1 }
        for d in arrived {
            guard let b = body(d.targetId) else { continue }
            b.kick(5)
            b.glow = 1
            b.status = .received
            b.statusTime = 0
        }
    }

    func dropletPosition(_ d: Droplet) -> V2? {
        guard let r = ropes.first(where: { $0.id == d.ropeId }) else { return nil }
        let s = d.s * d.s * (3 - 2 * d.s)
        return r.point(at: s).0
    }

    private func updateHover(dt: Float) {
        hoverBody = nil
        hoverLump = nil
        hoverPill = nil
        if case .none = dragMode {
            hoverPill = pillAt(mouse)
            if hoverPill == nil {
                hoverBody = bodyAt(mouse, slack: 1.5)?.id
                if hoverBody == nil { hoverLump = lumpAt(mouseScreen) }
            }
        }
        for b in bodies {
            var target: Float = 0
            if hoverBody == b.id && !b.isConductor && b.engine == .claude {
                let d = len(mouse - b.com)
                if d > b.radius * b.scale * 0.5 {
                    target = 1
                    b.knobAngle = angleLerp(b.knobAngle, atan2(mouse.y - b.com.y, mouse.x - b.com.x), min(1, dt * 18))
                }
            }
            if case .rope(let rid) = dragMode, let r = ropes.first(where: { $0.id == rid }), r.from == b.id {
                target = 1
                let p = r.pts[1]
                b.knobAngle = angleLerp(b.knobAngle, atan2(p.y - b.com.y, p.x - b.com.x), min(1, dt * 18))
            }
            b.knobTarget = target
            b.knob += (b.knobTarget - b.knob) * min(1, dt * 12)
            let hv: Float = hoverBody == b.id ? 1 : 0
            b.hover += (hv - b.hover) * min(1, dt * 10)
            if b.absorbInto == nil && !b.grabbed {
                b.scaleTarget = (1 + 0.04 * b.hover) * b.girth
            }
            b.glow = max(0, b.glow - dt * 0.7)
        }
        for l in lumps {
            let hv: Float = hoverLump == l.template.id ? 1 : 0
            l.hover += (hv - l.hover) * min(1, dt * 10)
            l.scaleTarget = 1 + 0.1 * l.hover
        }
    }

    private func updateStatus(dt: Float) {
        for b in bodies {
            b.statusTime += dt
            b.sessionState = sessionStateProvider?(b.id) ?? .none
            if let t = sessionTitleProvider?(b.id) {
                b.topic = t
                if !b.titleLocked && !b.titleFromClaude && !b.isConductor && b.title != nil {
                    b.title = Self.clipTitle(t)
                    b.titleFromClaude = true
                }
            }
            if let info = launchInfoProvider?(b) {
                b.dirName = info.0
                if info.1.boxed != b.sandboxMode.boxed { b.domeTime = time }
                b.sandboxMode = info.1
                b.usesWorktree = info.2
                b.dirMismatch = info.3
            }
            if b.status == .received && b.statusTime > 2.5 {
                b.status = .idle
                b.statusTime = 0
            }
            if !b.pending.isEmpty { b.glow = max(b.glow, 0.55) }
            if let badge = b.badge, badge.kind.needsAttention, !b.grabbed, time - b.lastHop > 3.2 {
                b.lastHop = time
                if b.homeTarget == nil {
                    if let r = b.restSpot, len(r - b.com) < 40 { b.homeTarget = r } else { b.homeTarget = b.com }
                }
                b.kick(2.2)
                for i in 0..<b.n { b.v[i] += V2(0, -150) }
                b.computeCom()
                b.glow = max(b.glow, 0.6)
            }
            b.face.update(b, world: self, dt: dt)
            let runTarget: Float = b.sessionState == .busy ? 1 : 0
            b.running += (runTarget - b.running) * min(1, dt * 3)
        }
    }

    // MARK: - Messaging

    func rope(from: Int, to: Int) -> Rope? {
        ropes.first { $0.from == from && $0.to == to && !$0.retracting }
    }

    func outgoing(_ id: Int) -> [SoftBody] {
        ropes.filter { $0.from == id && !$0.retracting }.compactMap { $0.to.flatMap(body) }
    }

    func incoming(_ id: Int) -> [SoftBody] {
        ropes.filter { $0.to == id && !$0.retracting }.compactMap { body($0.from) }
    }

    func bodyNamed(_ raw: String) -> SoftBody? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("@") { name.removeFirst() }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if let b = bodies.first(where: { $0.name == name && $0.absorbInto == nil }) { return b }
        return bodies.filter { b in
            guard b.absorbInto == nil, name.hasPrefix(b.name) else { return false }
            let rest = name.dropFirst(b.name.count)
            guard let c = rest.first else { return true }
            return !(c.isLetter || c.isNumber || c == "-" || c == "_")
        }.max { $0.name.count < $1.name.count }
    }

    var onBadge: ((SoftBody, Badge) -> Void)?

    func setBadge(_ b: SoftBody, _ kind: BadgeKind, summary: String = "") {
        if let cur = b.badge, cur.kind == kind, cur.summary == summary { return }
        let badge = Badge(kind: kind, time: time, summary: summary)
        b.badge = badge
        b.lastHop = time
        b.kick(kind.needsAttention ? 4 : 3)
        b.glow = 1
        onBadge?(b, badge)
    }

    func clearBadge(_ b: SoftBody, onlyAttention: Bool = false) {
        guard let cur = b.badge else { return }
        if onlyAttention && !cur.kind.needsAttention { return }
        b.badge = nil
    }

    func addPending(_ p: PendingSend, to b: SoftBody) {
        b.pending.append(p)
        b.statusTime = 0
        b.kick(3)
        b.glow = 1
    }

    func launchDroplet(from: Int, to: Int) {
        guard let r = rope(from: from, to: to), let a = body(from) else { return }
        droplets.append(Droplet(ropeId: r.id, targetId: to, color: a.template.color))
        for i in 0..<a.n { a.v[i] += norm(r.pts[2] - a.com) * 60 }
        a.kick(2)
    }

    func choose(_ b: SoftBody, _ index: Int) {
        guard let p = b.pending.first else { return }
        b.pending.removeFirst()
        b.statusTime = 0
        b.kick(2)
        p.resolve(index == 0)
    }

    func restoreBody(template: Template, name: String, at p: V2) -> SoftBody {
        let b = SoftBody(id: nextId, template: template, name: uniqueName(name), center: p, radius: bubbleR)
        nextId += 1
        b.scale = 0.2
        b.scaleV = 3
        b.islandId = islandAt(p)?.id
        bodies.append(b)
        return b
    }

    @discardableResult
    func spawnBody(templateId: String, at p: V2) -> SoftBody? {
        guard let lump = lump(templateId) else { return nil }
        let b = SoftBody(id: nextId, template: lump.template, name: World.sessionName(lump.template.name), center: p, radius: bubbleR)
        nextId += 1
        bodies.append(b)
        return b
    }

    @discardableResult
    func connect(_ a: SoftBody, _ b: SoftBody) -> Rope {
        let r = Rope(id: nextId, from: a.id, start: a.com)
        nextId += 1
        r.to = b.id
        ropes.append(r)
        return r
    }

    func requestRemove(_ b: SoftBody) {
        if b.isConductor { return }
        if shouldConfirmRemove?(b) == true {
            for i in 0..<b.n { b.v[i] += V2(0, 900) }
            b.kick(3)
            onConfirmRemove?(b)
        } else {
            remove(b)
        }
    }

    func remove(_ b: SoftBody) {
        var best: String?
        var bestD: Float = .infinity
        for l in lumps {
            let same: Float = l.template.id == b.template.id ? 0 : 100000
            let d = len(l.com - b.com) + same
            if d < bestD { bestD = d; best = l.template.id }
        }
        b.absorbInto = best ?? "__none__"
        b.grabbed = false
        b.scaleTarget = 0
        for p in b.pending { p.resolve(false) }
        b.pending = []
        for other in bodies {
            let doomed = other.pending.filter { $0.targetId == b.id }
            for p in doomed { p.resolve(false) }
            other.pending.removeAll { $0.targetId == b.id }
        }
        for r in ropes where r.from == b.id || r.to == b.id {
            r.free = r.pts.last ?? r.free
            if r.from == b.id { r.alpha = 0 }
            r.retracting = true
        }
    }

    func removeRope(_ r: Rope) {
        r.free = r.pts.last ?? r.free
        r.retracting = true
    }

    // MARK: - Hit testing

    func bodyAt(_ p: V2, slack: Float = 1.05) -> SoftBody? {
        var best: SoftBody?
        var bestD: Float = .infinity
        for b in bodies where b.absorbInto == nil {
            let d = len(p - b.com)
            if d < b.radius * b.scale * slack && d < bestD { best = b; bestD = d }
        }
        if let best, slack > 1.1 {
            let d = len(p - best.com)
            if d > best.radius * best.scale * 1.05 && best.knob < 0.05 && !(hoverBody == best.id) { return nil }
        }
        return best
    }

    func lumpAt(_ p: V2) -> String? {
        for l in lumps {
            if len(p - l.com) < l.radius * 1.15 { return l.template.id }
            if p.y < bandY + 4 && abs(p.x - l.anchor.x) < l.radius * 0.9 { return l.template.id }
        }
        return nil
    }

    func ropeAt(_ p: V2) -> Rope? {
        ropes.first { !$0.retracting && $0.to != nil && $0.distance(to: p) < 9 }
    }

    func pillLayout(_ b: SoftBody) -> [PillLayout] {
        guard let p = b.pending.first else { return [] }
        let items: [(String, String, V3, Bool)] = p.approvalTitle == nil ? [
            ("\(p.targetName) に送る", "paperplane.fill", p.color, true),
            ("止める", "hand.raised.fill", V3(0.5, 0.52, 0.6), false),
        ] : [
            ("許可する", "checkmark.shield.fill", V3(0.95, 0.55, 0.3), false),
            ("止める", "hand.raised.fill", V3(0.5, 0.52, 0.6), true),
        ]
        var out: [PillLayout] = []
        let r = CGFloat(b.radius * b.scale), cy = CGFloat(b.com.y)
        let block = CGFloat(items.count) * 34 - 6
        let below = cy + r + 96
        let above = cy - r - 14 - block
        var y = below
        let vis = visibleRect
        if below + block > vis.maxY - 8 {
            y = above - 82 >= vis.minY ? above : vis.maxY - 8 - block
        }
        for (i, it) in items.enumerated() {
            let w = (it.0 as NSString).size(withAttributes: [.font: World.pillFont]).width + 16 + 6 + 28
            let cx = min(max(CGFloat(b.com.x), vis.minX + w / 2 + 8), vis.maxX - w / 2 - 8)
            let rect = CGRect(x: cx - w / 2, y: y, width: w, height: 28)
            out.append(PillLayout(rect: rect, text: it.0, icon: it.1, color: it.2, recommended: it.3, index: i))
            y += 34
        }
        return out
    }

    func pillAt(_ p: V2) -> (Int, Int)? {
        let pt = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        for b in bodies where !b.pending.isEmpty {
            for pl in pillLayout(b) where pl.rect.insetBy(dx: -2, dy: -2).contains(pt) {
                return (b.id, pl.index)
            }
        }
        return nil
    }

    var cursor: CursorKind {
        switch dragMode {
        case .body, .pull: return .closedHand
        case .rope: return .crosshair
        case .island: return .closedHand
        case .islandResize: return .crosshair
        case .pan: return .closedHand
        case .none: break
        }
        if hoverPill != nil { return .pointingHand }
        if let id = hoverBody, let b = body(id) {
            return knobHit(b, mouse) ? .crosshair : .pointingHand
        }
        if hoverLump != nil { return .openHand }
        if islands.contains(where: { $0.inCorner(mouse) }) { return .crosshair }
        if islands.contains(where: { $0.inHeader(mouse) }) { return .openHand }
        return .arrow
    }

    private func knobHit(_ b: SoftBody, _ p: V2) -> Bool {
        b.knob > 0.3 && len(p - b.knobPosition) < 20
    }

    // MARK: - Input

    func mouseMoved(_ s: V2) {
        mouseScreen = s
        mouse = s.x > -999 ? toWorld(s) : s
    }

    func mouseDown(_ s: V2) {
        let p = toWorld(s)
        mouse = p
        lastMouse = p
        mouseVel = V2(0, 0)
        mouseScreen = s
        lastMouseScreen = s
        mouseScreenVel = V2(0, 0)
        mouseIsDown = true
        downTime = time
        downScreen = s
        if let (bid, idx) = pillAt(p), let b = body(bid) {
            choose(b, idx)
            dragMode = .none
            return
        }
        if let b = bodyAt(p, slack: 1.6), !b.isConductor, b.engine == .claude, knobHit(b, p) {
            let r = Rope(id: nextId, from: b.id, start: b.knobPosition)
            nextId += 1
            r.free = p
            ropes.append(r)
            dragMode = .rope(r.id)
            return
        }
        if let b = bodyAt(p) {
            if !b.isConductor {
                b.homeTarget = nil
                b.destIslandId = nil
            }
            b.startGrab(at: p)
            dragMode = .body(b.id)
            return
        }
        if let l = lumpAt(s), let lump = lump(l) {
            let base = lump.tip(toward: V2(0, 1))
            pull = Pull(lumpId: l, proto: base, protoV: V2(0, 0))
            dragMode = .pull
            return
        }
        if let i = islands.last(where: { $0.inCorner(p) }) {
            dragMode = .islandResize(i.id)
            return
        }
        if let i = islands.last(where: { $0.inHeader(p) }) {
            dragMode = .island(i.id, bodiesInside(i))
            return
        }
        dragMode = .pan(s, camera)
    }

    func mouseDragged(_ s: V2) {
        if case .pan(let start, let cam) = dragMode {
            camera = cam - (s - start) / zoom
            mouseScreen = s
            mouse = toWorld(s)
            return
        }
        let p = toWorld(s)
        let delta = p - mouse
        mouse = p
        mouseScreen = s
        if case .island(let iid, let members) = dragMode, let i = island(iid) {
            i.rect = i.rect.offsetBy(dx: CGFloat(delta.x), dy: CGFloat(delta.y))
            for id in members {
                guard let b = body(id) else { continue }
                for k in 0..<b.n { b.x[k] += delta }
                if let h = b.homeTarget { b.homeTarget = h + delta }
                b.computeCom()
            }
        }
        if case .islandResize(let iid) = dragMode, let i = island(iid) {
            let w = max(260, CGFloat(p.x) - i.rect.minX)
            let h = max(170, CGFloat(p.y) - i.rect.minY)
            i.rect = CGRect(x: i.rect.minX, y: i.rect.minY, width: w, height: h)
        }
        if case .rope(let rid) = dragMode, let r = ropes.first(where: { $0.id == rid }) {
            r.free = p
        }
    }

    func mouseUp(_ s: V2) {
        let p = toWorld(s)
        mouse = p
        mouseScreen = s
        mouseIsDown = false
        let isTap = (time - downTime) < 0.3 && len(s - downScreen) < 5
        let mode = dragMode
        dragMode = .none
        switch mode {
        case .body(let id):
            if let b = body(id) {
                b.grabbed = false
                b.computeCom()
                let throwV = clampLen(mouseVel, 2600) * 0.85
                for i in 0..<b.n { b.v[i] = (b.v[i] - b.vcom) + throwV }
                if isTap {
                    b.kick(5)
                    onOpenBody?(b)
                } else if b.isConductor {
                    conductorSpot = b.com
                    b.homeTarget = conductorHome
                    b.kick(3)
                } else if toScreen(b.com).y < bandY + lumpR * 2.2 && !b.isConductor {
                    requestRemove(b)
                }
            }
        case .pull:
            let lid = pull?.lumpId
            cancelPull()
            if isTap, let lid {
                lump(lid)?.kick(4)
                onEditTemplate?(lid)
            }
        case .rope(let rid):
            if let r = ropes.first(where: { $0.id == rid }) {
                if let t = bodyAt(p, slack: 1.15), t.id != r.from, !t.isConductor, t.engine != .claude {
                    r.retracting = true
                    t.kick(2.5)
                    t.face.surprise = 0.6
                } else if let t = bodyAt(p, slack: 1.15), t.id != r.from, !t.isConductor,
                   !ropes.contains(where: { $0.id != r.id && $0.from == r.from && $0.to == t.id && !$0.retracting }) {
                    r.to = t.id
                    t.kick(3)
                    let push = norm(t.com - p) * 120
                    for i in 0..<t.n { t.v[i] += push }
                } else {
                    r.retracting = true
                }
            }
        case .island, .islandResize:
            onIslandsChanged?()
        case .pan, .none:
            break
        }
    }

    func cancelInteraction() {
        if case .pull = dragMode { cancelPull() }
        if case .body(let id) = dragMode { body(id)?.grabbed = false }
        if case .rope(let rid) = dragMode { ropes.first { $0.id == rid }?.retracting = true }
        dragMode = .none
        mouseIsDown = false
    }

    func menuTarget(at p: V2) -> (SoftBody?, Rope?) {
        if let b = bodyAt(p) { return (b, nil) }
        return (nil, ropeAt(p))
    }
}
