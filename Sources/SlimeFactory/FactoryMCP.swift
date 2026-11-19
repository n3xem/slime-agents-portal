import Foundation

final class FactoryMCP {
    let world: World
    let sessions: SessionManager
    let store: TemplateStore
    /// 画面のエディタでファイルを開く。開けなかったら理由を投げる。
    var openFile: ((SoftBody, URL) -> Void)?

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
                "serverInfo": ["name": "slime-factory", "version": "0.2.0"],
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

    static let openFileTool: [String: Any] = [
        "name": "open_file",
        "description": "Markdown ファイル（.md）を Slime Factory の画面のエディタで開く。人はそこで編集でき、編集は自動で保存される。人に「開いて」「見せて」と頼まれたときや、書いた文書を人に見てほしいときに使う。いま開ける形式は .md だけ。ほかのパネル（ターミナルなど）を開いていたら、それを閉じてエディタを出す。開く前に、「開く / 開かない」を選ぶダイアログを出して人に確かめる。このツールは確かめている間にすぐ戻り、人が「開く」を押したときに開く。",
        "inputSchema": ["type": "object",
                        "properties": ["path": ["type": "string", "description": "ファイルの絶対パス。~ も使える"]],
                        "required": ["path"]],
    ]

    static let sayTool: [String: Any] = [
        "name": "say",
        "description": "Slime Factory の画面で、このスライムの横に短い吹き出しを出して人に呼びかける。定期的に見回っていて、人に知らせたいこと（Slack に返事をしていない依頼がある、など）を見つけたときに使う。作業の状態の報告には report_status を使う。新しく出すと前の吹き出しは置き換わり、人がこのスライムを開くと消える。text を空にすると消す。",
        "inputSchema": ["type": "object",
                        "properties": ["text": ["type": "string", "description": "吹き出しに出す短い文。80 文字まで。改行より後は出ない"]],
                        "required": ["text"]],
    ]

    static let tools: [[String: Any]] = [
        ["name": "list_templates",
         "description": "テンプレート（画面上部に並ぶテンプレートのスライム）の一覧と、それぞれの既定の設定を返す。",
         "inputSchema": ["type": "object", "properties": [String: Any]()]],
        ["name": "list_bubbles",
         "description": "画面上のスライムの一覧を返す。名前、テンプレート、作業ディレクトリ、サンドボックス、権限モード、worktree、セッションの状態、いまの作業、矢印の送り先と受け取り元を含む。",
         "inputSchema": ["type": "object", "properties": [String: Any]()]],
        ["name": "list_islands",
         "description": "画面上の島（リポジトリのディレクトリを表す領域）の一覧と、中にあるスライムを返す。",
         "inputSchema": ["type": "object", "properties": [String: Any]()]],
        ["name": "create_island",
         "description": "ディレクトリの島を作る。島に置いたスライムは、その島のディレクトリで起動する。同じディレクトリの島があればそれを返す。",
         "inputSchema": ["type": "object",
                         "properties": ["path": ["type": "string", "description": "ディレクトリの絶対パス。~ も使える"]],
                         "required": ["path"]]],
        ["name": "create_bubble",
         "description": "テンプレートのスライムから新しいスライムを作る。island（島のパスか名前）か workdir を指定すると、その島の中に置く（workdir に島がなければ島も作る）。省略した設定はテンプレートの既定に従う。start が true なら Claude Code のセッションもすぐ起動する。サンドボックス・権限モード・Chrome 連携をテンプレートの既定より緩める指定は、人が画面で承認するまで反映されない。",
         "inputSchema": ["type": "object",
                         "properties": configProps.merging([
                             "template": ["type": "string", "description": "テンプレートの id または名前"],
                             "island": ["type": "string", "description": "置く島のパスまたは名前"],
                             "name": ["type": "string", "description": "スライムの名前。画面に出て、SendMessage の宛先にもなる。役割と対象がわかる短い名前（例: 認証の実装、決済APIのレビュー）を付ける。文字・数字・-・_ 以外は - に置き換えて宛先にする。同じ名前があれば末尾に -2 などを付ける。省略時はテンプレート名"],
                             "start": ["type": "boolean", "description": "true ならセッションをすぐ起動する"],
                         ]) { a, _ in a },
                         "required": ["template"]]],
        ["name": "configure_bubble",
         "description": "スライムの作業ディレクトリ・サンドボックス・権限モード・worktree を変える。island を指定すると、スライムをその島へ移す。セッションの起動後は、サンドボックスと権限モードだけを restart: true で再起動して反映できる。サンドボックス・権限モード・Chrome 連携をいまより緩める変更は、人が画面で承認するまで反映されない。",
         "inputSchema": ["type": "object",
                         "properties": configProps.merging([
                             "name": ["type": "string"],
                             "island": ["type": "string", "description": "スライムを移す島のパスまたは名前。起動前なら作業ディレクトリもその島にする"],
                             "restart": ["type": "boolean", "description": "起動済みのセッションを再起動して反映する（会話は --resume で引き継ぐ）"],
                         ]) { a, _ in a },
                         "required": ["name"]]],
        ["name": "connect_bubbles",
         "description": "スライムからスライムへ矢印を引く。矢印の向きにだけ SendMessage で送れる。auto_send が true なら人の承認なしで送れる。auto_send を true にする変更は、人が画面で承認するまで反映されない。",
         "inputSchema": ["type": "object",
                         "properties": ["from": ["type": "string"], "to": ["type": "string"], "auto_send": ["type": "boolean"]],
                         "required": ["from", "to"]]],
        ["name": "disconnect_bubbles",
         "description": "スライム間の矢印を外す。",
         "inputSchema": ["type": "object", "properties": ["from": ["type": "string"], "to": ["type": "string"]],
                         "required": ["from", "to"]]],
        ["name": "start_bubble",
         "description": "スライムの Claude Code セッションを起動する（画面にターミナルは開かない）。",
         "inputSchema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]],
        openFileTool,
        sayTool,
    ]

    static let bubbleTools: [[String: Any]] = [
        ["name": "report_status",
         "description": "このスライムの状態を Slime Factory の画面に表示する。ターンを終える前に必ず呼ぶ。done: 頼まれた作業が終わった / need_decision: 人に方針の選択や前提の確認をしてほしい / blocked: 権限や環境の問題で進められない。",
         "inputSchema": ["type": "object",
                         "properties": [
                             "state": ["type": "string", "enum": ["done", "need_decision", "blocked"]],
                             "summary": ["type": "string", "description": "画面に出す一行の要約。need_decision なら何を決めてほしいか"],
                         ],
                         "required": ["state", "summary"]]],
        openFileTool,
        sayTool,
    ]

    private func open(_ b: SoftBody, _ args: [String: Any]) throws -> Any {
        guard let raw = string(args, "path"), !raw.isEmpty else { throw ToolError(message: "path を指定してください。") }
        let path = (raw as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw ToolError(message: "path は絶対パスで指定してください（~ も使えます）。") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            throw ToolError(message: "いま開けるのは Markdown（.md）だけです。")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw ToolError(message: "ファイル「\(raw)」がありません。")
        }
        guard let openFile else { throw ToolError(message: "画面の準備ができていないため開けませんでした。") }
        openFile(b, url)
        return "「\(url.lastPathComponent)」を開くか人に確かめています。人が「開く」を押すと画面のエディタで開きます: \(url.path)"
    }

    private func callBubble(_ b: SoftBody, _ name: String, _ args: [String: Any]) throws -> Any {
        if name == "open_file" { return try open(b, args) }
        if name == "say" { return say(b, args) }
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
            throw ToolError(message: "スライム「\(name ?? "")」が見つかりません。list_bubbles で名前を確認してください。")
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
        b.config = try applied(args, to: b, started: started)
    }

    private func persist(_ args: [String: Any], to b: SoftBody) {
        if let sb = string(args, "sandbox"), let mode = SandboxMode(rawValue: sb) { b.savedSession?.sandbox = mode }
        if let pm = args["permission_mode"] as? String { b.savedSession?.permissionMode = pm }
        if string(args, "chrome") != nil, let c = b.config.chrome { b.savedSession?.chrome = c }
    }

    private func effective(_ b: SoftBody) -> LaunchConfig {
        sessions.existing(b.id)?.config ?? sessions.existingAgy(b.id)?.config ?? b.savedSession?.launchConfig
            ?? sessions.launchConfig(for: b, store: store)
    }

    private static func sandboxRank(_ m: SandboxMode) -> Int {
        switch m {
        case .off: return 0
        case .inherit: return 1
        case .on: return 2
        case .strict: return 3
        }
    }

    private static func permissionRank(_ v: String) -> Int {
        switch v {
        case "plan", "manual", "dontAsk": return 0
        case "": return 1
        case "acceptEdits", "accept-edits": return 2
        case "auto": return 3
        case "bypassPermissions": return 4
        default: return 4
        }
    }

    private func permissionLabel(_ v: String, engine: Engine) -> String {
        (engine == .agy ? AgyModes.all : PermissionModes.all).first { $0.value == v }?.label ?? v
    }

    private func loosening(_ args: [String: Any], for b: SoftBody) -> (keys: Set<String>, lines: [String]) {
        let cur = effective(b)
        var keys = Set<String>(), lines: [String] = []
        if let sb = string(args, "sandbox"), let mode = SandboxMode(rawValue: sb),
           Self.sandboxRank(mode) < Self.sandboxRank(cur.sandbox) {
            keys.insert("sandbox")
            lines.append("サンドボックス: \(cur.sandbox.short) → \(mode.short)")
        }
        if let pm = args["permission_mode"] as? String,
           Self.permissionRank(pm) > Self.permissionRank(cur.permissionMode) {
            keys.insert("permission_mode")
            lines.append("権限モード: \(permissionLabel(cur.permissionMode, engine: b.engine)) → \(permissionLabel(pm, engine: b.engine))")
        }
        if let c = string(args, "chrome"), (c == "on" && cur.chrome != true) || (c == "default" && cur.chrome == false) {
            keys.insert("chrome")
            lines.append("Chrome 連携: \(cur.chrome.map { $0 ? "オン" : "オフ" } ?? "既定") → \(c == "on" ? "オン" : "既定")")
        }
        return (keys, lines)
    }

    private func requestApproval(_ b: SoftBody, title: String, lines: [String], onDecision: @escaping (Bool) -> Void) {
        let p = PendingSend(targetId: b.id, targetName: b.displayName, ropeId: -1, message: lines.joined(separator: "\n"), summary: "",
                            color: V3(0.95, 0.55, 0.3), approvalTitle: title, resolver: onDecision)
        world.addPending(p, to: b)
    }

    private func applied(_ args: [String: Any], to b: SoftBody, started: Bool) throws -> BubbleConfig {
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
        return cfg
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
        if b.pending.contains(where: { !$0.isQuestion }) { d["pending_sends"] = b.pending.filter { !$0.isQuestion }.map { ["to": $0.targetName, "message": $0.message] } }
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
                throw ToolError(message: "スライムを作れませんでした。")
            }
            if let island { b.config.workdir = island.path }
            var rest = args
            if island != nil { rest["workdir"] = nil }
            let risky = loosening(rest, for: b)
            do {
                _ = try applied(rest, to: b, started: false)
                try apply(rest.filter { !risky.keys.contains($0.key) }, to: b, started: false)
            } catch {
                world.bodies.removeAll { $0.id == b.id }
                throw error
            }
            if let n = string(args, "name"), !n.isEmpty {
                b.title = n
                b.titleLocked = true
            }
            let start = args["start"] as? Bool == true
            if !risky.keys.isEmpty {
                let riskyArgs = rest.filter { risky.keys.contains($0.key) }
                requestApproval(b, title: "管理が「\(b.displayName)」の設定を緩めようとしています", lines: risky.lines) { [weak self, weak b] ok in
                    guard let self, let b else { return }
                    if ok { try? self.apply(riskyArgs, to: b, started: false) }
                    if start { self.sessions.start(b, store: self.store) }
                }
                var d = describe(b)
                d["approval"] = "次の変更は人の承認待ちです。承認されるまで反映されません（start も承認の判断のあとに行います）: " + risky.lines.joined(separator: "、")
                return d
            }
            if start { sessions.start(b, store: store) }
            return describe(b)
        case "configure_bubble":
            let b = try bubble(string(args, "name"))
            let started = (sessions.hasStarted(b.id) && sessions.isAlive(b.id))
            let locked = started || b.savedSession != nil
            var moveNote: String?
            if let key = string(args, "island") {
                let expanded = (key as NSString).expandingTildeInPath
                guard let target = world.islands.first(where: { $0.path == expanded || $0.name == key }) else {
                    throw ToolError(message: "島「\(key)」がありません。list_islands で確認するか、create_island で作ってください。")
                }
                if !locked { b.config.workdir = target.path }
                world.send(b, to: target)
                moveNote = locked
                    ? "「\(target.name)」の島へ移しましたが、起動済みのため作業ディレクトリは \(effective(b).workdir) のままです。"
                    : "「\(target.name)」の島へ移し、作業ディレクトリを \(target.path) にしました。"
            }
            let risky = loosening(args, for: b)
            _ = try applied(args, to: b, started: locked)
            let safeArgs = args.filter { !risky.keys.contains($0.key) }
            try apply(safeArgs, to: b, started: locked)
            persist(safeArgs, to: b)
            b.kick(2.5)
            if !risky.keys.isEmpty {
                let riskyArgs = args.filter { risky.keys.contains($0.key) }
                let restart = args["restart"] as? Bool == true
                requestApproval(b, title: "管理が「\(b.displayName)」の設定を緩めようとしています", lines: risky.lines) { [weak self, weak b] ok in
                    guard let self, let b, ok else { return }
                    try? self.apply(riskyArgs, to: b, started: locked)
                    self.persist(riskyArgs, to: b)
                    if restart && self.sessions.isAlive(b.id) { self.sessions.restart(b, store: self.store) }
                }
                return ["result": "次の変更は人の承認待ちです。承認されるまで反映されません\(restart ? "（再起動も承認のあとに行います）" : "")。"
                            + risky.lines.joined(separator: "、")
                            + (safeArgs.keys.contains { $0 != "name" && $0 != "restart" } ? "。それ以外の変更は反映しました。" : ""),
                        "bubble": describe(b)]
            }
            if let moveNote, !started { return ["result": moveNote, "bubble": describe(b)] }
            if started {
                if args["restart"] as? Bool == true {
                    sessions.restart(b, store: store)
                    return ["result": "再起動して反映しました（会話は引き継ぎます）", "bubble": describe(b)]
                }
                return ["result": (moveNote ?? "") + "設定を保存しました。起動中のセッションには、restart: true で再起動するまで反映されません。", "bubble": describe(b)]
            }
            return describe(b)
        case "connect_bubbles":
            let a = try bubble(string(args, "from")), t = try bubble(string(args, "to"))
            guard a.id != t.id else { throw ToolError(message: "同じスライム同士はつなげません。") }
            guard a.engine == .claude, t.engine == .claude else {
                throw ToolError(message: "Antigravity CLI のスライムは矢印でつなげません。")
            }
            let r = world.rope(from: a.id, to: t.id) ?? world.connect(a, t)
            t.kick(3)
            if let auto = args["auto_send"] as? Bool {
                if auto && !r.autoSend {
                    requestApproval(a, title: "管理が「\(a.displayName)」→「\(t.displayName)」を承認なしで送るようにしようとしています",
                                    lines: ["この矢印の送信で「送る / 止める」の確認を出さなくなります"]) { [weak r] ok in
                        if ok { r?.autoSend = true }
                    }
                    return ["result": "「\(a.name)」→「\(t.name)」をつなぎました。承認なしで送る設定は、人の承認待ちです。承認されるまで、送信のたびに人が確認します。",
                            "auto_send": false]
                }
                r.autoSend = auto
            }
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
        case "open_file":
            guard let c = world.conductor else { throw ToolError(message: "管理スライムが見つかりません。") }
            return try open(c, args)
        case "say":
            guard let c = world.conductor else { throw ToolError(message: "管理スライムが見つかりません。") }
            return say(c, args)
        default:
            throw ToolError(message: "不明なツール: \(name)")
        }
    }

    private func say(_ b: SoftBody, _ args: [String: Any]) -> Any {
        let text = FactoryBridge.firstLine(string(args, "text") ?? "", limit: 80)
        guard !text.isEmpty else {
            b.speech = nil
            return "吹き出しを消しました。"
        }
        b.speech = Speech(text: text, time: world.time)
        b.glow = 1
        b.kick(2)
        return "吹き出しを出しました: \(text)"
    }
}
