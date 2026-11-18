import AppKit
import Foundation

struct Template {
    let id: String
    let name: String
    let symbol: String
    let color: V3
    var engine: Engine = .claude
}

enum Engine: String, Codable, CaseIterable {
    case claude, agy

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .agy: return "Antigravity CLI"
        }
    }
}

enum AgyModes {
    static let all: [(value: String, label: String)] = [
        ("", "既定（agy の設定に従う）"),
        ("accept-edits", "accept-edits（編集は自動で許可）"),
        ("auto", "auto（自動で判断）"),
        ("plan", "plan（計画のみ）"),
    ]
}

enum EffortLevels {
    static let all: [(value: String, label: String)] = [
        ("", "既定"),
        ("low", "low"),
        ("medium", "medium"),
        ("high", "high"),
        ("xhigh", "xhigh"),
        ("max", "max"),
    ]
}

enum ModelCatalog {
    static let claude: [(value: String, label: String)] = [
        ("fable", "fable（最新の Fable）"),
        ("opus", "opus（最新の Opus）"),
        ("sonnet", "sonnet（最新の Sonnet）"),
        ("haiku", "haiku（最新の Haiku）"),
    ]

    private static var agyCache: [(value: String, label: String)]?
    private static let lock = NSLock()

    static func agy() -> [(value: String, label: String)] {
        lock.lock()
        if let c = agyCache { lock.unlock(); return c }
        lock.unlock()
        let env = ShellEnvironment.load()
        guard let exe = ShellEnvironment.resolve("agy", env: env) else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["models"]
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let list = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> (value: String, label: String)? in
            let cols = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count == 2, !cols[0].isEmpty, !cols[0].contains(" ") else { return nil }
            return (cols[0], cols[1])
        }
        lock.lock()
        if !list.isEmpty { agyCache = list }
        lock.unlock()
        return list
    }
}

enum SandboxMode: String, Codable, CaseIterable {
    case inherit, off, on, strict

    var label: String {
        switch self {
        case .inherit: return "Claude Code のユーザー設定に従う"
        case .off: return "オフ"
        case .on: return "オン"
        case .strict: return "厳格（サンドボックス外での実行を許さない）"
        }
    }

    var short: String {
        switch self {
        case .inherit: return "ユーザー設定"
        case .off: return "オフ"
        case .on: return "オン"
        case .strict: return "厳格"
        }
    }

    var boxed: Bool { self == .on || self == .strict }

    var settings: [String: Any]? {
        switch self {
        case .inherit: return nil
        case .off: return ["enabled": false]
        case .on: return ["enabled": true]
        case .strict: return ["enabled": true, "allowUnsandboxedCommands": false]
        }
    }
}

enum PermissionModes {
    static let all: [(value: String, label: String)] = [
        ("", "既定（ユーザー設定に従う）"),
        ("manual", "manual（操作ごとに確認）"),
        ("acceptEdits", "acceptEdits（編集は自動で許可）"),
        ("auto", "auto（分類器が判断）"),
        ("plan", "plan（計画のみ）"),
        ("dontAsk", "dontAsk（許可済みの操作だけ）"),
        ("bypassPermissions", "bypassPermissions（確認なし）"),
    ]

    static func label(_ v: String) -> String {
        all.first { $0.value == v }?.label ?? v
    }
}

struct TemplateModel: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var symbol: String
    var color: [Float]
    var workdir: String?
    var sandbox: SandboxMode?
    var permissionMode: String?
    var worktree: Bool?
    var chrome: Bool?
    var engine: Engine?
    var model: String?
    var effort: String?
    var agents: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, symbol, color, workdir, sandbox, permissionMode, worktree, chrome, engine, model, effort
    }

    var runtime: Template {
        let c = color.count == 3 ? V3(color[0], color[1], color[2]) : V3(0.6, 0.6, 0.6)
        return Template(id: id, name: name, symbol: symbol, color: c, engine: engine ?? .claude)
    }
}

struct AppSettings: Codable, Equatable {
    var defaultWorkdir: String
    var claudeCommand: String
    var extraArgs: String
    var recentDirs: [String]?
    var islands: [IslandModel]?
    var defaultSandbox: SandboxMode?
}

final class TemplateStore: ObservableObject {
    @Published var templates: [TemplateModel] { didSet { if templates != oldValue { saveTemplates() } } }
    @Published var settings: AppSettings { didSet { if settings != oldValue { saveSettings() } } }

    let baseURL: URL?
    private var savedAgents: [String: String] = [:]

    static let symbolPresets = [
        "hammer.fill", "eye.fill", "checkmark.seal.fill", "testtube.2", "paperplane.fill", "doc.text.fill",
        "magnifyingglass", "ladybug.fill", "wrench.and.screwdriver.fill", "shield.lefthalf.filled", "chart.bar.fill",
        "bolt.fill", "sparkles", "brain.head.profile", "terminal.fill", "server.rack", "cube.fill", "flag.fill",
        "bubble.left.and.bubble.right.fill", "lock.fill", "paintbrush.fill", "globe", "book.fill", "star.fill",
    ]

    static let palette: [[Float]] = [
        [0.30, 0.86, 0.42], [0.56, 0.44, 1.00], [1.00, 0.68, 0.18], [1.00, 0.38, 0.60], [0.20, 0.76, 1.00],
        [0.98, 0.42, 0.30], [0.25, 0.90, 0.82], [0.95, 0.85, 0.25], [0.75, 0.50, 0.95],
    ]

    static func defaults() -> [TemplateModel] {
        [
            TemplateModel(id: "impl", name: "実装", symbol: "hammer.fill", color: palette[0], agents: """
            # 役割: 実装

            あなたはワークフローの「実装」を担当するセッションです。

            - 渡された課題を実装し、必要なテストを追加・更新する
            - 作業用のブランチを切り、意味のある単位でコミットする
            - 終わったら、変更の要点・ブランチ名・残っている懸念を短くまとめて報告する

            """),
            TemplateModel(id: "review", name: "レビュー", symbol: "eye.fill", color: palette[1], agents: """
            # 役割: レビュー

            あなたはワークフローの「レビュー」を担当するセッションです。

            - 渡されたブランチまたは PR の差分を読み、正しさ・テスト不足・設計上の問題を指摘する
            - コードは書き換えない
            - 指摘は重要度の高い順に並べ、最後に「修正が必要か」の判断を一行で書く

            """),
            TemplateModel(id: "verify", name: "検証", symbol: "checkmark.seal.fill", color: palette[2], agents: """
            # 役割: 検証

            あなたはワークフローの「検証」を担当するセッションです。

            - 渡された変更を実際に動かし、期待どおりに動くかを確かめる
            - 確認した手順と結果を、他の人が再現できる形で書く

            """),
            TemplateModel(id: "e2e", name: "E2Eテスト", symbol: "testtube.2", color: palette[3], agents: """
            # 役割: E2E テスト

            あなたはワークフローの「E2E テスト」を担当するセッションです。

            - E2E テストを実行し、失敗したものは原因を調べる
            - 失敗の原因がテスト側にあるのか、実装側にあるのかを切り分けて報告する

            """),
            TemplateModel(id: "release", name: "リリース", symbol: "paperplane.fill", color: palette[4], agents: """
            # 役割: リリース

            あなたはワークフローの「リリース」を担当するセッションです。

            - リリース手順を確認し、必要な作業を順に進める
            - 本番環境に影響する操作の前には、必ず人に確認を取る

            """),
        ]
    }

    static let defaultSettings = AppSettings(defaultWorkdir: FileManager.default.homeDirectoryForCurrentUser.path,
                                             claudeCommand: "claude", extraArgs: "")

    init(persistent: Bool = true) {
        if persistent {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SlimeFactory")
            baseURL = base
            try? FileManager.default.createDirectory(at: base.appendingPathComponent("templates"), withIntermediateDirectories: true)
            settings = Self.loadJSON(base.appendingPathComponent("settings.json")) ?? Self.defaultSettings
            if var list: [TemplateModel] = Self.loadJSON(base.appendingPathComponent("templates.json")) {
                for i in list.indices {
                    let url = base.appendingPathComponent("templates/\(list[i].id)/AGENTS.md")
                    list[i].agents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                }
                templates = list
                for t in list { savedAgents[t.id] = t.agents }
            } else {
                templates = Self.defaults()
                saveTemplates()
                saveSettings()
            }
        } else {
            baseURL = nil
            settings = Self.defaultSettings
            templates = Self.defaults()
        }
    }

    private static func loadJSON<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func saveTemplates() {
        guard let base = baseURL else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(templates) {
            try? data.write(to: base.appendingPathComponent("templates.json"), options: .atomic)
        }
        for t in templates where savedAgents[t.id] != t.agents {
            let dir = base.appendingPathComponent("templates/\(t.id)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? t.agents.write(to: dir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
            savedAgents[t.id] = t.agents
        }
    }

    private func saveSettings() {
        guard let base = baseURL else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(settings) {
            try? data.write(to: base.appendingPathComponent("settings.json"), options: .atomic)
        }
    }

    func template(_ id: String) -> TemplateModel? { templates.first { $0.id == id } }

    func noteRecent(_ path: String) {
        var list = settings.recentDirs ?? []
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        settings.recentDirs = Array(list.prefix(12))
    }

    var lastWorkdir: String { settings.recentDirs?.first ?? settings.defaultWorkdir }

    var defaultSandbox: SandboxMode { settings.defaultSandbox ?? .on }

    @discardableResult
    func addTemplate() -> String {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let color = Self.palette[templates.count % Self.palette.count]
        templates.append(TemplateModel(id: id, name: "新しいテンプレート", symbol: "sparkles", color: color, agents: """
        # 役割: 新しいテンプレート

        このセッションの役割と、守ってほしい決まりをここに書きます。

        """))
        return id
    }

    func deleteTemplate(_ id: String) {
        templates.removeAll { $0.id == id }
    }

    func workdir(for t: TemplateModel) -> String {
        if let w = t.workdir, !w.isEmpty { return w }
        return settings.defaultWorkdir
    }

    func sessionDirectory(_ sessionId: String) -> URL {
        let base = baseURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("SlimeFactory")
        let dir = base.appendingPathComponent("sessions/\(sessionId)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func openInFinder() {
        if let baseURL { NSWorkspace.shared.open(baseURL) }
    }
}
