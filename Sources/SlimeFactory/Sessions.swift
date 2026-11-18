import AppKit
import Foundation
import SwiftTerm

final class OutputClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: CFTimeInterval = 0

    func touch() {
        lock.lock()
        last = CACurrentMediaTime()
        lock.unlock()
    }

    var sinceLast: CFTimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return CACurrentMediaTime() - last
    }
}

enum ShellEnvironment {
    private static var cached: [String: String]?
    private static let lock = NSLock()

    private static func discardUntilClosed(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        handle.readabilityHandler = { h in
            guard h.availableData.isEmpty else { return }
            h.readabilityHandler = nil
            _ = pipe
        }
    }

    private static func capture(shell: String, base: [String: String], until deadline: Date) -> [String: String]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", "env -0"]
        p.environment = base
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let fd = out.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let exited = !p.isRunning
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                data.append(buf, count: n)
                continue
            }
            if n == 0 { break }
            if exited {
                discardUntilClosed(out)
                break
            }
            if Date() > deadline {
                p.terminate()
                discardUntilClosed(out)
                return nil
            }
            usleep(10_000)
        }
        var env: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let str = String(decoding: entry, as: UTF8.self)
            guard let eq = str.firstIndex(of: "=") else { continue }
            env[String(str[..<eq])] = String(str[str.index(after: eq)...])
        }
        guard let path = env["PATH"], path != base["PATH"] else { return nil }
        return env
    }

    static func load() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let parent = ProcessInfo.processInfo.environment
        let shell = parent["SHELL"] ?? "/bin/zsh"
        var base: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": shell, "TERM": "xterm-256color"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"] {
            if let v = parent[key] { base[key] = v }
        }
        let deadline = Date().addingTimeInterval(5)
        if let env = capture(shell: shell, base: base, until: deadline) ?? capture(shell: shell, base: base, until: deadline) {
            var merged = base
            merged.merge(env) { _, new in new }
            cached = merged
            return merged
        }
        var fallback = base
        let home = parent["HOME"] ?? NSHomeDirectory()
        fallback["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", base["PATH"]!].joined(separator: ":")
        cached = fallback
        return fallback
    }

    static func resolve(_ command: String, env: [String: String]) -> String? {
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let path = "\(dir)/\(expanded)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func prefetch() {
        DispatchQueue.global(qos: .userInitiated).async { _ = load() }
    }
}

enum GitRepository {
    private static var cache: [String: Bool] = [:]
    private static let lock = NSLock()

    static func contains(_ path: String) -> Bool {
        let start = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[start] { return hit }
        var dir = start
        var found = false
        while !dir.isEmpty {
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                found = true
                break
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        cache[start] = found
        return found
    }
}

final class ActivityTerminalView: LocalProcessTerminalView {
    var clock: OutputClock?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        clock?.touch()
    }
}

struct LaunchConfig {
    var workdir: String
    var sandbox: SandboxMode
    var permissionMode: String
    var worktree: Bool
    var chrome: Bool?
    var conductorMCP: String?
    var model: String? = nil
    var effort: String? = nil
    var engine: Engine = .claude

    func saved(_ id: String) -> SavedSession {
        SavedSession(sessionId: id, workdir: workdir, sandbox: sandbox, permissionMode: permissionMode, worktree: worktree,
                     chrome: chrome, engine: engine == .claude ? nil : engine, model: model, effort: effort)
    }

    static func plain(_ workdir: String) -> LaunchConfig {
        LaunchConfig(workdir: workdir, sandbox: .inherit, permissionMode: "", worktree: false, chrome: nil, conductorMCP: nil)
    }
}

final class ClaudeSession: NSObject, LocalProcessTerminalViewDelegate, ObservableObject {
    let bodyId: Int
    let name: String
    let template: TemplateModel
    let sessionId: String
    let view: ActivityTerminalView
    var nsView: NSView { view }
    private let clock = OutputClock()
    private let settings: AppSettings
    private let agentsPath: URL
    private weak var server: HookServer?

    @Published var exited = false
    var ready = false
    @Published var exitCode: Int32?
    @Published var title = ""
    @Published var currentDirectory: String
    @Published var config: LaunchConfig

    let hookToken = UUID().uuidString.lowercased()
    var testArgs: [String] = []

    var workdir: String { config.workdir }
    var isConductor: Bool { config.conductorMCP != nil }

    init(bodyId: Int, name: String, template: TemplateModel, config: LaunchConfig, store: TemplateStore, server: HookServer? = nil,
         sessionId: String = UUID().uuidString.lowercased()) {
        self.sessionId = sessionId
        self.bodyId = bodyId
        self.name = name
        self.template = template
        var cfg = config
        cfg.workdir = (cfg.workdir as NSString).expandingTildeInPath
        self.config = cfg
        self.currentDirectory = cfg.workdir
        self.settings = store.settings
        self.server = server
        let dir = store.sessionDirectory(sessionId)
        agentsPath = dir.appendingPathComponent("AGENTS.md")
        try? template.agents.write(to: agentsPath, atomically: true, encoding: .utf8)
        view = ActivityTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        super.init()
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(red: 0.055, green: 0.06, blue: 0.085, alpha: 1)
        view.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        view.caretColor = NSColor(red: CGFloat(template.color[safe: 0] ?? 0.8), green: CGFloat(template.color[safe: 1] ?? 0.8),
                                  blue: CGFloat(template.color[safe: 2] ?? 0.8), alpha: 1)
        view.processDelegate = self
        view.clock = clock
    }

    private func settingsJSON() -> String? {
        var settings: [String: Any] = [:]
        if let server {
            let token = hookToken
            func http(_ event: String, timeout: Int, block: Bool = false) -> [String: Any] {
                let url = server.url(token: token, event: event)
                let curl = "curl -sS -m \(timeout) -X POST -H 'Content-Type: application/json' --data-binary @- '\(url)'"
                let onError = block
                    ? "|| { echo 'Slime Factory に接続できないため、送信を止めました。' >&2; exit 2; }"
                    : "2>/dev/null || true"
                var h: [String: Any] = ["type": "command", "command": "\(curl) \(onError)", "timeout": timeout + 5]
                if block { h["onFailure"] = "block" }
                return h
            }
            settings["hooks"] = [
                "SessionStart": [["hooks": [http("start", timeout: 5)]]],
                "PreToolUse": [
                    ["matcher": "^SendMessage$", "hooks": [http("pre", timeout: 1800, block: true)]],
                    ["matcher": "*", "hooks": [http("tool", timeout: 5)]],
                ],
                "PostToolUse": [
                    ["matcher": "^SendMessage$", "hooks": [http("post", timeout: 10)]],
                    ["matcher": "*", "hooks": [http("posttool", timeout: 5)]],
                ],
                "StopFailure": [["hooks": [http("stopfail", timeout: 5)]]],
                "UserPromptSubmit": [["hooks": [http("prompt", timeout: 10)]]],
                "Notification": [["hooks": [http("notify", timeout: 5)]]],
                "Stop": [["hooks": [http("stop", timeout: 10)]]],
            ]
        }
        if let sandbox = config.sandbox.settings { settings["sandbox"] = sandbox }
        if settings.isEmpty { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private var factoryPrompt: String {
        if isConductor {
            return """
            # Slime Factory の管理セッション

            このセッションは Slime Factory の「管理」セッションです。Slime Factory は、Claude Code のセッションをスライムとして画面に並べ、矢印でつないで作業を引き継がせるアプリです。人の指示に従って、スライムを作り、設定し、矢印でつなぎます。

            - スライムの操作には slime-factory MCP サーバーのツール（list_templates、list_islands、create_island、list_bubbles、create_bubble、configure_bubble、connect_bubbles、disconnect_bubbles、start_bubble）を使います。
            - 人に Markdown ファイルを「開いて」と頼まれたときや、書いた文書を見てほしいときは、slime-factory MCP サーバーの open_file に絶対パスを渡して、Slime Factory の画面のエディタで開きます。
            - 定期的に見回っていて人に知らせたいことを見つけたときは、slime-factory MCP サーバーの say に短い文を渡して、画面の管理スライムの横に吹き出しを出します。
            - 画面上の「島」はリポジトリのディレクトリを表します。島の中のスライムは、その島のディレクトリで起動します。リポジトリごとに島を作り、スライムはその島に置きます。
            - スライムの作業ディレクトリは、人の指示とリポジトリの場所から決めます。場所がわからないときは、手元を調べるか人に聞きます。
            - 同じリポジトリを並行して編集するスライムが複数あるときは、worktree を使うかを検討します。
            - 作業ディレクトリ・サンドボックス・権限モード・worktree は、セッションの起動前にしか変えられません。
            - スライムに作業を頼むときは、SendMessage でスライムの名前を宛先にして送ります。メッセージには目的、成果物の場所、依頼内容を書きます。起動していないスライムは、送信時に自動で起動します。
            - スライムの削除は人が行います。
            - テンプレートには Claude Code と Antigravity CLI（agy）のエンジンがあります（list_templates の engine）。agy のスライムは人が端末で直接使うもので、SendMessage では送れず、矢印でもつなげません。
            """
        }
        return """
        # Slime Factory

        このセッションは Slime Factory のスライム「\(name)」（テンプレート: \(template.name)）で動いています。Slime Factory は、矢印でつないだ Claude Code のセッション同士で作業を引き継ぐためのアプリです。

        - 他のスライムへの引き継ぎには SendMessage を使います。宛先はスライムの名前です。
        - 送れるのは、このスライムから矢印が出ている相手だけです。現在の送り先と受け取り元は、プロンプトごとに追加のコンテキストとして示されます。
        - 矢印のない相手への送信はフックが拒否します。矢印のある相手への送信も、人が承認するまで保留されることがあります。拒否された場合は、示された理由に従います。
        - 引き継ぎのメッセージには、目的、成果物の場所（ブランチ名、PR の URL、ファイルのパスなど）、相手にしてほしいことを書きます。差分や長い出力は貼らずに、場所を示します。
        - 受け取る側はこちらの会話履歴を見られません。必要な前提はメッセージに書きます。
        - ターンを終える前に、slime-factory MCP サーバーの report_status で状態を報告します。頼まれた作業が終わったら done、人に方針の選択や前提の確認をしてほしいときは need_decision、権限や環境の問題で進められないときは blocked です。summary には画面に出す一行の要約を書きます。
        - 人に Markdown ファイルを「開いて」と頼まれたときや、書いた文書を見てほしいときは、slime-factory MCP サーバーの open_file に絶対パスを渡して、Slime Factory の画面のエディタで開きます。
        - 定期的に見回っていて人に知らせたいこと（Slack に返事をしていない依頼がある、など）を見つけたときは、slime-factory MCP サーバーの say に短い文を渡して、画面のこのスライムの横に吹き出しを出します。
        \(config.worktree ? "- このスライムは専用の git worktree で動いています。変更を引き継ぐときは、先にコミットし、ブランチ名を伝えます。worktree 同士は同じリポジトリを共有しているので、相手は別の worktree からでもそのブランチを git で読めます（同じブランチを 2 つの worktree で同時にチェックアウトすることはできません）。" : "- 受け取ったブランチが別の worktree にあっても、同じリポジトリなら git でそのブランチを読めます。")
        """
    }

    private var worktreeName: String {
        World.sessionName("\(template.id)-\(bodyId)").lowercased()
    }

    private func arguments(resume: Bool) -> [String] {
        var args = ["--name", name]
        if resume {
            args += ["--resume", sessionId]
        } else {
            args += ["--session-id", sessionId]
        }
        if config.worktree && !isConductor { args += ["--worktree", worktreeName] }
        if !config.permissionMode.isEmpty { args += ["--permission-mode", config.permissionMode] }
        if let m = config.model, !m.isEmpty { args += ["--model", m] }
        if let e = config.effort, !e.isEmpty { args += ["--effort", e] }
        if let chrome = config.chrome { args.append(chrome ? "--chrome" : "--no-chrome") }
        if let json = settingsJSON() { args += ["--settings", json] }
        if let mcp = config.conductorMCP ?? server?.bubbleMCPURL(token: hookToken) {
            let mcpConfig: [String: Any] = ["mcpServers": ["slime-factory": ["type": "http", "url": mcp]]]
            if let data = try? JSONSerialization.data(withJSONObject: mcpConfig) {
                args += ["--mcp-config", String(decoding: data, as: UTF8.self), "--allowedTools", "mcp__slime-factory"]
            }
        }
        let agents = (try? String(contentsOf: agentsPath, encoding: .utf8)) ?? template.agents
        var prompt = factoryPrompt
        if !agents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\n" + agents
        }
        args += ["--append-system-prompt", prompt]
        args += settings.extraArgs.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        args += testArgs
        return args
    }

    func start(resume: Bool = false) {
        exited = false
        ready = false
        exitCode = nil
        var env = ShellEnvironment.load()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "ja_JP.UTF-8" }
        env["SLIME_FACTORY_BUBBLE"] = name
        env["SLIME_FACTORY_TEMPLATE"] = template.name
        let command = settings.claudeCommand.isEmpty ? "claude" : settings.claudeCommand
        guard let exe = ShellEnvironment.resolve(command, env: env) else {
            view.feed(text: "\u{1b}[31m「\(command)」が見つかりませんでした。設定の「起動コマンド」を確認してください。\u{1b}[0m\r\n")
            exited = true
            return
        }
        guard FileManager.default.fileExists(atPath: workdir) else {
            view.feed(text: "\u{1b}[31m作業ディレクトリ「\(workdir)」がありません。\u{1b}[0m\r\n")
            exited = true
            return
        }
        let envList = env.map { "\($0.key)=\($0.value)" }
        view.startProcess(executable: exe, args: arguments(resume: resume), environment: envList,
                          execName: nil, currentDirectory: workdir)
    }

    func restart(with config: LaunchConfig) {
        var cfg = config
        cfg.workdir = self.config.workdir
        self.config = cfg
        if exited {
            start(resume: true)
            return
        }
        terminate()
        func waitExit(_ tries: Int) {
            if exited || tries > 40 {
                start(resume: true)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitExit(tries + 1) }
            }
        }
        waitExit(0)
    }

    func terminate() {
        if !exited { view.terminate() }
    }

    var state: SessionState {
        if exited { return .exited }
        if !ready { return .starting }
        return clock.sinceLast < 1.2 ? .busy : .waiting
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { self.title = title }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        DispatchQueue.main.async { self.currentDirectory = directory }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.exited = true
            self.exitCode = exitCode
        }
    }
}

final class ShellSession: NSObject, LocalProcessTerminalViewDelegate, ObservableObject {
    let view: LocalProcessTerminalView
    private let workdir: String

    @Published var exited = false
    @Published var exitCode: Int32?
    @Published var currentDirectory: String

    init(workdir: String) {
        let dir = (workdir as NSString).expandingTildeInPath
        self.workdir = FileManager.default.fileExists(atPath: dir) ? dir : NSHomeDirectory()
        currentDirectory = self.workdir
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        super.init()
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(red: 0.055, green: 0.06, blue: 0.085, alpha: 1)
        view.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        view.caretColor = NSColor(white: 0.8, alpha: 1)
        view.processDelegate = self
    }

    func start() {
        exited = false
        exitCode = nil
        var env = ShellEnvironment.load()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "ja_JP.UTF-8" }
        let shell = env["SHELL"] ?? "/bin/zsh"
        view.startProcess(executable: shell, args: ["-l"], environment: env.map { "\($0.key)=\($0.value)" },
                          execName: nil, currentDirectory: workdir)
    }

    func terminate() {
        if !exited { view.terminate() }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        DispatchQueue.main.async { self.currentDirectory = directory }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.exited = true
            self.exitCode = exitCode
        }
    }
}

enum ClaudeSessionRegistry {
    static var enabled = true

    static func namesInUse(excluding pids: Set<pid_t> = []) -> Set<String> {
        guard enabled else { return [] }
        let env = ShellEnvironment.load()
        let base = env["CLAUDE_CONFIG_DIR"].map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        let dir = URL(fileURLWithPath: base).appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var names = Set<String>()
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber).map({ pid_t($0.int32Value) }),
                  let name = obj["name"] as? String, !name.isEmpty,
                  !pids.contains(pid) else { continue }
            if isRunning(pid) { names.insert(name) }
        }
        return names
    }

    private static func isRunning(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        if info.kp_proc.p_stat == SZOMB { return false }
        return info.kp_proc.p_flag & P_WEXIT == 0
    }
}

final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [Int: ClaudeSession] = [:]
    @Published private(set) var agySessions: [Int: AgySession] = [:]
    private(set) var shell: ShellSession?
    private(set) var bodyShells: [Int: ShellSession] = [:]
    let server: HookServer?

    static let conductorTemplate = TemplateModel(id: "__conductor", name: "管理", symbol: "crown.fill",
                                                 color: [0.52, 0.32, 0.9])

    var locationResolver: ((SoftBody) -> String?)?
    var renameIfTaken: ((SoftBody, Set<String>) -> Void)?
    var onStarted: ((ClaudeSession) -> Void)?

    init(server: HookServer?) {
        self.server = server
    }

    func resolvedWorkdir(for body: SoftBody, template tpl: TemplateModel, store: TemplateStore) -> String {
        if let w = body.config.workdir { return w }
        if let w = locationResolver?(body) { return w }
        if let w = tpl.workdir, !w.isEmpty { return w }
        return store.lastWorkdir
    }

    func bodyId(forToken token: String) -> Int? {
        sessions.values.first { $0.hookToken == token }?.bodyId
    }

    func template(for body: SoftBody, store: TemplateStore) -> TemplateModel {
        if body.isConductor { return Self.conductorTemplate }
        return store.template(body.template.id)
            ?? TemplateModel(id: body.template.id, name: body.template.name, symbol: body.template.symbol,
                             color: [body.template.color.x, body.template.color.y, body.template.color.z])
    }

    func launchConfig(for body: SoftBody, store: TemplateStore) -> LaunchConfig {
        let tpl = template(for: body, store: store)
        if body.isConductor {
            return LaunchConfig(workdir: body.config.workdir ?? store.settings.defaultWorkdir,
                                sandbox: body.config.sandbox ?? store.defaultSandbox, permissionMode: body.config.permissionMode ?? "",
                                worktree: false, chrome: body.config.chrome ?? nil, conductorMCP: server?.mcpURL)
        }
        let workdir = resolvedWorkdir(for: body, template: tpl, store: store)
        let model = tpl.model.flatMap { $0.isEmpty ? nil : $0 }
        let effort = tpl.effort.flatMap { $0.isEmpty ? nil : $0 }
        if tpl.engine == .agy {
            return LaunchConfig(workdir: workdir, sandbox: body.config.sandbox ?? tpl.sandbox ?? .on,
                                permissionMode: body.config.permissionMode ?? tpl.permissionMode ?? "accept-edits",
                                worktree: false, chrome: nil, conductorMCP: nil, model: model, effort: effort, engine: .agy)
        }
        return LaunchConfig(workdir: workdir,
                            sandbox: body.config.sandbox ?? tpl.sandbox ?? store.defaultSandbox,
                            permissionMode: body.config.permissionMode ?? tpl.permissionMode ?? "",
                            worktree: (body.config.worktree ?? tpl.worktree ?? true) && GitRepository.contains(workdir),
                            chrome: body.config.chrome ?? tpl.chrome,
                            conductorMCP: nil, model: model, effort: effort)
    }

    @discardableResult
    func start(_ body: SoftBody, store: TemplateStore) -> Bool {
        if body.engine == .agy { return agySession(for: body, store: store) != nil }
        return session(for: body, store: store) != nil
    }

    func agySession(for body: SoftBody, store: TemplateStore) -> AgySession? {
        if let a = agySessions[body.id] {
            if a.exited { a.start() }
            return a
        }
        let cfg = body.savedSession?.launchConfig ?? launchConfig(for: body, store: store)
        let a = AgySession(bodyId: body.id, name: body.name, template: template(for: body, store: store), config: cfg,
                           conversationId: body.savedSession?.sessionId)
        agySessions[body.id] = a
        a.onConversation = { [weak body, weak a] id in
            guard let body, let a else { return }
            body.savedSession = a.config.saved(id)
        }
        a.start()
        return a
    }

    func existingAgy(_ id: Int) -> AgySession? { agySessions[id] }

    func session(for body: SoftBody, store: TemplateStore) -> ClaudeSession? {
        if let s = sessions[body.id] { return s }
        let own = Set(sessions.values.compactMap { $0.exited ? nil : $0.view.process?.shellPid })
        let taken = ClaudeSessionRegistry.namesInUse(excluding: own)
        if taken.contains(body.name) { renameIfTaken?(body, taken) }
        let s: ClaudeSession
        if let saved = body.savedSession {
            var cfg = saved.launchConfig
            if body.isConductor { cfg.conductorMCP = server?.mcpURL }
            s = ClaudeSession(bodyId: body.id, name: body.name, template: template(for: body, store: store),
                              config: cfg, store: store, server: server, sessionId: saved.sessionId)
            sessions[body.id] = s
            s.start(resume: CanvasStore.transcriptExists(saved.sessionId))
        } else {
            s = ClaudeSession(bodyId: body.id, name: body.name, template: template(for: body, store: store),
                              config: launchConfig(for: body, store: store), store: store, server: server)
            sessions[body.id] = s
            s.start()
        }
        body.savedSession = s.config.saved(s.sessionId)
        onStarted?(s)
        return s
    }

    func restart(_ body: SoftBody, store: TemplateStore) {
        if let a = agySessions[body.id] {
            var cfg = launchConfig(for: body, store: store)
            cfg.workdir = a.config.workdir
            a.restart(with: cfg)
            if let id = a.conversationId { body.savedSession = a.config.saved(id) }
            return
        }
        guard let s = sessions[body.id] else { return }
        s.restart(with: launchConfig(for: body, store: store))
        body.savedSession = s.config.saved(s.sessionId)
    }

    func existing(_ id: Int) -> ClaudeSession? { sessions[id] }

    func adopt(_ s: ClaudeSession) { sessions[s.bodyId] = s }

    func markReady(token: String) {
        sessions.values.first { $0.hookToken == token }?.ready = true
    }

    func isReady(_ id: Int) -> Bool {
        if let a = agySessions[id] { return !a.exited }
        guard let s = sessions[id] else { return false }
        return s.ready && !s.exited
    }

    func isAlive(_ id: Int) -> Bool {
        if let a = agySessions[id] { return !a.exited }
        guard let s = sessions[id] else { return false }
        return !s.exited
    }

    func hasStarted(_ id: Int) -> Bool { sessions[id] != nil || agySessions[id] != nil }

    func state(_ id: Int) -> SessionState {
        agySessions[id]?.state ?? sessions[id]?.state ?? .none
    }

    func terminate(_ id: Int) {
        sessions[id]?.terminate()
        sessions[id] = nil
        agySessions[id]?.terminate()
        agySessions[id] = nil
        bodyShells[id]?.terminate()
        bodyShells[id] = nil
    }

    func bodyShell(_ id: Int, workdir: String) -> ShellSession {
        if let s = bodyShells[id] {
            if s.exited { s.start() }
            return s
        }
        let s = ShellSession(workdir: workdir)
        bodyShells[id] = s
        s.start()
        return s
    }

    func shellSession(workdir: String) -> ShellSession {
        if let s = shell {
            if s.exited { s.start() }
            return s
        }
        let s = ShellSession(workdir: workdir)
        shell = s
        s.start()
        return s
    }

    func terminateAll() {
        for s in sessions.values { s.terminate() }
        for a in agySessions.values { a.terminate() }
        shell?.terminate()
        for s in bodyShells.values { s.terminate() }
    }
}
