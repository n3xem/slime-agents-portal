import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ScriptStep {
    case move(V2)
    case down(V2)
    case drag(from: V2, to: V2, duration: Float)
    case up
    case capture(String)
    case wait(Float)
    case pill(String, Int)
}

@MainActor
final class SnapshotRunner {
    let world = World(templates: TemplateStore(persistent: false).templates.map(\.runtime))
    let renderer: Renderer
    let outDir: URL
    let scale: Float = 2

    init(outDir: URL) {
        ClaudeSessionRegistry.enabled = false
        self.outDir = outDir
        renderer = Renderer(device: MTLCreateSystemDefaultDevice()!, format: .bgra8Unorm)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    private func advance(_ seconds: Float) {
        var t: Float = 0
        while t < seconds {
            world.update(dt: 1.0 / 60.0)
            t += 1.0 / 60.0
        }
    }

    private func dragTo(_ from: V2, _ to: V2, _ duration: Float) {
        let frames = max(1, Int(duration * 60))
        for i in 1...frames {
            let t = Float(i) / Float(frames)
            let e = t * t * (3 - 2 * t)
            world.mouseDragged(mixv(from, to, e))
            world.update(dt: 1.0 / 60.0)
        }
    }

    private func body(named name: String) -> SoftBody? { world.bodies.first { $0.name == name } }

    func pullOut(_ lump: Int, to: V2) {
        let l = world.lumps[lump]
        let start = l.com + V2(0, 10)
        world.mouseMoved(start)
        advance(0.1)
        world.mouseDown(start)
        dragTo(start, to, 0.7)
        advance(0.15)
        world.mouseUp(to)
        advance(0.5)
    }

    func connect(_ a: String, _ b: String) {
        guard let s = body(named: a), let t = body(named: b) else { return }
        let dir = norm(t.com - s.com)
        let hover = s.com + dir * s.radius * 0.9
        world.mouseMoved(hover)
        advance(0.35)
        let kp = s.knobPosition
        world.mouseDown(kp)
        dragTo(kp, t.com, 0.5)
        world.mouseUp(t.com)
        world.mouseMoved(V2(-1000, -1000))
        advance(0.4)
    }

    func capture(_ name: String) {
        guard let base = renderer.renderImage(world: world, scale: scale) else { return }
        let overlay = OverlayView(world: world, tick: Double(world.time))
        let ir = ImageRenderer(content: overlay)
        ir.scale = CGFloat(scale)
        let w = base.width, h = base.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let ov = ir.cgImage {
            ctx.draw(ov, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        guard let img = ctx.makeImage() else { return }
        let url = outDir.appendingPathComponent(name + ".png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        print("wrote \(url.path)")
    }

    func run() {
        world.layout(size: V2(1440, 900))
        world.syncTemplates(TemplateStore(persistent: false).templates.map { t -> Template in
            var r = t.runtime
            if t.id == "release" { r.engine = .agy }
            return r
        })
        world.addIsland(path: "/Users/example/workspace/todo-web", rect: CGRect(x: 250, y: 250, width: 930, height: 520))
        world.addIsland(path: "/Users/example/ghq/github.com/example/todo-api", rect: CGRect(x: 1200, y: 170, width: 220, height: 300))
        let store = TemplateStore(persistent: false)
        let mgr = SessionManager(server: nil)
        world.launchInfoProvider = { b in
            let cfg = mgr.launchConfig(for: b, store: store)
            let dir = b.isConductor ? "workspace" : (self.world.islandAt(b.com)?.name ?? "workspace")
            return (dir, b.name == "実装" ? .on : cfg.sandbox, b.name == "実装", false)
        }
        advance(0.6)
        capture("00_idle")

        let l0 = world.lumps[0]
        let start = l0.com + V2(0, 10)
        world.mouseMoved(start)
        advance(0.1)
        world.mouseDown(start)
        dragTo(start, start + V2(40, 120), 0.5)
        advance(0.05)
        capture("01_pull")
        dragTo(start + V2(40, 120), V2(380, 430), 0.25)
        advance(0.03)
        capture("02_snap")
        advance(0.15)
        world.mouseUp(V2(380, 430))
        advance(0.6)

        pullOut(1, to: V2(720, 380))
        pullOut(2, to: V2(1080, 440))
        pullOut(3, to: V2(760, 690))
        advance(0.6)

        connect("実装", "レビュー")
        connect("レビュー", "検証")
        connect("レビュー", "実装")
        connect("検証", "E2Eテスト")
        advance(1.0)
        if let r = body(named: "レビュー"), let t = body(named: "実装"), let rope = world.rope(from: r.id, to: t.id) {
            world.addPending(PendingSend(targetId: t.id, targetName: t.name, ropeId: rope.id,
                                         message: "ブランチ feat/todo-reminder のレビューで指摘が 3 件あります。PR の 2 件目のコメント（テスト不足）を優先して直してください。",
                                         summary: "レビュー指摘の修正依頼", color: t.template.color) { _ in }, to: r)
        }
        if let b = body(named: "実装") {
            b.topic = "期限が近いタスクの通知"
            b.activity = Activity(text: "編集: ReminderService.swift", symbol: "pencil", time: world.time)
        }
        if let b = body(named: "検証") {
            b.activity = Activity(text: "実行: npm test -- reminder", symbol: "terminal.fill", time: world.time)
            world.setBadge(b, .needDecision, summary: "本番の feature flag を先に有効にしてよいか")
        }
        if let b = body(named: "E2Eテスト") {
            world.setBadge(b, .done, summary: "E2E テスト 42 件すべて成功")
            b.activity = Activity(text: "E2E テスト 42 件すべて成功", symbol: "checkmark.circle.fill", time: world.time, finished: true)
        }
        advance(0.8)
        capture("03_overview")

        if let r = body(named: "レビュー"), let pl = world.pillLayout(r).first {
            let p = V2(Float(pl.rect.midX), Float(pl.rect.midY))
            world.mouseMoved(p)
            advance(0.05)
            world.mouseDown(p)
            world.mouseUp(p)
        }
        advance(0.55)
        capture("04_message")

        if let b = body(named: "検証") {
            let p = b.com
            world.mouseMoved(p)
            advance(0.05)
            world.mouseDown(p)
            dragTo(p, p + V2(-260, 80), 0.18)
            capture("05_fling")
            world.mouseUp(p + V2(-260, 80))
            advance(0.12)
            capture("06_after_fling")
        }
        advance(2.0)
        capture("07_settled")
        if let isl = world.islands.first {
            world.spawnFromLump(templateId: "release", name: nil, near: V2(900, 640), in: isl)
            var t: Float = 0
            var entered = false
            while t < 3 {
                world.update(dt: 1.0 / 60.0)
                t += 1.0 / 60.0
                if !entered, world.bodies.last?.islandId != nil {
                    entered = true
                    advance(0.12)
                    capture("08_enter_a")
                    advance(0.28)
                    capture("08_enter_b")
                }
            }
            world.removeIsland(isl)
            advance(0.1)
            capture("09_pop_a")
            advance(0.18)
            capture("09_pop_b")
            advance(0.15)
            capture("09_pop_c")
            advance(0.4)
            capture("09_pop_d")
        }
        if let c = world.conductor {
            let p = c.com
            let to = V2(world.size.x * 0.5, world.size.y * 0.62)
            world.mouseMoved(p)
            advance(0.05)
            world.mouseDown(p)
            dragTo(p, to, 0.6)
            world.mouseUp(to)
            advance(2.5)
            capture("10_conductor_moved")
            c.speech = Speech(text: "Slack に返事をしていない依頼が 2 件あります。1 件は今日が期限です", time: world.time)
            advance(0.8)
            capture("10_speech")
            c.speech = nil
        }
        if let b = body(named: "E2Eテスト") {
            world.addPending(PendingSend(targetId: b.id, targetName: b.displayName, ropeId: -1,
                                         message: "権限モード: 既定（ユーザー設定に従う） → bypassPermissions（確認なし）\nサンドボックス: オン → オフ",
                                         summary: "", color: V3(0.95, 0.55, 0.3),
                                         approvalTitle: "管理が「\(b.displayName)」の設定を緩めようとしています") { _ in }, to: b)
            advance(0.6)
            capture("12_approval")
            world.choose(b, 1)
            let q = PendingSend(targetId: b.id, targetName: b.displayName, ropeId: -1,
                                message: "失敗している 3 件のテストは、今回の変更と関係なさそうです。直してから進めますか？",
                                summary: "失敗中のテスト", color: b.template.color) { _ in }
            q.options = [("直してから進める (Recommended)", "3 件を先に直し、すべて通ってからレビューへ送ります"),
                         ("このまま進める", "失敗はレビューの依頼に書き添えます")]
            q.onPick = { _ in }
            world.addPending(q, to: b)
            advance(0.6)
            capture("12_question")
            world.choose(b, 0)
        }
        world.zoom(by: 0.6, around: V2(720, 520))
        advance(0.4)
        capture("13_zoom_out")
        pullOut(0, to: V2(300, 640))
        advance(1.2)
        capture("13_zoom_pull")
        world.resetView()
        world.zoom(by: 1.7, around: V2(1000, 700))
        advance(0.4)
        capture("13_zoom_in")
        let s0 = V2(160, 220)
        world.mouseMoved(s0)
        advance(0.05)
        world.mouseDown(s0)
        dragTo(s0, s0 + V2(320, 160), 0.4)
        world.mouseUp(s0 + V2(320, 160))
        advance(0.4)
        capture("13_pan")
        world.resetView()
        if let fixed = world.islands.first {
            let r = fixed.rect
            let other = world.addIsland(path: "/Users/example/workspace/other", rect: CGRect(x: r.minX - 280, y: r.minY + 80, width: 420, height: 300))
            world.spawnFromLump(templateId: "impl", name: nil, near: V2(Float(other.rect.midX), Float(other.rect.midY)), in: other)
            advance(0.05)
            capture("11_overlap_a")
            advance(1.0)
            capture("11_overlap_b")
            let grab = V2(Float(other.rect.minX + 60), Float(other.rect.minY + 12))
            let to = grab + V2(Float(fixed.rect.midX - other.rect.midX), 40)
            world.mouseMoved(grab)
            world.mouseDown(grab)
            dragTo(grab, to, 0.8)
            capture("11_overlap_c")
            world.mouseUp(to)
            advance(1.2)
            capture("11_overlap_d")
        }
    }
}
