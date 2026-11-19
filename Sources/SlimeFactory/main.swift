import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        ShellEnvironment.prefetch()
        DirectoryCandidates.prefetch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        _ = MarkdownDocument.current?.close()
        sharedSaveCanvas?()
        sharedSessions.terminateAll()
    }
}

let sharedStore = TemplateStore()
let sharedHookServer = try? HookServer()
let sharedSessions = SessionManager(server: sharedHookServer)

struct SlimeFactoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private let world = World(templates: sharedStore.templates.map(\.runtime))

    var body: some Scene {
        Window("Slime Factory", id: "main") {
            ContentView(world: world, store: sharedStore, sessions: sharedSessions)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)

        Settings {
            SettingsView(store: sharedStore)
        }
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        SnapshotRunner(outDir: URL(fileURLWithPath: args[i + 1])).run()
    }
    exit(0)
}

if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        IconRenderer.run(out: URL(fileURLWithPath: args[i + 1]))
    }
    exit(0)
}

if args.contains("--session-test") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let store = TemplateStore(persistent: false)
        let interactive = args.contains("--interactive")
        store.settings.extraArgs = interactive ? "" : "--version"
        let tpl = store.templates[1]
        let s = ClaudeSession(bodyId: 1, name: "レビュー 'テスト'", template: tpl, config: .plain(store.settings.defaultWorkdir), store: store)
        s.start()
        let deadline = Date().addingTimeInterval(interactive ? 8 : 15)
        while !s.exited && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let state = s.state
        let data = s.view.getTerminal().getBufferAsData()
        s.terminate()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        print("state=\(state) exited=\(s.exited) code=\(String(describing: s.exitCode)) cwd=\(s.workdir)")
        print("--- terminal ---")
        print(text)
        fflush(stdout)
    }
    exit(0)
}

if let i = args.firstIndex(of: "--panel-snapshot"), i + 1 < args.count {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        let out = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = TemplateStore(persistent: false)
        let session = ClaudeSession(bodyId: 1, name: "レビュー 2", template: store.templates[1], config: .plain(store.settings.defaultWorkdir), store: store)
        session.start()

        func render<V: View>(_ view: V, size: NSSize, name: String, wait: TimeInterval) {
            let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless],
                               backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                .background(Color(red: 0.05, green: 0.055, blue: 0.08)))
            win.contentView = host
            win.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(wait))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
            print("wrote \(name)")
            win.orderOut(nil)
        }

        render(TemplatePanel(store: store, id: store.templates[1].id, close: {}).padding(30), size: NSSize(width: 900, height: 720),
               name: "template_panel", wait: 1)
        render(TerminalPanel(session: session, close: {}).padding(30), size: NSSize(width: 1100, height: 640),
               name: "terminal_panel", wait: 7)
        render(SettingsView(store: store), size: NSSize(width: 900, height: 640), name: "settings", wait: 1)
        let md = out.appendingPathComponent("sample.md")
        try? "# Slime Factory メモ\n\n- 実装とレビューのスライムをつなぐ\n- AGENTS.md を見直す\n\n```sh\nswift build -c release --build-system native\n```\n"
            .write(to: md, atomically: true, encoding: .utf8)
        if let doc = try? MarkdownDocument(url: md) {
            render(MarkdownPanel(document: doc, close: {}).padding(30), size: NSSize(width: 1100, height: 560), name: "markdown_panel", wait: 0.6)
            _ = doc.close()
        }

        let shell = ShellSession(workdir: store.settings.defaultWorkdir)
        shell.start()
        render(ShellPanel(session: shell, close: {}).padding(30), size: NSSize(width: 1100, height: 640),
               name: "shell_panel", wait: 3)
        shell.terminate()
        render(FaceGallery().padding(20), size: NSSize(width: 1040, height: 560), name: "faces", wait: 0.5)
        let sampleRepos = ["github.com/example/todo-api", "github.com/example/todo-mobile", "github.com/example/recipe-book",
                           "github.com/example/todo-web", "github.com/example/weather-bot", "github.com/example/blog-engine",
                           "github.com/example/dotfiles", "github.com/other/markdown-parser", "github.com/other/pixel-editor"]
            .map { "/Users/example/ghq/" + $0 }
        let sampleRecent = ["/Users/example/workspace/todo-web", "/Users/example/ghq/github.com/example/todo-api"]
        render(DirectoryPicker(title: "島を追加", recent: sampleRecent, existing: [sampleRecent[1]], preloaded: sampleRepos,
                               choose: { _ in }, browse: {}, close: {}).frame(width: 660, height: 520).padding(30),
               size: NSSize(width: 720, height: 580), name: "directory_picker", wait: 0.6)
        render(DirectoryPicker(title: "島を追加", recent: sampleRecent, existing: [sampleRecent[1]], preloaded: sampleRepos,
                               initialQuery: "todo a", choose: { _ in }, browse: {}, close: {}).frame(width: 660, height: 520).padding(30),
               size: NSSize(width: 720, height: 580), name: "directory_picker_search", wait: 0.6)
        session.terminate()
    }
    exit(0)
}

if let i = args.firstIndex(of: "--bridge-test"), i + 1 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let workdir = args[i + 1]
        let store = TemplateStore(persistent: false)
        store.settings.defaultWorkdir = workdir
        store.settings.extraArgs = "--model haiku"
        let world = World(templates: store.templates.map(\.runtime))
        let bridge = FactoryBridge(world: world, sessions: sharedSessions, store: store)
        sharedHookServer?.handler = { bridge.handle(token: $0, event: $1, body: $2, respond: $3) }
        print("hook server port: \(sharedHookServer?.port ?? 0)")
        guard let a = world.spawnBody(templateId: "impl", at: V2(300, 400)),
              let b = world.spawnBody(templateId: "review", at: V2(700, 400)) else { exit(1) }
        world.connect(a, b)

        func pump(_ seconds: Double, until: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end && !until() {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                world.update(dt: 0.05)
            }
        }
        func screen(_ s: ClaudeSession) -> String {
            String(decoding: s.view.getTerminal().getBufferAsData(), as: UTF8.self)
        }

        let sb = sharedSessions.session(for: b, store: store)!
        pump(40) { sb.ready }
        guard sb.ready else {
            print("受信側のセッションが起動しませんでした。Claude Code で信頼済みのディレクトリを指定してください。")
            print(screen(sb).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(20).joined(separator: "\n"))
            sb.terminate()
            exit(1)
        }
        print("B ready (SessionStart hook received): \(sb.ready)")

        let sa = ClaudeSession(bodyId: a.id, name: a.name, template: store.templates[0], config: .plain(workdir), store: store, server: sharedHookServer)
        sa.testArgs = ["-p", "SendMessage ツールで、宛先「\(b.name)」に「接続テストです。返信は不要です。」とだけ送ってください。それ以外の作業はしないでください。"]
        sharedSessions.adopt(sa)
        sa.start()
        print("A started; waiting for PreToolUse")
        pump(90) { !a.pending.isEmpty }
        if let p = a.pending.first {
            print("PENDING on A -> \(p.targetName): \(p.message)")
            world.choose(a, 0)
        } else {
            print("NO PENDING (timeout)")
        }
        pump(60) { !world.droplets.isEmpty || sa.exited }
        print("droplet launched: \(!world.droplets.isEmpty)  A exited: \(sa.exited)")
        pump(25)
        print("--- A screen ---")
        print(screen(sa).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(8).joined(separator: "\n"))
        print("--- B screen ---")
        print(screen(sb).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(16).joined(separator: "\n"))
        sa.terminate()
        sb.terminate()
        fflush(stdout)
    }
    exit(0)
}

if let i = args.firstIndex(of: "--mcp-test"), i + 1 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let workdir = args[i + 1]
        let store = TemplateStore(persistent: false)
        store.settings.defaultWorkdir = workdir
        store.settings.extraArgs = "--model haiku"
        let world = World(templates: store.templates.map(\.runtime))
        let bridge = FactoryBridge(world: world, sessions: sharedSessions, store: store)
        sharedHookServer?.handler = { bridge.handle(token: $0, event: $1, body: $2, respond: $3) }
        let mcp = FactoryMCP(world: world, sessions: sharedSessions, store: store)
        sharedHookServer?.mcpHandler = { mcp.handle(token: $0, method: $1, body: $2, reply: $3) }
        sharedSessions.locationResolver = { b in world.islandAt(b.com)?.path }
        print("mcp: \(sharedHookServer?.mcpURL ?? "-")")
        if let c = world.conductor {
            let s = ClaudeSession(bodyId: c.id, name: c.name, template: SessionManager.conductorTemplate,
                                  config: sharedSessions.launchConfig(for: c, store: store), store: store, server: sharedHookServer)
            s.testArgs = ["-p", args[i + 2 < args.count ? i + 2 : i + 1]]
            sharedSessions.adopt(s)
            s.start()
            let end = Date().addingTimeInterval(240)
            while Date() < end && !s.exited {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                world.update(dt: 0.05)
            }
            let text = String(decoding: s.view.getTerminal().getBufferAsData(), as: UTF8.self)
            print("--- conductor ---")
            print(text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.contains("Permission allow rule") && !$0.contains("permission checks") && !$0.contains("editing to") }.suffix(25).joined(separator: "\n"))
        }
        print("--- islands ---")
        for i in world.islands { print("\(i.name) \(i.path) bubbles=\(world.bodiesInside(i).compactMap { world.body($0)?.name })") }
        print("--- bubbles ---")
        for b in world.bodies {
            let cfg = sharedSessions.launchConfig(for: b, store: store)
            print("\(b.name) template=\(b.template.id) workdir=\(cfg.workdir) sandbox=\(cfg.sandbox.rawValue) perm=\(cfg.permissionMode) worktree=\(cfg.worktree) out=\(world.outgoing(b.id).map(\.name)) auto=\(world.ropes.filter { $0.from == b.id && $0.autoSend }.count)")
        }
        sharedSessions.terminateAll()
        fflush(stdout)
    }
    exit(0)
}

if let i = args.firstIndex(of: "--status-test"), i + 2 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let store = TemplateStore(persistent: false)
        store.settings.defaultWorkdir = args[i + 1]
        store.settings.extraArgs = "--model haiku"
        let world = World(templates: store.templates.map(\.runtime))
        let bridge = FactoryBridge(world: world, sessions: sharedSessions, store: store)
        sharedHookServer?.handler = { bridge.handle(token: $0, event: $1, body: $2, respond: $3) }
        let mcp = FactoryMCP(world: world, sessions: sharedSessions, store: store)
        sharedHookServer?.mcpHandler = { mcp.handle(token: $0, method: $1, body: $2, reply: $3) }
        guard let b = world.spawnBody(templateId: "verify", at: V2(500, 400)) else { exit(1) }
        var cfg = LaunchConfig.plain(args[i + 1])
        if args.contains("--sandbox") { cfg.sandbox = .on }
        if args.contains("--no-chrome-test") { cfg.chrome = false }
        let s = ClaudeSession(bodyId: b.id, name: b.name, template: store.templates[2], config: cfg, store: store, server: sharedHookServer)
        s.testArgs = ["-p", args[i + 2]]
        sharedSessions.adopt(s)
        s.start()
        let end = Date().addingTimeInterval(180)
        while Date() < end && !s.exited {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            world.update(dt: 0.05)
        }
        print("--- screen ---")
        print(String(decoding: s.view.getTerminal().getBufferAsData(), as: UTF8.self).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.contains("Permission allow rule") && !$0.contains("permission checks") && !$0.contains("ing tools") }.suffix(12).joined(separator: "\n"))
        print("title: \(b.title ?? "-")")
        print("badge: \(b.badge.map { "\($0.kind.emoji) \($0.kind.rawValue) \($0.summary)" } ?? "なし")")
        print("activity: \(b.activity?.text ?? "-")")
        fflush(stdout)
    }
    exit(0)
}

if let i = args.firstIndex(of: "--persist-test"), i + 1 < args.count {
    MainActor.assumeIsolated {
        let url = URL(fileURLWithPath: args[i + 1])
        let store = TemplateStore(persistent: false)
        let w1 = World(templates: store.templates.map(\.runtime))
        let a = w1.spawnBody(templateId: "impl", at: V2(300, 400))!
        let b = w1.spawnBody(templateId: "review", at: V2(700, 400))!
        a.config.worktree = true
        a.config.sandbox = .strict
        a.savedSession = SavedSession(sessionId: "11111111-2222-3333-4444-555555555555", workdir: "/tmp", sandbox: .strict,
                                      permissionMode: "acceptEdits", worktree: true, chrome: true)
        w1.connect(a, b).autoSend = true
        w1.conductor?.savedSession = SavedSession(sessionId: "conductor-id", workdir: "/Users", sandbox: .on, permissionMode: "", worktree: false, chrome: nil)
        w1.placeConductor(at: V2(640, 520))
        CanvasStore(url: url).save(world: w1)
        let w2 = World(templates: store.templates.map(\.runtime))
        if let saved = CanvasStore(url: url).load() { CanvasStore.restore(saved, into: w2) }
        for x in w2.bodies {
            print("\(x.name) conductor=\(x.isConductor) pos=(\(Int(x.com.x)),\(Int(x.com.y))) cfg=\(x.config) session=\(x.savedSession?.sessionId ?? "-") out=\(w2.outgoing(x.id).map(\.name)) auto=\(w2.ropes.filter { $0.from == x.id && $0.autoSend }.count)")
        }
    }
    exit(0)
}

if args.contains("--serve-test") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        sharedHookServer?.handler = { _, event, _, respond in
            print("hook event: \(event)")
            fflush(stdout)
            respond(nil)
        }
        print("port: \(sharedHookServer?.port ?? 0)")
        fflush(stdout)
        RunLoop.main.run(until: Date().addingTimeInterval(8))
    }
    exit(0)
}

let terminationSignals = [SIGTERM, SIGINT, SIGHUP].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    return source
}

SlimeFactoryApp.main()
