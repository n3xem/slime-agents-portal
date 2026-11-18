import AppKit
import Foundation
import SwiftTerm

final class AgySession: NSObject, LocalProcessTerminalViewDelegate, ObservableObject {
    let bodyId: Int
    let name: String
    let template: TemplateModel
    let view: ActivityTerminalView
    private let clock = OutputClock()

    @Published private(set) var config: LaunchConfig
    @Published private(set) var conversationId: String?
    @Published private(set) var exited = true
    @Published private(set) var everStarted = false
    @Published private(set) var exitCode: Int32?
    @Published var title = ""

    var onConversation: ((String) -> Void)?

    private var baseline: String?
    private var watcher: Timer?

    var state: SessionState {
        if !everStarted { return .none }
        if exited { return .exited }
        return clock.sinceLast < 1.2 ? .busy : .waiting
    }

    init(bodyId: Int, name: String, template: TemplateModel, config: LaunchConfig, conversationId: String?) {
        self.bodyId = bodyId
        self.name = name
        self.template = template
        self.config = config
        self.conversationId = conversationId
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

    private var arguments: [String] {
        var args: [String] = []
        if !config.permissionMode.isEmpty { args += ["--mode", config.permissionMode] }
        if config.sandbox == .on || config.sandbox == .strict { args.append("--sandbox") }
        if let m = config.model, !m.isEmpty { args += ["--model", m] }
        if let e = config.effort, !e.isEmpty { args += ["--effort", e] }
        if let id = conversationId {
            args += ["--conversation", id]
        } else {
            let agents = template.agents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !agents.isEmpty {
                args += ["-i", agents + "\n\nこの役割で作業してください。準備ができたら、了解したことだけを短く返してください。"]
            }
        }
        return args
    }

    private var waitingForEnv = false

    func start() {
        guard exited, !waitingForEnv else { return }
        waitingForEnv = true
        ShellEnvironment.whenLoaded { [weak self] env in
            guard let self, self.waitingForEnv else { return }
            self.waitingForEnv = false
            self.launch(env)
        }
    }

    private func launch(_ loaded: [String: String]) {
        var env = loaded
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "ja_JP.UTF-8" }
        env["SLIME_FACTORY_BUBBLE"] = name
        env["SLIME_FACTORY_TEMPLATE"] = template.name
        guard let exe = ShellEnvironment.resolve("agy", env: env) else {
            view.feed(text: "\u{1b}[31magy が見つかりませんでした。Antigravity CLI をインストールしてください。\u{1b}[0m\r\n")
            return
        }
        guard FileManager.default.fileExists(atPath: config.workdir) else {
            view.feed(text: "\u{1b}[31m作業ディレクトリ「\(config.workdir)」がありません。\u{1b}[0m\r\n")
            return
        }
        baseline = Self.lastConversation(for: config.workdir)
        exited = false
        exitCode = nil
        everStarted = true
        view.startProcess(executable: exe, args: arguments, environment: env.map { "\($0.key)=\($0.value)" },
                          execName: nil, currentDirectory: config.workdir)
        watcher?.invalidate()
        watcher = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.watchConversation() }
    }

    func restart(with config: LaunchConfig) {
        var cfg = config
        cfg.workdir = self.config.workdir
        self.config = cfg
        if exited {
            start()
            return
        }
        terminate()
        func wait(_ tries: Int) {
            if exited || tries > 40 {
                start()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { wait(tries + 1) }
            }
        }
        wait(0)
    }

    func terminate() {
        waitingForEnv = false
        if !exited { view.terminate() }
    }

    private func watchConversation() {
        guard let id = Self.lastConversation(for: config.workdir), id != baseline, id != conversationId else { return }
        baseline = id
        conversationId = id
        onConversation?(id)
    }

    static func lastConversation(for workdir: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/cache/last_conversations.json")
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return map[workdir] ?? map[(workdir as NSString).resolvingSymlinksInPath]
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { self.title = title }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.watchConversation()
            self.watcher?.invalidate()
            self.watcher = nil
            self.exited = true
            self.exitCode = exitCode
        }
    }
}
