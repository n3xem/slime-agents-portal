import AppKit
import MetalKit
import SwiftUI

var sharedSaveCanvas: (() -> Void)?

final class FrameClock: ObservableObject {
    @Published var frame: Int = 0
}

let sharedFrameClock = FrameClock()

struct FrameSyncedOverlay: View {
    let world: World
    @ObservedObject var clock: FrameClock

    var body: some View {
        OverlayView(world: world, tick: Double(clock.frame))
            .id(clock.frame)
    }
}

final class SlimeMTKView: MTKView, MTKViewDelegate {
    let world: World
    let renderer: Renderer
    private var lastTime = CACurrentMediaTime()
    private var tracking: NSTrackingArea?
    private var menuBody: SoftBody?
    private var menuRope: Rope?

    init(world: World) {
        self.world = world
        let device = MTLCreateSystemDefaultDevice()!
        self.renderer = Renderer(device: device, format: .bgra8Unorm)
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = 120
        delegate = self
    }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func point(_ e: NSEvent) -> V2 {
        let p = convert(e.locationInWindow, from: nil)
        return V2(Float(p.x), Float(p.y))
    }

    override func mouseMoved(with event: NSEvent) { world.mouseMoved(point(event)) }
    override func mouseExited(with event: NSEvent) { world.mouseMoved(V2(-1000, -1000)) }
    override func mouseDown(with event: NSEvent) { world.mouseDown(point(event)) }
    override func mouseDragged(with event: NSEvent) { world.mouseDragged(point(event)) }
    override func mouseUp(with event: NSEvent) { world.mouseUp(point(event)) }

    override func magnify(with event: NSEvent) {
        world.zoom(by: 1 + Float(event.magnification), around: point(event))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            world.pan(byScreen: V2(Float(event.scrollingDeltaX), Float(event.scrollingDeltaY)))
        } else {
            let dy = Float(event.scrollingDeltaY)
            guard dy != 0 else { return }
            let step: Float = event.hasPreciseScrollingDeltas ? 1 + dy * 0.01 : (dy > 0 ? 1.1 : 1 / 1.1)
            world.zoom(by: step, around: point(event))
        }
    }

    var configMenu: ((SoftBody, NSMenu) -> Void)?
    var canvasMenu: ((V2, Island?, NSMenu) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let (b, r) = world.menuTarget(at: world.toWorld(point(event)))
        menuBody = b
        menuRope = r
        let m = NSMenu()
        if let b {
            m.addItem(withTitle: b.title.map { "\($0)（宛先: \(b.name)）" } ?? b.name, action: nil, keyEquivalent: "").isEnabled = false
            m.addItem(.separator())
            m.addItem(withTitle: "ターミナルを開く", action: #selector(menuOpen), keyEquivalent: "").target = self
            if !b.isConductor {
                m.addItem(withTitle: "名前を変える…", action: #selector(menuRename), keyEquivalent: "").target = self
            }
            configMenu?(b, m)
            if !b.isConductor {
                m.addItem(.separator())
                m.addItem(withTitle: "スライムに戻す", action: #selector(menuRemove), keyEquivalent: "").target = self
            }
            return m
        }
        if r != nil {
            let auto = m.addItem(withTitle: "承認なしで送る", action: #selector(menuToggleAuto), keyEquivalent: "")
            auto.target = self
            auto.state = r!.autoSend ? .on : .off
            m.addItem(.separator())
            m.addItem(withTitle: "矢印を外す", action: #selector(menuRemoveRope), keyEquivalent: "").target = self
            return m
        }
        let p = world.toWorld(point(event))
        canvasMenu?(p, world.islandAt(p), m)
        return m.items.isEmpty ? nil : m
    }

    @objc private func menuRename() {
        guard let b = menuBody else { return }
        let alert = NSAlert()
        alert.messageText = "バブルの名前"
        alert.informativeText = "画面に表示する名前です。メッセージの宛先（\(b.name)）は変わりません。空にすると、次の依頼から自動で付けます。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = b.title ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            b.title = t.isEmpty ? nil : t
            b.titleLocked = !t.isEmpty
            b.titleFromClaude = false
            b.kick(3)
        }
    }

    @objc private func menuToggleAuto() { if let r = menuRope { r.autoSend.toggle() } }
    @objc private func menuRemove() { if let b = menuBody { world.requestRemove(b) } }
    @objc private func menuOpen() { if let b = menuBody { world.onOpenBody?(b) } }
    @objc private func menuRemoveRope() { if let r = menuRope { world.removeRope(r) } }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(now - lastTime)
        lastTime = now
        let sz = V2(Float(bounds.width), Float(bounds.height))
        if sz.x > 10 && sz.y > 10 && sz != world.size { world.layout(size: sz) }
        world.update(dt: dt)
        sharedFrameClock.frame &+= 1
        let waiting = world.bodies.filter { $0.badge?.kind.needsAttention == true }.count
        let label = waiting > 0 ? "\(waiting)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
        switch world.cursor {
        case .arrow: NSCursor.arrow.set()
        case .openHand: NSCursor.openHand.set()
        case .closedHand: NSCursor.closedHand.set()
        case .crosshair: NSCursor.crosshair.set()
        case .pointingHand: NSCursor.pointingHand.set()
        }
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let cb = renderer.queue.makeCommandBuffer() else { return }
        let scale = Float(window?.backingScaleFactor ?? 2)
        renderer.encode(world: world, pass: pass, commandBuffer: cb, scale: scale)
        cb.present(drawable)
        cb.commit()
    }
}

struct SlimeCanvas: NSViewRepresentable {
    let world: World
    let menus: BubbleMenuBuilder
    func makeNSView(context: Context) -> SlimeMTKView {
        let v = SlimeMTKView(world: world)
        updateNSView(v, context: context)
        return v
    }
    func updateNSView(_ nsView: SlimeMTKView, context: Context) {
        let menus = menus
        nsView.configMenu = { menus.build($0, into: $1) }
        nsView.canvasMenu = { menus.buildCanvas(at: $0, island: $1, into: $2) }
    }
}

final class BubbleMenuBuilder: NSObject {
    let world: World
    let sessions: SessionManager
    let store: TemplateStore

    init(world: World, sessions: SessionManager, store: TemplateStore) {
        self.world = world
        self.sessions = sessions
        self.store = store
    }

    private final class Payload: NSObject {
        let body: SoftBody
        let apply: (SoftBody) -> Void
        init(_ body: SoftBody, _ apply: @escaping (SoftBody) -> Void) {
            self.body = body
            self.apply = apply
        }
    }

    @objc private func applyItem(_ item: NSMenuItem) {
        guard let p = item.representedObject as? Payload else { return }
        p.apply(p.body)
        p.body.kick(2.5)
    }

    private func item(_ title: String, _ body: SoftBody, on: Bool = false, enabled: Bool = true,
                      _ apply: @escaping (SoftBody) -> Void) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: #selector(applyItem(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = Payload(body, apply)
        it.state = on ? NSControl.StateValue.on : NSControl.StateValue.off
        it.isEnabled = enabled
        return it
    }

    var onPickDirectory: ((DirectoryRequest) -> Void)?

    func applyDirectory(_ path: String, for req: DirectoryRequest) {
        if let iid = req.islandId, let i = world.island(iid) {
            i.path = path
            world.onIslandsChanged?()
        } else if let pt = req.point {
            let r = CGRect(x: CGFloat(pt.x) - 300, y: CGFloat(pt.y) - 40, width: 600, height: 300)
            world.addIsland(path: path, rect: r)
        } else {
            world.addIsland(path: path)
        }
        store.noteRecent(path)
    }

    private final class DirectoryAction: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc private func runDirectoryAction(_ item: NSMenuItem) {
        (item.representedObject as? DirectoryAction)?.run()
    }

    func directoryItem(_ title: String, _ req: DirectoryRequest) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: #selector(runDirectoryAction(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = DirectoryAction { [weak self] in self?.onPickDirectory?(req) }
        return it
    }

    @objc private func revealIsland(_ item: NSMenuItem) {
        if let path = item.representedObject as? String { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    @objc private func resetView() { world.resetView() }

    @objc private func deleteIsland(_ item: NSMenuItem) {
        if let iid = item.representedObject as? Int, let i = world.island(iid) { world.removeIsland(i) }
    }

    func buildCanvas(at p: V2, island: Island?, into m: NSMenu) {
        if let island {
            let head = NSMenuItem(title: (island.path as NSString).abbreviatingWithTildeInPath, action: nil, keyEquivalent: "")
            head.isEnabled = false
            m.addItem(head)
            m.addItem(.separator())
            m.addItem(directoryItem("ディレクトリを変更…", DirectoryRequest(point: p, islandId: island.id, title: "島のディレクトリを変更")))
            let reveal = NSMenuItem(title: "Finder で開く", action: #selector(revealIsland(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = island.path
            m.addItem(reveal)
            m.addItem(.separator())
            let del = NSMenuItem(title: "島を消す（バブルは残る）", action: #selector(deleteIsland(_:)), keyEquivalent: "")
            del.target = self
            del.representedObject = island.id
            m.addItem(del)
        } else {
            m.addItem(directoryItem("ここに島を作る…", DirectoryRequest(point: p, islandId: nil, title: "ここに島を作る")))
            if world.zoom != 1 || world.camera != V2(0, 0) {
                m.addItem(.separator())
                let reset = NSMenuItem(title: "表示を元に戻す（等倍）", action: #selector(resetView), keyEquivalent: "")
                reset.target = self
                m.addItem(reset)
            }
        }
    }

    func addIslandMenu(into m: NSMenu) {
        m.addItem(directoryItem("島を追加…", DirectoryRequest(point: nil, islandId: nil, title: "島を追加")))
    }

    func build(_ b: SoftBody, into m: NSMenu) {
        let cfg = sessions.existing(b.id)?.config ?? sessions.existingAgy(b.id)?.config ?? b.savedSession?.launchConfig
            ?? sessions.launchConfig(for: b, store: store)
        let started = sessions.isAlive(b.id)
        let locked = started || b.savedSession != nil
        let agy = b.engine == .agy
        m.addItem(.separator())
        let engineItem = NSMenuItem(title: "エンジン: " + b.engine.label + ((cfg.model ?? "").isEmpty ? "" : "（\(cfg.model!)）"),
                                    action: nil, keyEquivalent: "")
        engineItem.isEnabled = false
        m.addItem(engineItem)

        let dirTitle = "作業ディレクトリ: " + (cfg.workdir as NSString).abbreviatingWithTildeInPath
        if locked {
            let fixed = NSMenuItem(title: dirTitle + "（会話を引き継ぐため変更不可）", action: nil, keyEquivalent: "")
            fixed.isEnabled = false
            m.addItem(fixed)
        } else {
            m.addItem(item(dirTitle + "…", b) { body in
                if let p = chooseDirectory() { body.config.workdir = p }
            })
        }

        let sandbox = NSMenuItem(title: "サンドボックス: \(cfg.sandbox.short)", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        for mode in agy ? [SandboxMode.on, .off] : SandboxMode.allCases {
            sm.addItem(item(agy ? (mode == .on ? "オン（--sandbox）" : "オフ") : mode.label, b, on: cfg.sandbox == mode) { body in
                body.config.sandbox = mode
                body.savedSession?.sandbox = mode
            })
        }
        sandbox.submenu = sm
        m.addItem(sandbox)

        let perm = NSMenuItem(title: "権限モード: " + (cfg.permissionMode.isEmpty ? "既定" : cfg.permissionMode), action: nil, keyEquivalent: "")
        let pm = NSMenu()
        for mode in agy ? AgyModes.all : PermissionModes.all {
            pm.addItem(item(mode.label, b, on: cfg.permissionMode == mode.value) { body in
                body.config.permissionMode = mode.value
                body.savedSession?.permissionMode = mode.value
            })
        }
        perm.submenu = pm
        m.addItem(perm)

        if agy {
            appendCommon(b, into: m, started: started)
            return
        }
        let chromeTitle: String = {
            switch cfg.chrome {
            case .none: return "既定"
            case .some(true): return "オン"
            case .some(false): return "オフ"
            }
        }()
        let chromeItem = NSMenuItem(title: "Chrome 連携: " + chromeTitle, action: nil, keyEquivalent: "")
        let cm = NSMenu()
        for (label, value) in [("既定（指定しない）", Bool?.none), ("オン（--chrome）", Bool?.some(true)), ("オフ（--no-chrome）", Bool?.some(false))] {
            cm.addItem(item(label, b, on: cfg.chrome == value) { body in
                body.config.chrome = .some(value)
                body.savedSession?.chrome = value
            })
        }
        chromeItem.submenu = cm
        m.addItem(chromeItem)

        if !b.isConductor {
            m.addItem(item("worktree を作って起動する" + (locked ? "（変更不可）" : ""), b, on: cfg.worktree, enabled: !locked) {
                $0.config.worktree = !cfg.worktree
            })
        }
        appendCommon(b, into: m, started: started)
    }

    private func appendCommon(_ b: SoftBody, into m: NSMenu, started: Bool) {
        let faceItem = NSMenuItem(title: "顔: " + b.faceStyle.label, action: nil, keyEquivalent: "")
        let fm = NSMenu()
        for style in FaceStyle.allCases {
            fm.addItem(item(style.label, b, on: b.faceStyle == style) { body in
                body.faceStyle = style
                body.face.surprise = 0.7
                body.kick(2)
            })
        }
        faceItem.submenu = fm
        m.addItem(faceItem)

        let store = store, sessions = sessions
        if started {
            m.addItem(item("再起動して設定を反映（会話は引き継ぐ）", b) { body in sessions.restart(body, store: store) })
        } else if b.savedSession != nil {
            m.addItem(item("会話をリセット（次は新しい会話で起動）", b) { body in
                body.savedSession = nil
                if body.engine == .agy { sessions.terminate(body.id) }
            })
        }
    }
}

struct ContentView: View {
    let world: World
    @ObservedObject var store: TemplateStore
    @ObservedObject var sessions: SessionManager
    @StateObject private var ui = AppState()
    @State private var menuBuilder: BubbleMenuBuilder

    init(world: World, store: TemplateStore, sessions: SessionManager) {
        self.world = world
        self.store = store
        self.sessions = sessions
        _menuBuilder = State(initialValue: BubbleMenuBuilder(world: world, sessions: sessions, store: store))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                SlimeCanvas(world: world, menus: menuBuilder)
                FrameSyncedOverlay(world: world, clock: sharedFrameClock)
                    .allowsHitTesting(false)

                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Spacer()
                        Button {
                            openShell()
                        } label: {
                            RoundIcon(symbol: "terminal.fill")
                        }
                        .buttonStyle(.plain)
                        .help("ターミナルを開く")
                        Button {
                            let m = NSMenu()
                            menuBuilder.addIslandMenu(into: m)
                            m.addItem(.separator())
                            let add = PlusMenuAction { open(template: store.addTemplate(), size: geo.size) }
                            let item = NSMenuItem(title: "テンプレートを追加", action: #selector(PlusMenuAction.run), keyEquivalent: "")
                            item.target = add
                            item.representedObject = add
                            m.addItem(item)
                            if let ev = NSApp.currentEvent, let view = ev.window?.contentView {
                                NSMenu.popUpContextMenu(m, with: ev, for: view)
                            }
                        } label: {
                            RoundIcon(symbol: "plus")
                        }
                        .buttonStyle(.plain)
                        .help("島やテンプレートを追加")
                        SettingsLink {
                            RoundIcon(symbol: "gearshape.fill")
                        }
                        .buttonStyle(.plain)
                        .help("設定")
                    }
                }
                .padding(18)

                if ui.openBodyId != nil || ui.editingTemplateId != nil || ui.shellOpen || ui.dirRequest != nil {
                    Color.black.opacity(0.45)
                        .contentShape(Rectangle())
                        .onTapGesture { closePanels() }
                        .transition(.opacity)
                }

                if let id = ui.openBodyId, let s = sessions.existing(id) {
                    TerminalPanel(session: s, title: world.body(id)?.title, close: closePanels)
                        .padding(.horizontal, max(40, geo.size.width * 0.06))
                        .padding(.top, 100)
                        .padding(.bottom, 40)
                        .transition(.panel(anchor: ui.anchor))
                        .id(id)
                } else if let id = ui.openBodyId, let a = sessions.existingAgy(id) {
                    AgyPanel(session: a, title: world.body(id)?.title, close: closePanels)
                        .padding(.horizontal, max(40, geo.size.width * 0.06))
                        .padding(.top, 100)
                        .padding(.bottom, 40)
                        .transition(.panel(anchor: ui.anchor))
                        .id(id)
                }

                if let tid = ui.editingTemplateId {
                    TemplatePanel(store: store, id: tid, close: closePanels)
                        .frame(maxWidth: 860)
                        .padding(.top, 100)
                        .padding(.bottom, 40)
                        .padding(.horizontal, 40)
                        .frame(maxWidth: .infinity)
                        .transition(.panel(anchor: ui.anchor))
                        .id(tid)
                }

                if let req = ui.dirRequest {
                    DirectoryPicker(title: req.title, recent: store.settings.recentDirs ?? [],
                                    existing: Set(world.islands.map(\.path)),
                                    choose: { path in
                                        menuBuilder.applyDirectory(path, for: req)
                                        closePanels()
                                    },
                                    browse: {
                                        if let path = chooseDirectory() {
                                            menuBuilder.applyDirectory(path, for: req)
                                            closePanels()
                                        }
                                    },
                                    close: closePanels)
                        .frame(width: 660, height: min(560, geo.size.height - 160))
                        .padding(.top, 100)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .transition(.panel(anchor: ui.anchor))
                }

                if ui.shellOpen, let s = sessions.shell {
                    ShellPanel(session: s, close: closePanels)
                        .padding(.horizontal, max(40, geo.size.width * 0.06))
                        .padding(.top, 100)
                        .padding(.bottom, 40)
                        .transition(.panel(anchor: .bottomTrailing))
                }
            }
            .onAppear { wire(size: geo.size) }
            .onChange(of: geo.size) { _, s in wire(size: s) }
        }
        .ignoresSafeArea()
        .frame(minWidth: 1100, minHeight: 720)
        .background(Color(red: 0.05, green: 0.055, blue: 0.08))
        .onReceive(store.$templates) { list in
            world.syncTemplates(list.map(\.runtime))
            if let tid = ui.editingTemplateId, !list.contains(where: { $0.id == tid }) { ui.editingTemplateId = nil }
        }
    }

    private func anchor(_ p: V2, _ size: CGSize) -> UnitPoint {
        UnitPoint(x: CGFloat(p.x) / max(size.width, 1), y: CGFloat(p.y) / max(size.height, 1))
    }

    private func open(template id: String, size: CGSize) {
        world.cancelInteraction()
        if let l = world.lump(id) { ui.anchor = anchor(l.com, size) } else { ui.anchor = .top }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            ui.openBodyId = nil
            ui.shellOpen = false
            ui.dirRequest = nil
            ui.editingTemplateId = id
        }
    }

    private func openShell() {
        world.cancelInteraction()
        _ = sessions.shellSession(workdir: store.settings.defaultWorkdir)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            ui.openBodyId = nil
            ui.editingTemplateId = nil
            ui.dirRequest = nil
            ui.shellOpen = true
        }
    }

    private func closePanels() {
        let bodyId = ui.openBodyId
        let templateId = ui.editingTemplateId
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            if let id = bodyId, let b = world.body(id) {
                b.kick(3.5)
                for k in 0..<b.n { b.v[k] += norm(b.x[k] - b.com) * 140 }
            }
            if let tid = templateId { world.lump(tid)?.kick(3) }
        }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) {
            ui.openBodyId = nil
            ui.editingTemplateId = nil
            ui.shellOpen = false
            ui.dirRequest = nil
        }
    }

    private func openDirectoryPicker(_ req: DirectoryRequest, size: CGSize) {
        world.cancelInteraction()
        ui.anchor = req.point.map { anchor(world.toScreen($0), size) } ?? .bottomTrailing
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            ui.openBodyId = nil
            ui.editingTemplateId = nil
            ui.shellOpen = false
            ui.dirRequest = req
        }
    }

    private func wire(size: CGSize) {
        let sessions = sessions
        let store = store
        let world = world
        let bridge = FactoryBridge(world: world, sessions: sessions, store: store)
        sharedHookServer?.handler = { bridge.handle(token: $0, event: $1, body: $2, respond: $3) }
        let mcp = FactoryMCP(world: world, sessions: sessions, store: store)
        sharedHookServer?.mcpHandler = { mcp.handle(token: $0, method: $1, body: $2, reply: $3) }
        sessions.locationResolver = { b in
            if let i = world.islandAt(b.com) { return i.path }
            if let h = b.homeTarget, let i = world.islandAt(h) { return i.path }
            for up in world.incoming(b.id) {
                if let w = sessions.existing(up.id)?.config.workdir ?? up.config.workdir ?? world.islandAt(up.com)?.path { return w }
            }
            return nil
        }
        sessions.renameIfTaken = { b, taken in
            b.name = world.uniqueName(b.name, avoiding: taken, except: b)
        }
        sessions.onStarted = { s in
            if !s.isConductor { store.noteRecent(s.workdir) }
        }
        world.onIslandsChanged = { store.settings.islands = world.islands.map(\.model) }
        if !world.islandsLoaded {
            world.islandsLoaded = true
            for m in store.settings.islands ?? [] {
                world.addIsland(path: m.path, rect: CGRect(x: CGFloat(m.x), y: CGFloat(m.y), width: CGFloat(m.w), height: CGFloat(m.h)))
            }
            let canvas = CanvasStore(store: store)
            if let saved = canvas.load() { CanvasStore.restore(saved, into: world) }
            sharedSaveCanvas = { canvas.save(world: world) }
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in canvas.save(world: world) }
        }
        world.launchInfoProvider = { b in
            let running = sessions.existing(b.id)
            let cfg = running?.config ?? b.savedSession?.launchConfig ?? sessions.launchConfig(for: b, store: store)
            var mismatch = false
            if running != nil || b.savedSession != nil, !b.isConductor, let i = world.islandAt(b.com), i.path != cfg.workdir { mismatch = true }
            return ((cfg.workdir as NSString).lastPathComponent, cfg.sandbox, cfg.worktree, mismatch)
        }
        world.sessionTitleProvider = { id in
            guard let t = sessions.existing(id)?.title else { return nil }
            let cleaned = String(t.drop { !($0.isLetter || $0.isNumber) }).trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty || cleaned == "Claude Code" ? nil : cleaned
        }
        world.sessionStateProvider = { sessions.state($0) }
        world.shouldConfirmRemove = { sessions.isAlive($0.id) }
        world.onRemoved = { sessions.terminate($0.id) }
        world.onBadge = { b, badge in
            guard badge.kind.needsAttention, !NSApp.isActive else { return }
            NSApp.requestUserAttention(.informationalRequest)
            let text = badge.summary.isEmpty ? badge.kind.label : badge.summary
            let esc: (String) -> String = { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            let script = "display notification \"\(esc(text))\" with title \"\(badge.kind.emoji) \(esc(b.name))\" subtitle \"\(esc(badge.kind.label))\""
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            try? p.run()
        }
        world.onOpenBody = { b in
            if let badge = b.badge, !badge.kind.needsAttention { world.clearBadge(b) }
            guard sessions.start(b, store: store) else { return }
            world.cancelInteraction()
            world.mouse = V2(-1000, -1000)
            ui.anchor = anchor(world.toScreen(b.com), size)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                ui.editingTemplateId = nil
                ui.shellOpen = false
                ui.dirRequest = nil
                ui.openBodyId = b.id
            }
        }
        world.onEditTemplate = { id in open(template: id, size: size) }
        menuBuilder.onPickDirectory = { req in openDirectoryPicker(req, size: size) }
        world.onConfirmRemove = { b in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "「\(b.name)」を削除しますか？"
                alert.informativeText = "このバブルで動いている Claude Code のセッションを終了します。"
                alert.addButton(withTitle: "セッションを終了して削除")
                alert.addButton(withTitle: "キャンセル")
                alert.alertStyle = .warning
                guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
                alert.beginSheetModal(for: window) { resp in
                    if resp == .alertFirstButtonReturn {
                        sessions.terminate(b.id)
                        world.remove(b)
                    }
                }
            }
        }
    }
}

struct RoundIcon: View {
    let symbol: String
    @State private var hover = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white.opacity(hover ? 1 : 0.75))
            .frame(width: 38, height: 38)
            .background(
                Circle()
                    .fill(LinearGradient(colors: [.white.opacity(hover ? 0.22 : 0.14), .white.opacity(0.04)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
            .scaleEffect(hover ? 1.08 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
            .onHover { hover = $0 }
    }
}

final class PlusMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

private struct SuckIn: ViewModifier {
    let p: CGFloat
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1 - 0.96 * pow(p, 0.75), y: 1 - 0.88 * pow(p, 1.5), anchor: anchor)
            .blur(radius: 8 * p)
            .opacity(Double(1 - p * p))
    }
}

extension AnyTransition {
    static func panel(anchor: UnitPoint) -> AnyTransition {
        .asymmetric(insertion: .scale(scale: 0.15, anchor: anchor).combined(with: .opacity),
                    removal: .modifier(active: SuckIn(p: 1, anchor: anchor), identity: SuckIn(p: 0, anchor: anchor)))
    }
}
