import Foundation

struct SavedSession: Codable, Equatable {
    var sessionId: String
    var workdir: String
    var sandbox: SandboxMode
    var permissionMode: String
    var worktree: Bool
    var chrome: Bool?
    var engine: Engine?
    var model: String?
    var effort: String?

    var launchConfig: LaunchConfig {
        LaunchConfig(workdir: workdir, sandbox: sandbox, permissionMode: permissionMode, worktree: worktree, chrome: chrome, conductorMCP: nil,
                     model: model, effort: effort, engine: engine ?? .claude)
    }
}

struct SavedBubble: Codable, Equatable {
    var name: String
    var templateId: String
    var templateName: String
    var symbol: String
    var color: [Float]
    var x: Float
    var y: Float
    var conductor: Bool
    var workdir: String?
    var sandbox: SandboxMode?
    var permissionMode: String?
    var worktree: Bool?
    var chrome: Bool?
    var chromeSet: Bool?
    var session: SavedSession?
    var title: String?
    var titleLocked: Bool?
    var faceStyle: FaceStyle?
    var placed: Bool?
    var costume: Costume?
}

struct SavedRope: Codable, Equatable {
    var from: String
    var to: String
    var autoSend: Bool
}

struct SavedCanvas: Codable, Equatable {
    var bubbles: [SavedBubble]
    var ropes: [SavedRope]
    var view: [Float]?
}

final class CanvasStore {
    private let url: URL?
    private var lastData: Data?

    init(store: TemplateStore) {
        url = store.baseURL?.appendingPathComponent("canvas.json")
    }

    init(url: URL) {
        self.url = url
    }

    func load() -> SavedCanvas? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        lastData = data
        return try? JSONDecoder().decode(SavedCanvas.self, from: data)
    }

    func save(world: World) {
        guard let url else { return }
        let bubbles = world.bodies.filter { $0.absorbInto == nil }.map { b -> SavedBubble in
            let c = b.template.color
            return SavedBubble(name: b.name, templateId: b.template.id, templateName: b.template.name, symbol: b.template.symbol,
                               color: [c.x, c.y, c.z], x: b.homeTarget?.x ?? b.com.x, y: b.homeTarget?.y ?? b.com.y,
                               conductor: b.isConductor, workdir: b.config.workdir, sandbox: b.config.sandbox,
                               permissionMode: b.config.permissionMode, worktree: b.config.worktree,
                               chrome: b.config.chrome ?? nil, chromeSet: b.config.chrome != nil, session: b.savedSession,
                               title: b.title, titleLocked: b.titleLocked, faceStyle: b.faceStyle,
                               placed: b.isConductor && world.conductorSpot != nil ? true : nil,
                               costume: b.dressTime != nil ? b.nextCostume : b.costume)
        }
        let ropes = world.ropes.filter { !$0.retracting && $0.to != nil }.compactMap { r -> SavedRope? in
            guard let a = world.body(r.from), let t = r.to.flatMap(world.body) else { return nil }
            return SavedRope(from: a.name, to: t.name, autoSend: r.autoSend)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(SavedCanvas(bubbles: bubbles, ropes: ropes, view: [world.camera.x, world.camera.y, world.zoom])), data != lastData else { return }
        lastData = data
        try? data.write(to: url, options: .atomic)
    }

    static func restore(_ canvas: SavedCanvas, into world: World) {
        if let v = canvas.view, v.count == 3, v[2] > 0 {
            world.camera = V2(v[0], v[1])
            world.zoom = clampf(v[2], 0.25, 2.5)
        }
        for sb in canvas.bubbles {
            let b: SoftBody
            if sb.conductor {
                guard let c = world.conductor else { continue }
                b = c
                if sb.placed == true { world.placeConductor(at: V2(sb.x, sb.y)) }
            } else {
                let tpl = world.lump(sb.templateId)?.template
                    ?? Template(id: sb.templateId, name: sb.templateName, symbol: sb.symbol,
                                color: sb.color.count == 3 ? V3(sb.color[0], sb.color[1], sb.color[2]) : V3(0.6, 0.6, 0.6))
                b = world.restoreBody(template: tpl, name: sb.name, at: V2(sb.x, sb.y))
            }
            b.config = BubbleConfig(workdir: sb.workdir, sandbox: sb.sandbox, permissionMode: sb.permissionMode, worktree: sb.worktree,
                                    chrome: sb.chromeSet == true ? .some(sb.chrome) : nil)
            b.savedSession = sb.session
            b.title = sb.title
            b.titleLocked = sb.titleLocked ?? false
            b.titleFromClaude = sb.title != nil
            if let style = sb.faceStyle { b.faceStyle = style }
            if !b.isConductor { b.costume = sb.costume }
        }
        for r in canvas.ropes {
            guard let a = world.bodies.first(where: { $0.name == r.from }),
                  let t = world.bodies.first(where: { $0.name == r.to }), a.engine == .claude, t.engine == .claude else { continue }
            let rope = world.connect(a, t)
            rope.autoSend = r.autoSend
        }
    }

    static func transcriptExists(_ sessionId: String) -> Bool {
        transcriptPath(sessionId) != nil
    }

    static func transcriptPath(_ sessionId: String) -> String? {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return nil }
        for d in dirs {
            let path = base.appendingPathComponent("\(d)/\(sessionId).jsonl").path
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }
}
