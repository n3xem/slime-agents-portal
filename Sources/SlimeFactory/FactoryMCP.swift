import Foundation

final class FactoryMCP {
    let world: World
    let sessions: SessionManager
    let store: TemplateStore

    init(world: World, sessions: SessionManager, store: TemplateStore) {
        self.world = world
        self.sessions = sessions
        self.store = store
    }

    struct ToolError: Error { let message: String }

    func handle(token: String, method: String, body: Data, reply: @escaping (String, Any?) -> Void) {
        var bubble: SoftBody?
        if token != sessions.server?.mcpToken {
            guard let id = sessions.bodyId(forToken: token), let b = world.body(id) else {
                reply("404 Not Found", nil)
                return
            }
            bubble = b
        }
        let logOn = ProcessInfo.processInfo.environment["SLIME_HOOK_LOG"] != nil
        if logOn {
            FileHandle.standardError.write("[mcp] \(method) \(String(decoding: body.prefix(600), as: UTF8.self))\n".data(using: .utf8)!)
        }
        let reply: (String, Any?) -> Void = { status, json in
            if logOn {
                let text = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0.prefix(300), as: UTF8.self) } ?? ""
                FileHandle.standardError.write("[mcp] -> \(status) \(text)\n".data(using: .utf8)!)
            }
            reply(status, json)
        }
        guard method == "POST" else {
            reply(method == "DELETE" ? "200 OK" : "405 Method Not Allowed", nil)
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) else {
            if ProcessInfo.processInfo.environment["SLIME_HOOK_LOG"] != nil {
                FileHandle.standardError.write("[mcp] unparsable body: \(String(decoding: body.prefix(200), as: UTF8.self))\n".data(using: .utf8)!)
            }
            reply("400 Bad Request", nil)
            return
        }
        if let batch = json as? [[String: Any]] {
            let out = batch.compactMap { respond($0, bubble: bubble) }
            reply(out.isEmpty ? "202 Accepted" : "200 OK", out.isEmpty ? nil : out)
        } else if let req = json as? [String: Any] {
            if let out = respond(req, bubble: bubble) {
                reply("200 OK", out)
            } else {
                reply("202 Accepted", nil)
            }
        } else {
            reply("400 Bad Request", nil)
        }
    }

    private func respond(_ req: [String: Any], bubble: SoftBody?) -> [String: Any]? {
        guard let id = req["id"] else { return nil }
        let method = req["method"] as? String ?? ""
        let params = req["params"] as? [String: Any] ?? [:]
        func ok(_ result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        switch method {
        case "initialize":
            return ok([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "slime-factory", "version": "0.1.0"],
            ])
        case "ping":
            return ok([String: Any]())
        case "tools/list":
            return ok(["tools": bubble == nil ? Self.tools : Self.bubbleTools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let result = try bubble.map { try callBubble($0, name, args) } ?? call(name, args)
                return ok(["content": [["type": "text", "text": Self.text(result)]]])
            } catch let e as ToolError {
                return ok(["content": [["type": "text", "text": e.message]], "isError": true])
            } catch {
                return ok(["content": [["type": "text", "text": "\(error)"]], "isError": true])
            }
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    private static func text(_ value: Any) -> String {
        if let s = value as? String { return s }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    private static let configProps: [String: Any] = [
        "workdir": ["type": "string", "description": "作業ディレクトリの絶対パス。~ も使える"],
        "sandbox": ["type": "string", "enum": SandboxMode.allCases.map(\.rawValue),
                    "description": "inherit: ユーザー設定に従う / off / on / strict: サンドボックス外での実行を許さない"],
        "permission_mode": ["type": "string", "enum": PermissionModes.all.map(\.value),
                            "description": "Claude Code の --permission-mode。空文字はユーザー設定に従う"],
        "worktree": ["type": "boolean", "description": "true なら claude --worktree で専用の git worktree を作って起動する"],
        "chrome": ["type": "string", "enum": ["default", "on", "off"], "description": "Claude in Chrome 連携。default は指定しない、on は --chrome、off は --no-chrome"],
    ]

    static let tools: [[String: Any]] = [
        ["name": "list_templates",
         "description": "バブルのテンプレート（画面上部のスライム）の一覧と、それぞれの既定の設定を返す。",
         "inputSchema": ["type": "object", "properties": [String: Any]()]],
        ["name": "list_bubbles",
         "description": "画面上のバブルの一覧を返す。名前、テンプレート、作業ディレクトリ、サンドボックス、権限モード、worktree、セッションの状態、いまの作業、矢印の送り先と受け取り元を含む。",
         "inputSchema": ["type": "object", "properties": [String: Any]()]],
        ["name": "list_islands",
         "description": "画面上の島（リポジトリのディレクトリを表す領域）の一覧と、中にあるバブルを返す。",
         "inputSchema": ["type": "object", "properties": [String: Any]()]],
        ["name": "create_island",
         "description": "ディレクトリの島を作る。島に置いたバブルは、その島のディレクトリで起動する。同じディレクトリの島があればそれを返す。",
         "inputSchema": ["type": "object",
                         "properties": ["path": ["type": "string", "description": "ディレクトリの絶対パス。~ も使える"]],
                         "required": ["path"]]],
        ["name": "create_bubble",
         "description": "テンプレートのスライムから新しいバブルを作る。island（島のパスか名前）か workdir を指定すると、その島の中に置く（workdir に島がなければ島も作る）。省略した設定はテンプレートの既定に従う。start が true なら Claude Code のセッションもすぐ起動する。",
         "inputSchema": ["type": "object",
                         "properties": configProps.merging([
                             "template": ["type": "string", "description": "テンプレートの id または名前"],
                             "island": ["type": "string", "description": "置く島のパスまたは名前"],
                             "name": ["type": "string", "description": "バブルの名前。SendMessage の宛先になる。省略時はテンプレート名"],
                             "start": ["type": "boolean", "description": "true ならセッションをすぐ起動する"],
                         ]) { a, _ in a },
                         "required": ["template"]]],
        ["name": "configure_bubble",
         "description": "バブルの作業ディレクトリ・サンドボックス・権限モード・worktree を変える。セッションの起動後は、サンドボックスと権限モードだけを restart: true で再起動して反映できる。",
         "inputSchema": ["type": "object",
                         "properties": configProps.merging([
                             "name": ["type": "string"],
                             "restart": ["type": "boolean", "description": "起動済みのセッションを再起動して反映する（会話は --resume で引き継ぐ）"],
                         ]) { a, _ in a },
                         "required": ["name"]]],
        ["name": "connect_bubbles",
         "description": "バブルからバブルへ矢印を引く。矢印の向きにだけ SendMessage で送れる。auto_send が true なら人の承認なしで送れる。",
         "inputSchema": ["type": "object",
                         "properties": ["from": ["type": "string"], "to": ["type": "string"], "auto_send": ["type": "boolean"]],
                         "required": ["from", "to"]]],
        ["name": "disconnect_bubbles",
         "description": "バブル間の矢印を外す。",
         "inputSchema": ["type": "object", "properties": ["from": ["type": "string"], "to": ["type": "string"]],
                         "required": ["from", "to"]]],
        ["name": "start_bubble",
         "description": "バブルの Claude Code セッションを起動する（画面にターミナルは開かない）。",
         "inputSchema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]],
    ]

    static let bubbleTools: [[String: Any]] = [
        ["name": "report_status",
         "description": "このバブルの状態を Slime Factory の画面に表示する。ターンを終える前に必ず呼ぶ。done: 頼まれた作業が終わった / need_decision: 人に方針の選択や前提の確認をしてほしい / blocked: 権限や環境の問題で進められない。",
         "inputSchema": ["type": "object",
                         "properties": [
                             "state": ["type": "string", "enum": ["done", "need_decision", "blocked"]],
                             "summary": ["type": "string", "description": "画面に出す一行の要約。need_decision なら何を決めてほしいか"],
                         ],
                         "required": ["state", "summary"]]],
    ]

    private func callBubble(_ b: SoftBody, _ name: String, _ args: [String: Any]) throws -> Any {
        guard name == "report_status" else { throw ToolError(message: "不明なツール: \(name)") }
        let summary = FactoryBridge.firstLine(string(args, "summary") ?? "", limit: 80)
        let kind: BadgeKind
        switch string(args, "state") ?? "" {
        case "done": kind = .done
        case "need_decision": kind = .needDecision
        case "blocked": kind = .blocked
        default: throw ToolError(message: "state は done / need_decision / blocked のどれかです。")
        }
        world.setBadge(b, kind, summary: summary)
        b.reportedThisTurn = true
        b.activity = Activity(text: summary, symbol: kind == .done ? "checkmark.circle.fill" : "exclamationmark.bubble.fill",
                              time: world.time, finished: true)
        return "画面に表示しました: \(kind.emoji) \(summary)"
    }

    private func string(_ args: [String: Any], _ key: String) -> String? {
        (args[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func bubble(_ name: String?) throws -> SoftBody {
        guard let name, let b = world.bodyNamed(name), !b.isConductor else {
            throw ToolError(message: "バブル「\(name ?? "")」が見つかりません。list_bubbles で名前を確認してください。")
        }
        return b
    }

    private func checkedDirectory(_ raw: String) throws -> String {
        let path = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError(message: "ディレクトリ「\(raw)」がありません。")
        }
        return path
    }

    private func apply(_ args: [String: Any], to b: SoftBody, started: Bool) throws {
        var cfg = b.config
        if let w = string(args, "workdir") {
            if started { throw ToolError(message: "「\(b.name)」は起動済みなので、作業ディレクトリは変えられません。") }
            cfg.workdir = try checkedDirectory(w)
        }
        if let wt = args["worktree"] as? Bool {
            if started { throw ToolError(message: "「\(b.name)」は起動済みなので、worktree の設定は変えられません。") }
            cfg.worktree = wt
        }
        if let sb = string(args, "sandbox") {
            guard let mode = SandboxMode(rawValue: sb) else { throw ToolError(message: "sandbox は inherit / off / on / strict のどれかです。") }
            cfg.sandbox = mode
        }
        if let c = string(args, "chrome") {
            switch c {
            case "default": cfg.chrome = .some(nil)
            case "on": cfg.chrome = .some(true)
            case "off": cfg.chrome = .some(false)
            default: throw ToolError(message: "chrome は default / on / off のどれかです。")
            }
        }
        if let pm = args["permission_mode"] as? String {
            let modes = b.engine == .agy ? AgyModes.all : PermissionModes.all
            guard modes.contains(where: { $0.value == pm }) else {
                throw ToolError(message: "permission_mode「\(pm)」は使えません。")
            }
            cfg.permissionMode = pm
        }
        b.config = cfg
    }

    private func describe(_ b: SoftBody) -> [String: Any] {
        let cfg = sessions.existing(b.id)?.config ?? b.savedSession?.launchConfig ?? sessions.launchConfig(for: b, store: store)
        var d: [String: Any] = [
            "name": b.name,
            "title": b.title ?? "",
            "template": b.isConductor ? "管理" : b.template.name,
            "workdir": cfg.workdir,
            "sandbox": cfg.sandbox.rawValue,
            "permission_mode": cfg.permissionMode,
            "engine": b.engine.rawValue,
            "model": cfg.model ?? "",
            "effort": cfg.effort ?? "",
            "worktree": cfg.worktree,
            "chrome": cfg.chrome.map { $0 ? "on" : "off" } ?? "default",
            "session": "\(sessions.state(b.id))",
            "outgoing": world.outgoing(b.id).map(\.name),
            "incoming": world.incoming(b.id).map(\.name),
            "auto_send_to": world.ropes.filter { $0.from == b.id && $0.autoSend && !$0.retracting }.compactMap { $0.to.flatMap(world.body)?.name },
        ]
        if b.isConductor { d["role"] = "管理" }
        if let a = b.activity { d["activity"] = a.text }
        if let t = b.topic { d["topic"] = t }
        if !b.pending.isEmpty { d["pending_sends"] = b.pending.map { ["to": $0.targetName, "message": $0.message] } }
        return d
    }

    private func call(_ name: String, _ args: [String: Any]) throws -> Any {
        switch name {
        case "list_templates":
            return store.templates.map { t -> [String: Any] in
                [
                    "id": t.id, "name": t.name,
                    "workdir": store.workdir(for: t),
                    "sandbox": (t.sandbox ?? store.defaultSandbox).rawValue,
                    "permission_mode": t.permissionMode ?? "",
                    "engine": (t.engine ?? .claude).rawValue,
                    "model": t.model ?? "",
                    "effort": t.effort ?? "",
                    "worktree": t.worktree ?? true,
                    "chrome": t.chrome.map { $0 ? "on" : "off" } ?? "default",
                    "agents_md_head": String(t.agents.prefix(300)),
                ]
            }
        case "list_bubbles":
            return world.bodies.filter { $0.absorbInto == nil }.map(describe)
        case "list_islands":
            return world.islands.map { i -> [String: Any] in
                ["name": i.name, "path": i.path,
                 "bubbles": world.bodiesInside(i).compactMap { world.body($0)?.name }]
            }
        case "create_island":
            guard let raw = string(args, "path") else { throw ToolError(message: "path を指定してください。") }
            let path = try checkedDirectory(raw)
            let i = world.addIsland(path: path)
            store.noteRecent(path)
            return ["name": i.name, "path": i.path]
        case "create_bubble":
            guard let key = string(args, "template"),
                  let tpl = store.templates.first(where: { $0.id == key || $0.name == key || World.sessionName($0.name) == key }) else {
                throw ToolError(message: "テンプレート「\(string(args, "template") ?? "")」が見つかりません。list_templates で確認してください。")
            }
            var island: Island?
            if let key = string(args, "island") {
                let expanded = (key as NSString).expandingTildeInPath
                island = world.islands.first { $0.path == expanded || $0.name == key }
                if island == nil { throw ToolError(message: "島「\(key)」がありません。list_islands で確認するか、create_island で作ってください。") }
            } else if let w = string(args, "workdir") {
                let path = try checkedDirectory(w)
                island = world.islandFor(path: path) ?? world.addIsland(path: path)
            }
            guard let b = world.spawnFromLump(templateId: tpl.id, name: string(args, "name"), in: island) else {
                throw ToolError(message: "バブルを作れませんでした。")
            }
            if let island { b.config.workdir = island.path }
            do {
                var rest = args
                if island != nil { rest["workdir"] = nil }
                try apply(rest, to: b, started: false)
            } catch {
                world.bodies.removeAll { $0.id == b.id }
                throw error
            }
            if let n = string(args, "name"), !n.isEmpty {
                b.title = n
                b.titleLocked = true
            }
            if args["start"] as? Bool == true { sessions.start(b, store: store) }
            return describe(b)
        case "configure_bubble":
            let b = try bubble(string(args, "name"))
            let started = (sessions.hasStarted(b.id) && sessions.isAlive(b.id))
            try apply(args, to: b, started: started || b.savedSession != nil)
            if let sb = string(args, "sandbox"), let mode = SandboxMode(rawValue: sb) { b.savedSession?.sandbox = mode }
            if let pm = args["permission_mode"] as? String { b.savedSession?.permissionMode = pm }
            if string(args, "chrome") != nil, let c = b.config.chrome { b.savedSession?.chrome = c }
            b.kick(2.5)
            if started {
                if args["restart"] as? Bool == true {
                    sessions.restart(b, store: store)
                    return ["result": "再起動して反映しました（会話は引き継ぎます）", "bubble": describe(b)]
                }
                return ["result": "設定を保存しました。起動中のセッションには、restart: true で再起動するまで反映されません。", "bubble": describe(b)]
            }
            return describe(b)
        case "connect_bubbles":
            let a = try bubble(string(args, "from")), t = try bubble(string(args, "to"))
            guard a.id != t.id else { throw ToolError(message: "同じバブル同士はつなげません。") }
            guard a.engine == .claude, t.engine == .claude else {
                throw ToolError(message: "Antigravity CLI のバブルは矢印でつなげません。")
            }
            let r = world.rope(from: a.id, to: t.id) ?? world.connect(a, t)
            r.autoSend = args["auto_send"] as? Bool ?? r.autoSend
            t.kick(3)
            return ["result": "「\(a.name)」→「\(t.name)」をつなぎました", "auto_send": r.autoSend]
        case "disconnect_bubbles":
            let a = try bubble(string(args, "from")), t = try bubble(string(args, "to"))
            guard let r = world.rope(from: a.id, to: t.id) else { throw ToolError(message: "「\(a.name)」→「\(t.name)」の矢印はありません。") }
            world.removeRope(r)
            return ["result": "矢印を外しました"]
        case "start_bubble":
            let b = try bubble(string(args, "name"))
            sessions.start(b, store: store)
            b.kick(3)
            return describe(b)
        default:
            throw ToolError(message: "不明なツール: \(name)")
        }
    }
}
