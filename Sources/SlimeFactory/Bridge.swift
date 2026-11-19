import Foundation

final class FactoryBridge {
    let world: World
    let sessions: SessionManager
    let store: TemplateStore

    init(world: World, sessions: SessionManager, store: TemplateStore) {
        self.world = world
        self.sessions = sessions
        self.store = store
    }

    private func refreshContext(token: String, transcript: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let tokens = Self.contextTokens(transcript: transcript) else { return }
            DispatchQueue.main.async {
                guard let self, let id = self.sessions.bodyId(forToken: token), let b = self.world.body(id) else { return }
                b.contextTokens = tokens
            }
        }
    }

    func preloadContext(_ bodies: [SoftBody]) {
        let items = bodies.compactMap { b in b.savedSession.map { (b.id, $0.sessionId) } }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for (id, sessionId) in items {
                guard let path = CanvasStore.transcriptPath(sessionId), let tokens = Self.contextTokens(transcript: path) else { continue }
                DispatchQueue.main.async {
                    guard let b = self?.world.body(id), b.contextTokens == 0 else { return }
                    b.contextTokens = tokens
                }
            }
        }
    }

    static func contextTokens(transcript path: String) -> Int? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let end = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: end > 2_000_000 ? end - 2_000_000 : 0)
        guard let data = try? fh.readToEnd() else { return nil }
        let marker = Data("\"usage\"".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant", obj["isSidechain"] as? Bool != true,
                  let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any] else { continue }
            return ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
        }
        return nil
    }

    func handle(token: String, event: String, body: [String: Any], respond: @escaping HookServer.Respond) {
        if let path = body["transcript_path"] as? String { refreshContext(token: token, transcript: path) }
        if event == "start" {
            sessions.markReady(token: token)
            respond(nil)
            return
        }
        guard let id = sessions.bodyId(forToken: token), let b = world.body(id), b.absorbInto == nil else {
            respond(nil)
            return
        }
        switch event {
        case "prompt":
            world.clearBadge(b)
            closeEscape(b)
            if let prompt = body["prompt"] as? String {
                let line = Self.firstLine(prompt)
                if b.title == nil, !b.isConductor, let t = Self.shortTitle(prompt) { b.title = t }
                b.activity = Activity(text: "依頼: " + line, symbol: "text.bubble.fill", time: world.time)
                b.topic = b.topic ?? line
            }
            respond(context(for: b))
        case "pre": preSend(b, body, respond)
        case "ask": ask(b, body, respond)
        case "post": postSend(b, body, respond)
        case "tool":
            let tool = body["tool_name"] as? String ?? ""
            let input = body["tool_input"] as? [String: Any] ?? [:]
            let (text, symbol) = Self.describeTool(tool, input)
            b.activity = Activity(text: text, symbol: symbol, time: world.time)
            if tool == "Bash", input["dangerouslyDisableSandbox"] as? Bool == true, b.sandboxMode == .on {
                b.activity = Activity(text: "サンドボックスの外で" + text, symbol: "exclamationmark.triangle.fill", time: world.time)
                b.escapeTime = world.time
                b.escapeEnd = nil
            } else {
                closeEscape(b)
            }
            switch tool {
            case "AskUserQuestion":
                let q = ((input["questions"] as? [[String: Any]])?.first?["question"] as? String) ?? ""
                world.setBadge(b, .question, summary: Self.firstLine(q))
            case "ExitPlanMode":
                world.setBadge(b, .plan)
            case "mcp__slime-factory__report_status", "mcp__slime-factory__say":
                break
            default:
                world.clearBadge(b)
            }
            respond(nil)
        case "posttool":
            closeEscape(b)
            if b.badge?.kind == .permission { world.clearBadge(b) }
            respond(nil)
        case "stopfail":
            closeEscape(b)
            let msg = (body["error"] as? String) ?? (body["message"] as? String) ?? ""
            world.setBadge(b, .error, summary: Self.firstLine(msg))
            respond(nil)
        case "notify":
            let message = body["message"] as? String ?? ""
            switch body["notification_type"] as? String ?? "" {
            case "permission_prompt":
                world.setBadge(b, .permission, summary: Self.firstLine(message))
            case "idle_prompt":
                if b.badge == nil { world.setBadge(b, .idle) }
            default:
                if !message.isEmpty {
                    b.activity = Activity(text: Self.firstLine(message), symbol: "bell.fill", time: world.time)
                    b.glow = 1
                    b.kick(2)
                }
            }
            respond(nil)
        case "stop":
            closeEscape(b)
            let last = body["last_assistant_message"] as? String ?? ""
            if !b.reportedThisTurn && b.badge == nil && !last.isEmpty {
                b.activity = Activity(text: Self.firstLine(last), symbol: "checkmark.circle.fill", time: world.time, finished: true)
                world.setBadge(b, Self.looksLikeQuestion(last) ? .needDecision : .done, summary: Self.firstLine(last))
            }
            b.reportedThisTurn = false
            b.glow = max(b.glow, 0.8)
            b.kick(1.5)
            respond(nil)
        default: respond(nil)
        }
    }

    static func shortTitle(_ prompt: String) -> String? {
        guard var line = prompt.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        if line.hasPrefix("/") { return nil }
        while line.hasPrefix("@"), let sp = line.firstIndex(of: " ") { line = String(line[line.index(after: sp)...]) }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*>`「」『』\"' 　"))
        for sep in ["。", "、", "！", "？", "!", "?", ". ", ",", "：", ":"] {
            if let r = line.range(of: sep), line.distance(from: line.startIndex, to: r.lowerBound) >= 4 {
                line = String(line[..<r.lowerBound])
            }
        }
        var width: Double = 0
        var out = ""
        for ch in line {
            width += ch.isASCII ? 0.55 : 1
            if width > 14 { return out + "…" }
            out.append(ch)
        }
        return out.isEmpty ? nil : out
    }

    static func looksLikeQuestion(_ s: String) -> Bool {
        guard let line = s.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }) else {
            return false
        }
        return ["?", "？", "か。", "か？", "ますか", "でしょうか"].contains { line.hasSuffix($0) }
    }

    static func firstLine(_ s: String, limit: Int = 60) -> String {
        let line = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.allSatisfy { "#-*>`".contains($0) } } ?? ""
        let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*>` "))
        return cleaned.count > limit ? String(cleaned.prefix(limit)) + "…" : cleaned
    }

    static func describeTool(_ name: String, _ input: [String: Any]) -> (String, String) {
        func str(_ k: String) -> String { (input[k] as? String) ?? "" }
        func file(_ k: String) -> String { (str(k) as NSString).lastPathComponent }
        let result: (String, String)
        switch name {
        case "Bash", "PowerShell":
            let d = str("description")
            result = ("実行: " + (d.isEmpty ? firstLine(str("command"), limit: 48) : d), "terminal.fill")
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            result = ("編集: " + file(input["file_path"] != nil ? "file_path" : "notebook_path"), "pencil")
        case "Read": result = ("読む: " + file("file_path"), "doc.text.fill")
        case "Grep": result = ("検索: " + str("pattern"), "magnifyingglass")
        case "Glob": result = ("ファイルを探す: " + str("pattern"), "folder.fill")
        case "WebSearch": result = ("Web 検索: " + str("query"), "globe")
        case "WebFetch": result = ("Web を読む: " + (URL(string: str("url"))?.host ?? str("url")), "globe")
        case "Agent", "Task": result = ("サブエージェント: " + str("description"), "person.2.fill")
        case "SendMessage": result = ("送信: " + str("to"), "paperplane.fill")
        case "ListAgents": result = ("送り先を確認", "person.3.fill")
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet": result = ("タスクを整理", "checklist")
        case "Skill": result = ("スキル: " + str("skill"), "sparkles")
        case "AskUserQuestion": result = ("質問しています", "questionmark.bubble.fill")
        case "ExitPlanMode": result = ("計画の確認待ち", "list.bullet.clipboard.fill")
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                result = ("MCP: " + parts.dropFirst().joined(separator: " "), "puzzlepiece.fill")
            } else {
                result = (name, "gearshape.fill")
            }
        }
        let t = result.0
        return (t.count > 60 ? String(t.prefix(60)) + "…" : t, result.1)
    }

    private func describe(_ list: [SoftBody]) -> String {
        list.isEmpty ? "なし" : list.map { b in
            b.title.map { "「\($0)」（宛先: \(b.name)、テンプレート: \(b.template.name)）" } ?? "「\(b.name)」（テンプレート: \(b.template.name)）"
        }.joined(separator: "、")
    }

    private func context(for b: SoftBody) -> [String: Any] {
        let text = """
        Slime Factory: このスライムの名前は「\(b.name)」です。矢印の送り先: \(describe(world.outgoing(b.id)))。受け取り元: \(describe(world.incoming(b.id)))。管理セッション「\(world.conductor?.name ?? "管理")」には、矢印がなくても報告を送れます。
        """
        return ["hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": text]]
    }

    private static func decision(_ allow: Bool, _ reason: String) -> [String: Any] {
        ["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": allow ? "allow" : "deny",
            "permissionDecisionReason": reason,
        ]]
    }

    private func preSend(_ b: SoftBody, _ body: [String: Any], _ respond: @escaping HookServer.Respond) {
        let input = body["tool_input"] as? [String: Any] ?? [:]
        let to = (input["to"] as? String) ?? ""
        let message = (input["message"] as? String) ?? ""
        let summary = (input["summary"] as? String) ?? ""
        let allowed = world.outgoing(b.id)
        let allowedText = allowed.isEmpty ? "このスライムから出ている矢印はありません。人に報告して終えてください。"
            : "送れる相手: \(allowed.map { "「\($0.name)」" }.joined(separator: "、"))。"

        if to.hasPrefix("uds:") {
            respond(Self.decision(false, "Slime Factory: 宛先はスライムの名前で指定してください。\(allowedText)"))
            return
        }
        guard let target = world.bodyNamed(to) else {
            respond(Self.decision(false, "Slime Factory: 「\(to)」は Slime Factory のスライムではないため、送れません。\(allowedText)"))
            return
        }
        if target.id != b.id && (b.isConductor || target.isConductor) {
            ensureRunning(target) {
                respond(Self.decision(true, "Slime Factory: 管理セッションとの送受信は許可されています。"))
            }
            return
        }
        guard target.id != b.id, let rope = world.rope(from: b.id, to: target.id) else {
            respond(Self.decision(false, "Slime Factory: 「\(b.name)」から「\(target.name)」への矢印がないため、送れません。\(allowedText)"))
            return
        }
        let deliver = { [weak self] in
            self?.ensureRunning(target) {
                respond(Self.decision(true, "Slime Factory: 「\(target.name)」への送信が承認されました。"))
            }
        }
        if rope.autoSend {
            deliver()
            return
        }
        let pending = PendingSend(targetId: target.id, targetName: target.displayName, ropeId: rope.id, message: message,
                                  summary: summary, color: target.template.color) { ok in
            if ok {
                deliver()
            } else {
                respond(Self.decision(false, "Slime Factory: 人が「\(target.name)」への送信を止めました。メッセージは届いていません。"))
            }
        }
        world.addPending(pending, to: b)
    }

    private func closeEscape(_ b: SoftBody) {
        if b.escapeTime != nil && b.escapeEnd == nil { b.escapeEnd = world.time }
    }

    private func ask(_ b: SoftBody, _ body: [String: Any], _ respond: @escaping HookServer.Respond) {
        let input = body["tool_input"] as? [String: Any] ?? [:]
        guard let questions = input["questions"] as? [[String: Any]], questions.count == 1, let q = questions.first,
              q["multiSelect"] as? Bool != true, let text = q["question"] as? String,
              let opts = q["options"] as? [[String: Any]], (1...4).contains(opts.count) else {
            respond(nil)
            return
        }
        let labels = opts.compactMap { $0["label"] as? String }
        guard labels.count == opts.count else {
            respond(nil)
            return
        }
        let p = PendingSend(targetId: b.id, targetName: b.displayName, ropeId: -1, message: text,
                            summary: q["header"] as? String ?? "", color: b.template.color) { _ in respond(nil) }
        p.options = zip(labels, opts).map { ($0, $1["description"] as? String ?? "") }
        p.onPick = { [weak self, weak b] i in
            var updated = input
            updated["answers"] = [text: labels[i]]
            if let self, let b { self.world.clearBadge(b) }
            respond(["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": "Slime Factory: 人が画面で「\(labels[i])」を選びました。",
                "updatedInput": updated,
            ]])
        }
        world.addPending(p, to: b)
    }

    private func ensureRunning(_ target: SoftBody, then: @escaping () -> Void) {
        if sessions.isReady(target.id) {
            then()
            return
        }
        if !sessions.isAlive(target.id) {
            sessions.start(target, store: store)
        }
        target.kick(4)
        let deadline = Date().addingTimeInterval(1700)
        func poll() {
            if sessions.isReady(target.id) {
                then()
            } else if Date() > deadline || target.absorbInto != nil {
                then()
            } else {
                target.glow = 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
            }
        }
        poll()
    }

    private func postSend(_ b: SoftBody, _ body: [String: Any], _ respond: @escaping HookServer.Respond) {
        let input = body["tool_input"] as? [String: Any] ?? [:]
        if let to = input["to"] as? String, let target = world.bodyNamed(to) {
            if world.rope(from: b.id, to: target.id) != nil {
                world.launchDroplet(from: b.id, to: target.id)
            } else {
                target.kick(4)
                target.glow = 1
                target.status = .received
                target.statusTime = 0
                b.kick(2)
            }
        }
        respond(nil)
    }
}
