import SwiftUI

struct EngineMark: View {
    let engine: Engine
    var size: CGFloat = 18

    var body: some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let r = min(sz.width, sz.height) / 2
            ctx.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: sz.width, height: sz.height)), with: .color(Color(white: 0.08).opacity(0.92)))
            ctx.stroke(Path(ellipseIn: CGRect(x: 0.5, y: 0.5, width: sz.width - 1, height: sz.height - 1)),
                       with: .color(.white.opacity(0.22)), lineWidth: 1)
            switch engine {
            case .claude:
                let orange = Color(red: 0.85, green: 0.47, blue: 0.34)
                let rays = 11
                for i in 0..<rays {
                    let a = Double(i) / Double(rays) * 2 * .pi - .pi / 2
                    let len = r * (i % 2 == 0 ? 0.72 : 0.56)
                    let w = r * 0.13
                    let dir = CGPoint(x: cos(a), y: sin(a))
                    let n = CGPoint(x: -dir.y, y: dir.x)
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + n.x * w, y: c.y + n.y * w))
                    p.addLine(to: CGPoint(x: c.x + dir.x * len, y: c.y + dir.y * len))
                    p.addLine(to: CGPoint(x: c.x - n.x * w, y: c.y - n.y * w))
                    p.closeSubpath()
                    ctx.fill(p, with: .color(orange))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.14, y: c.y - r * 0.14, width: r * 0.28, height: r * 0.28)), with: .color(orange))
            case .agy:
                var arch = Path()
                arch.move(to: CGPoint(x: c.x - r * 0.52, y: c.y + r * 0.46))
                arch.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r * 0.5), control: CGPoint(x: c.x - r * 0.36, y: c.y - r * 0.5))
                arch.addQuadCurve(to: CGPoint(x: c.x + r * 0.52, y: c.y + r * 0.46), control: CGPoint(x: c.x + r * 0.36, y: c.y - r * 0.5))
                let g = Gradient(colors: [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.62, green: 0.4, blue: 0.95),
                                          Color(red: 0.92, green: 0.3, blue: 0.35), Color(red: 0.98, green: 0.74, blue: 0.1)])
                ctx.stroke(arch, with: .linearGradient(g, startPoint: CGPoint(x: c.x - r * 0.5, y: c.y + r * 0.5),
                                                       endPoint: CGPoint(x: c.x + r * 0.5, y: c.y + r * 0.5)),
                           style: StrokeStyle(lineWidth: r * 0.24, lineCap: .round, lineJoin: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.1, y: c.y + r * 0.2, width: r * 0.2, height: r * 0.2)),
                         with: .color(Color(red: 0.2, green: 0.75, blue: 0.45)))
            }
        }
        .frame(width: size, height: size)
        .help(engine.label)
    }
}

struct AgyStatusChip: View {
    @ObservedObject var session: AgySession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { _ in
            let (text, c): (String, Color) = {
                switch session.state {
                case .busy: return ("作業中", .orange)
                case .waiting: return ("入力待ち", .green)
                case .exited: return ("終了", .gray)
                case .starting: return ("起動中", .yellow)
                case .none: return ("未起動", .gray)
                }
            }()
            HStack(spacing: 6) {
                Circle().fill(c).frame(width: 7, height: 7).shadow(color: c, radius: 3)
                Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(0.07)))
        }
    }
}

struct AgyPanel: View {
    @ObservedObject var session: AgySession
    var title: String?
    let close: () -> Void

    private var color: Color { session.template.swiftColor }

    var body: some View {
        PanelChrome(color: color) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    TemplateBadge(symbol: session.template.symbol, color: color)
                    EngineMark(engine: .agy, size: 16).offset(x: 4, y: 4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? session.template.name)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Text("Antigravity CLI · \((session.config.workdir as NSString).abbreviatingWithTildeInPath)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ConfigBadge(symbol: "lock.fill", text: session.config.sandbox == .on ? "サンドボックス: オン" : "サンドボックス: オフ",
                                    active: session.config.sandbox == .on)
                        ConfigBadge(symbol: "hand.raised.fill",
                                    text: session.config.permissionMode.isEmpty ? "モード: 既定" : "モード: " + session.config.permissionMode,
                                    active: !session.config.permissionMode.isEmpty)
                        if let m = session.config.model, !m.isEmpty {
                            ConfigBadge(symbol: "cpu", text: m, active: true)
                        }
                        if let e = session.config.effort, !e.isEmpty {
                            ConfigBadge(symbol: "gauge.with.dots.needle.50percent", text: "effort: " + e, active: true)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                AgyStatusChip(session: session)
                CloseButton(action: close)
            }
        } content: {
            ZStack {
                TerminalHost(terminal: session.view)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                if session.exited {
                    VStack(spacing: 12) {
                        Text(session.everStarted
                             ? "セッションは終了しました" + (session.exitCode.map { "（終了コード \($0)）" } ?? "")
                             : "セッションはまだ起動していません")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Button(session.everStarted ? "もう一度起動（会話は引き継ぐ）" : "起動") { session.start() }
                            .buttonStyle(.borderedProminent)
                            .tint(color)
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.75)))
                }
            }
        }
    }
}
