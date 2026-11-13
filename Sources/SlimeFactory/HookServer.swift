import Foundation
import Network

final class HookServer {
    typealias Respond = ([String: Any]?) -> Void
    typealias Handler = (_ token: String, _ event: String, _ body: [String: Any], _ respond: @escaping Respond) -> Void

    private let listener: NWListener
    private let queue = DispatchQueue(label: "slime.hook-server")
    private(set) var port: UInt16 = 0
    var handler: Handler?
    var mcpHandler: ((_ token: String, _ method: String, _ body: Data, _ reply: @escaping (_ status: String, _ json: Any?) -> Void) -> Void)?
    let mcpToken = UUID().uuidString.lowercased()
    var mcpURL: String { "http://localhost:\(port)/mcp/\(mcpToken)" }
    func bubbleMCPURL(token: String) -> String { "http://localhost:\(port)/mcp/\(token)" }

    init() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        port = listener.port?.rawValue ?? 0
    }

    func url(token: String, event: String) -> String {
        "http://localhost:\(port)/hook/\(token)/\(event)"
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data(), sentContinue: false)
    }

    private func log(_ s: String) {
        if ProcessInfo.processInfo.environment["SLIME_HOOK_LOG"] != nil {
            FileHandle.standardError.write("[hook] \(s)\n".data(using: .utf8)!)
        }
    }

    private func receive(_ conn: NWConnection, buffer: Data, sentContinue: Bool) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            var continued = sentContinue
            switch Self.parse(buf) {
            case .complete(let method, let path, let body):
                self.dispatch(conn, method: method, path: path, body: body)
                return
            case .needContinue:
                if !continued {
                    continued = true
                    conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                }
            case .incomplete:
                break
            case .invalid:
                self.log("invalid request")
                self.send(conn, status: "400 Bad Request", json: nil)
                return
            }
            if done || error != nil || buf.count > 32 << 20 {
                self.log("connection ended before a full request (\(buf.count) bytes)")
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf, sentContinue: continued)
            }
        }
    }

    private enum Parsed {
        case complete(String, String, Data)
        case needContinue
        case incomplete
        case invalid
    }

    private static func parse(_ buf: Data) -> Parsed {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        let head = String(decoding: buf[buf.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return .invalid }
        var length = 0
        var chunked = false
        var expectContinue = false
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "content-length" { length = Int(value) ?? 0 }
            if key == "transfer-encoding" && value.contains("chunked") { chunked = true }
            if key == "expect" && value == "100-continue" { expectContinue = true }
        }
        let rest = Data(buf[headerEnd.upperBound...])
        let method = String(parts[0]), path = String(parts[1])
        if chunked {
            var body = Data()
            var idx = rest.startIndex
            while true {
                guard let lineEnd = rest[idx...].range(of: Data("\r\n".utf8)) else { return expectContinue && rest.isEmpty ? .needContinue : .incomplete }
                let sizeText = String(decoding: rest[idx..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return .invalid }
                let start = lineEnd.upperBound
                if size == 0 { return .complete(method, path, body) }
                guard rest.endIndex - start >= size + 2 else { return .incomplete }
                body.append(rest[start..<(start + size)])
                idx = start + size + 2
            }
        }
        if rest.count >= length { return .complete(method, path, Data(rest.prefix(length))) }
        return expectContinue && rest.isEmpty ? .needContinue : .incomplete
    }

    private func dispatch(_ conn: NWConnection, method: String, path: String, body: Data) {
        log("\(method) \(path.split(separator: "/").prefix(1).joined())/…/\(path.split(separator: "/").last ?? "") \(body.count)B")
        let comps = path.split(separator: "/").map(String.init)
        if comps.count == 2, comps[0] == "mcp" {
            let token = comps[1]
            let reply: (String, Any?) -> Void = { [weak self] status, json in
                self?.queue.async { self?.send(conn, status: status, json: json) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let h = self?.mcpHandler else { reply("503 Service Unavailable", nil); return }
                h(token, method, body, reply)
            }
            return
        }
        guard comps.count == 3, comps[0] == "hook" else {
            send(conn, status: "404 Not Found", json: nil)
            return
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let token = comps[1], event = comps[2]
        var answered = false
        let respond: Respond = { [weak self] out in
            guard let self else { return }
            self.queue.async {
                if answered { return }
                answered = true
                self.send(conn, status: "200 OK", json: out)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let handler = self?.handler else { respond(nil); return }
            handler(token, event, json, respond)
        }
    }

    private func send(_ conn: NWConnection, status: String, json: Any?) {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }
}
