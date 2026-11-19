import SwiftUI

extension Color {
    init(_ v: V3, brightness: Float = 1) {
        self.init(red: Double(min(v.x * brightness, 1)), green: Double(min(v.y * brightness, 1)),
                  blue: Double(min(v.z * brightness, 1)))
    }
}

private func springPop(_ t: Float) -> CGFloat {
    if t <= 0 { return 0.001 }
    return CGFloat(1 - exp(-7 * t) * cos(15 * t))
}

struct OverlayView: View {
    let world: World
    let tick: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            mapLayer
                .frame(width: CGFloat(world.size.x), height: CGFloat(world.size.y), alignment: .topLeading)
                .scaleEffect(CGFloat(world.zoom), anchor: .topLeading)
                .offset(x: CGFloat(-world.camera.x * world.zoom), y: CGFloat(-world.camera.y * world.zoom))
            ForEach(world.lumps, id: \.id) { l in
                VStack(spacing: 1) {
                    Image(systemName: l.template.symbol)
                        .font(.system(size: 15, weight: .bold))
                        .overlay(alignment: .topTrailing) {
                            EngineMark(engine: l.template.engine, size: 14)
                                .offset(x: 13, y: -6)
                        }
                    Text(l.template.name)
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.95))
                .shadow(color: .black.opacity(0.45), radius: 1.5, y: 1)
                .scaleEffect(CGFloat(l.scale))
                .position(x: CGFloat(l.com.x), y: CGFloat(l.com.y + 6))
            }
        }
        .frame(width: CGFloat(world.size.x), height: CGFloat(world.size.y), alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var mapLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(world.islands + world.poppingIslands, id: \.id) { i in
                let a = CGFloat(clampf(i.appear, 0, 1.2))
                let fade = Double(max(0, 1 - i.pop * 2.5))
                let bob = CGFloat(sin(world.time * 1.4 + Float(i.id))) * 1.5
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(i.color, brightness: 1.15))
                    Text(i.name)
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    if i.hover > 0.02 {
                        Text((i.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.42))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .opacity(Double(i.hover))
                            .frame(maxWidth: max(0, i.rect.width - 160) * CGFloat(i.hover), alignment: .leading)
                            .clipped()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color(i.color).opacity(0.13 + Double(i.glow) * 0.15))
                        .overlay(Capsule().strokeBorder(Color(i.color).opacity(0.35), lineWidth: 1))
                )
                .fixedSize()
                .frame(width: max(40, i.rect.width - 36), alignment: .leading)
                .scaleEffect(a * (1 + CGFloat(i.pop) * 0.25), anchor: .topLeading)
                .blur(radius: CGFloat(i.pop) * 6)
                .opacity(Double(min(1, a)) * fade)
                .position(x: i.rect.minX + 18 + max(40, i.rect.width - 36) / 2, y: i.rect.minY + Island.headerHeight / 2 + 2 + bob)
                Circle()
                    .fill(Color(i.color).opacity(0.35))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color(i.color).opacity(0.7), lineWidth: 1))
                    .opacity(Double(min(1, a)) * 0.8 * fade)
                    .position(x: i.rect.maxX - 12, y: i.rect.maxY - 12)
            }

            if let c = world.conductor, c.scale > 0.3 {
                Canvas { ctx, _ in
                    let focus: Double = world.hoverBody == c.id ? 1 : 0
                    for b in world.bodies where !b.isConductor && b.engine == .claude && b.absorbInto == nil && b.scale > 0.3 {
                        let d = b.com - c.com
                        let L = len(d)
                        let rc = c.radius * c.scale * 0.95, rb = b.radius * b.scale * 0.95
                        guard L > rc + rb + 10 else { continue }
                        let u = d / L
                        let a = c.com + u * rc, e = b.com - u * rb
                        let sway = sin(world.time * 0.9 + Float(b.id)) * 6
                        let mid = (a + e) * 0.5 + V2(-u.y, u.x) * (L * 0.08 + sway)
                        var path = Path()
                        path.move(to: CGPoint(x: CGFloat(a.x), y: CGFloat(a.y)))
                        path.addQuadCurve(to: CGPoint(x: CGFloat(e.x), y: CGFloat(e.y)), control: CGPoint(x: CGFloat(mid.x), y: CGFloat(mid.y)))
                        let shading = GraphicsContext.Shading.linearGradient(
                            Gradient(colors: [Color(red: 1, green: 0.82, blue: 0.4), Color(b.template.color)]),
                            startPoint: CGPoint(x: CGFloat(a.x), y: CGFloat(a.y)), endPoint: CGPoint(x: CGFloat(e.x), y: CGFloat(e.y)))
                        var g = ctx
                        g.opacity = 0.16 + 0.22 * focus
                        g.stroke(path, with: shading, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 7], dashPhase: CGFloat(-world.time * 14)))
                        let t = (world.time * 0.35 + Float(b.id) * 0.37).truncatingRemainder(dividingBy: 1)
                        let q = a * ((1 - t) * (1 - t)) + mid * (2 * (1 - t) * t) + e * (t * t)
                        let dot = CGRect(x: CGFloat(q.x) - 2.5, y: CGFloat(q.y) - 2.5, width: 5, height: 5)
                        var h = ctx
                        h.opacity = (0.35 + 0.35 * focus) * Double(sin(t * .pi))
                        h.fill(Path(ellipseIn: dot), with: .color(Color(red: 1, green: 0.9, blue: 0.6)))
                    }
                }
                .allowsHitTesting(false)
            }

            Canvas { ctx, _ in
                for rope in world.ropes where rope.to != nil && !rope.retracting {
                    let (p, tan) = rope.point(at: 0.6)
                    if rope.autoSend {
                        let lp = CGPoint(x: CGFloat(p.x - tan.y * 16), y: CGFloat(p.y + tan.x * 16))
                        ctx.draw(Text("自動").font(.system(size: 9, weight: .heavy)).foregroundColor(.white.opacity(0.85)), at: lp)
                    }
                }
            }
            .allowsHitTesting(false)

            ForEach(world.bodies.filter { $0.sandboxMode.boxed && $0.absorbInto == nil }, id: \.id) { b in
                let d = CGFloat(b.radius * b.scale) * 2.8
                let age = world.time - b.domeTime - 0.35
                SandboxDomeView(strict: b.sandboxMode == .strict ? springPop(age * 1.6 - 0.25) : 0,
                                open: b.escapeTime.map { springPop((world.time - $0) * 1.8) * (1 - CGFloat(clampf((world.time - (b.escapeEnd ?? .infinity)) * 3, 0, 1))) } ?? 0)
                    .frame(width: d + SandboxDomeView.pad * 2, height: d + SandboxDomeView.pad * 2)
                    .scaleEffect(springPop(age * 1.6))
                    .opacity(Double(clampf(age * 4, 0, 1)))
                    .position(x: CGFloat(b.com.x), y: CGFloat(b.com.y))
            }

            ForEach(world.bodies, id: \.id) { b in
                VStack(spacing: 2) {
                    FaceView(face: b.face, style: b.faceStyle, tint: Color(b.template.color), time: world.time, royal: b.isConductor)
                    Text("\(Image(systemName: b.template.symbol)) \(b.displayName)")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(b.isConductor ? AnyShapeStyle(royalGold) : AnyShapeStyle(Color.white))
                        .opacity(b.title == nil && !b.isConductor ? 0.6 : 1)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .frame(width: CGFloat(b.radius * 1.75))
                    Text(statusText(b))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .opacity(0.88)
                    HStack(spacing: 3) {
                        if b.sandboxMode == .on || b.sandboxMode == .strict {
                            Image(systemName: b.sandboxMode == .strict ? "lock.shield.fill" : "lock.fill")
                        }
                        if b.usesWorktree { Image(systemName: "arrow.triangle.branch") }
                        if b.dirMismatch { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
                        Text(b.dirName)
                            .lineLimit(1)
                    }
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .opacity(0.7)
                    .frame(maxWidth: CGFloat(b.radius * 1.6))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .opacity(Double(clampf(b.turn * 4 + 0.6, 0, 1)))
                .scaleEffect(x: CGFloat(max(abs(b.turn), 0.001)), y: 1)
                .scaleEffect(CGFloat(max(b.scale, 0.001)))
                .rotationEffect(.radians(Double(clampf(b.angle * 0.8, -0.35, 0.35))))
                .opacity(b.absorbInto == nil ? 1 : Double(max(0, b.scale * 1.5 - 0.3)))
                .position(x: CGFloat(b.com.x), y: CGFloat(b.com.y))
            }

            ForEach(world.bodies.filter { $0.costume != nil && $0.absorbInto == nil }, id: \.id) { b in
                if let costume = b.costume {
                    let r = CGFloat(b.radius * b.scale)
                    CostumeView(costume: costume, time: world.time,
                                pose: b.posing ? CGFloat(clampf((world.time - (b.dressTime ?? world.time) - 0.9) / 0.63, 0, 1)) : 0)
                        .frame(width: r * CostumeView.span, height: r * CostumeView.span)
                        .scaleEffect(x: CGFloat(b.turn < 0 ? min(b.turn, -0.001) : max(b.turn, 0.001)), y: 1)
                        .rotationEffect(.radians(Double(clampf(b.angle * 0.8, -0.35, 0.35))))
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 2)
                        .position(x: CGFloat(b.com.x), y: CGFloat(b.com.y))
                }
            }

            ForEach(world.bodies.filter { $0.dressTime != nil && $0.absorbInto == nil }, id: \.id) { b in
                if let t0 = b.dressTime {
                    SparkleView(age: CGFloat(world.time - t0), seed: b.id)
                        .frame(width: SparkleView.size, height: SparkleView.size)
                        .position(x: CGFloat(b.com.x), y: CGFloat(b.com.y))
                }
            }

            if let c = world.conductor {
                let r = c.radius * c.scale
                let hop = CGFloat(clampf(c.scaleV * 1.4, -6, 12))
                let cw = CGFloat(c.radius) * 1.35, chh = cw * 0.78
                CrownView(time: world.time)
                    .frame(width: cw, height: chh)
                    .scaleEffect(CGFloat(max(c.scale, 0.001)), anchor: .bottom)
                    .rotationEffect(.radians(Double(clampf(c.angle * 0.8, -0.35, 0.35)) - 0.12), anchor: .bottom)
                    .shadow(color: Color(red: 1, green: 0.75, blue: 0.3).opacity(0.45), radius: 6)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 2)
                    .position(x: CGFloat(c.com.x - r * 0.12), y: CGFloat(c.com.y - r * 0.85) - chh * 0.36 - hop)
            }

            ForEach(world.bodies.filter { $0.absorbInto == nil && $0.scale > 0.3 }, id: \.id) { b in
                let r = b.radius * b.scale
                EngineMark(engine: b.engine, size: 20)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .scaleEffect(CGFloat(b.scale))
                    .position(x: CGFloat(b.com.x - r * 0.9), y: CGFloat(b.com.y + r * 0.42))
            }

            ForEach(world.bodies.filter { ($0.activity != nil || $0.topic != nil) && $0.absorbInto == nil }, id: \.id) { b in
                activityBalloon(b)
                    .scaleEffect(CGFloat(max(b.scale, 0.001)), anchor: .bottom)
                    .position(x: CGFloat(b.com.x), y: max(world.visibleRect.minY + 78 / CGFloat(world.zoom), CGFloat(b.com.y - b.radius * b.scale - 30)))
            }

            ForEach(world.bodies.filter { $0.speech != nil && $0.absorbInto == nil }, id: \.id) { b in
                if let s = b.speech { speech(b, s) }
            }

            ForEach(world.bodies.filter { $0.badge != nil && $0.absorbInto == nil }, id: \.id) { b in
                if let badge = b.badge {
                    let age = world.time - badge.time
                    let pulse = badge.kind.needsAttention ? 1 + 0.08 * CGFloat(sin(world.time * 4.5)) : 1
                    let r = b.radius * b.scale
                    let drop = CGFloat(max(0, 1 - age * 3)) * -26
                    Text(badge.kind.emoji)
                        .font(.system(size: 22))
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(RadialGradient(colors: [Color.white.opacity(0.32), Color.black.opacity(0.55)],
                                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: 24))
                                .overlay(Circle().strokeBorder(badge.kind.needsAttention ? Color.orange.opacity(0.85) : Color(b.template.color).opacity(0.7),
                                                               lineWidth: 1.5))
                        )
                        .shadow(color: badge.kind.needsAttention ? .orange.opacity(0.6) : .black.opacity(0.4),
                                radius: badge.kind.needsAttention ? 8 : 4, y: 2)
                        .scaleEffect(springPop(age * 1.6) * pulse)
                        .rotationEffect(.degrees(Double(sin(age * 9) * max(0, 1 - age * 1.5)) * 18))
                        .position(x: CGFloat(b.com.x + r * 0.7), y: CGFloat(b.com.y - r * 0.7) + drop)
                }
            }


            ForEach(Array(world.pops.enumerated()), id: \.offset) { _, pop in
                ConfettiView(age: CGFloat(world.time - pop.time), color: Color(pop.color), seed: pop.seed)
                    .frame(width: ConfettiView.size, height: ConfettiView.size)
                    .position(x: CGFloat(pop.p.x), y: CGFloat(pop.p.y))
            }

            ForEach(world.bodies.filter { !$0.pending.isEmpty }, id: \.id) { b in
                let pills = world.pillLayout(b)
                if let first = pills.first, let p = b.pending.first {
                    let hovered = world.hoverPill.flatMap { $0.0 == b.id && $0.1 < p.options.count ? p.options[$0.1].detail : nil }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: p.isQuestion ? "questionmark.bubble.fill" : p.approvalTitle == nil ? "envelope.fill" : "exclamationmark.shield.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(p.approvalTitle == nil || p.isQuestion ? Color(p.color) : Color.orange)
                            Text(p.isQuestion ? (p.summary.isEmpty ? "質問" : p.summary) : p.approvalTitle ?? "\(p.targetName) へのメッセージ")
                                .font(.system(size: 11, weight: .bold))
                            Spacer(minLength: 0)
                            if b.pending.count > 1 {
                                Text("ほか \(b.pending.count - 1) 件")
                                    .font(.system(size: 10, weight: .semibold))
                                    .opacity(0.6)
                            }
                        }
                        Text(hovered.flatMap { $0.isEmpty ? nil : $0 } ?? p.message)
                            .font(.system(size: 11))
                            .lineLimit(3)
                            .opacity(0.85)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(width: 320, height: 74, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.black.opacity(0.62))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Color(p.color).opacity(0.6), lineWidth: 1))
                    )
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    .scaleEffect(springPop(b.statusTime * 1.4))
                    .position(x: min(max(CGFloat(b.com.x), world.visibleRect.minX + 168), world.visibleRect.maxX - 168), y: first.rect.minY - 45)
                }
                ForEach(pills, id: \.index) { pl in
                    pill(pl, hovered: world.hoverPill.map { $0 == (b.id, pl.index) } ?? false)
                        .scaleEffect(springPop(b.statusTime * 1.4 - Float(pl.index) * 0.09))
                        .position(x: pl.rect.midX, y: pl.rect.midY)
                }
            }

        }
        .frame(width: CGFloat(world.size.x), height: CGFloat(world.size.y), alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func activityBalloon(_ b: SoftBody) -> some View {
        let busy = b.sessionState == .busy
        let stale = b.activity.map { $0.finished && world.time - $0.time > 40 } ?? false
        return VStack(alignment: .leading, spacing: 2) {
            if let topic = b.topic {
                Text(clip(topic, width: 230, size: 10.5))
                    .font(.system(size: 10.5, weight: .bold))
                    .lineLimit(1)
            }
            if let a = b.activity {
                HStack(spacing: 5) {
                    Image(systemName: a.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(b.template.color, brightness: 1.15))
                        .opacity(busy ? 0.55 + 0.45 * Double(abs(sin(world.time * 4))) : 1)
                    Text(clip(a.text, width: 215, size: 10.5))
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .opacity(0.85)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            BalloonShape()
                .fill(Color.black.opacity(0.6))
                .overlay(BalloonShape().stroke(Color(b.template.color).opacity(busy ? 0.75 : 0.4), lineWidth: 1))
        )
        .fixedSize()
        .opacity(stale ? 0.45 : 1)
    }

    private func speech(_ b: SoftBody, _ s: Speech) -> some View {
        let r = CGFloat(b.radius * b.scale)
        let left = CGFloat(b.com.x) + r + 250 > world.visibleRect.maxX
        let age = world.time - s.time
        let wobble: Float = 1 + 0.18 * sin(min(age, 0.6) * 10.5) * exp(-age * 4)
        let pop = CGFloat(max(min(1, age * 7) * wobble, 0.001))
        let bob = CGFloat(sin(world.time * 2.2 + b.phase)) * 2
        return speechBalloon(s.text, tailLeft: !left)
            .scaleEffect(pop, anchor: left ? .trailing : .leading)
            .frame(width: 1, height: 1, alignment: left ? .trailing : .leading)
            .position(x: CGFloat(b.com.x) + (left ? -r - 4 : r + 4), y: CGFloat(b.com.y) - r * 0.45 + bob)
    }

    private func speechBalloon(_ text: String, tailLeft: Bool) -> some View {
        let wide = text.reduce(CGFloat(0)) { $0 + ($1.isASCII ? 0.6 : 1.0) * 12.5 } > 210
        return Text(text)
            .font(.system(size: 12.5, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.12, green: 0.1, blue: 0.18))
            .lineLimit(3)
            .frame(width: wide ? 210 : nil, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(SpeechShape(tailLeft: tailLeft).fill(Color.white.opacity(0.96)))
            .padding(tailLeft ? .leading : .trailing, 9)
            .fixedSize()
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }

    private func clip(_ s: String, width: CGFloat, size: CGFloat) -> String {
        var w: CGFloat = 0
        var out = ""
        for ch in s {
            w += (ch.isASCII ? 0.56 : 1.0) * size
            if w > width { return out + "…" }
            out.append(ch)
        }
        return out
    }

    private func statusText(_ b: SoftBody) -> String {
        let dots = String(repeating: "・", count: Int(world.time * 3) % 3 + 1)
        if let p = b.pending.first { return p.isQuestion ? "質問の答え待ち" : p.approvalTitle == nil ? "送信の承認待ち" : "設定変更の承認待ち" }
        if let badge = b.badge { return badge.kind.label }
        switch b.status {
        case .received: return "メッセージを受信"
        case .idle:
            switch b.sessionState {
            case .none: return b.savedSession != nil ? "クリックで再開" : "クリックで起動"
            case .starting: return "起動中"
            case .waiting: return "入力待ち"
            case .busy: return "作業中" + dots
            case .exited: return "終了"
            }
        }
    }

    private func pill(_ pl: PillLayout, hovered: Bool) -> some View {
        let c = pl.color
        return HStack(spacing: 6) {
            Image(systemName: pl.icon)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 16)
            Text(pl.text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(width: pl.rect.width, height: pl.rect.height)
        .background(
            Capsule()
                .fill(LinearGradient(colors: [Color(c, brightness: pl.recommended ? 0.95 : 0.6),
                                              Color(c, brightness: pl.recommended ? 0.55 : 0.32)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    Capsule()
                        .fill(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)],
                                             startPoint: .top, endPoint: .center))
                        .padding(.horizontal, 6)
                        .padding(.top, 1.5)
                        .padding(.bottom, 13)
                )
                .overlay(Capsule().strokeBorder(.white.opacity(pl.recommended ? 0.55 : 0.25), lineWidth: 1))
        )
        .shadow(color: Color(c).opacity(pl.recommended ? 0.6 : 0.25), radius: pl.recommended ? 10 : 4, y: 2)
        .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
        .scaleEffect(hovered ? 1.07 : 1)
        .brightness(hovered ? 0.08 : 0)
    }
}

struct BalloonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height), cornerRadius: 9)
        let cx = rect.midX
        p.move(to: CGPoint(x: cx - 6, y: rect.maxY))
        p.addLine(to: CGPoint(x: cx, y: rect.maxY + 6))
        p.addLine(to: CGPoint(x: cx + 6, y: rect.maxY))
        return p
    }
}

struct SpeechShape: Shape {
    let tailLeft: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path(roundedRect: rect, cornerRadius: 12)
        let y = rect.minY + min(rect.height * 0.5, 16)
        let x = tailLeft ? rect.minX : rect.maxX
        let s: CGFloat = tailLeft ? -1 : 1
        p.move(to: CGPoint(x: x, y: y - 6))
        p.addQuadCurve(to: CGPoint(x: x + s * 10, y: y + 3), control: CGPoint(x: x + s * 4, y: y))
        p.addQuadCurve(to: CGPoint(x: x, y: y + 5), control: CGPoint(x: x + s * 3, y: y + 4))
        p.closeSubpath()
        return p
    }
}

private let royalGold = LinearGradient(colors: [Color(red: 1, green: 0.93, blue: 0.62), Color(red: 1, green: 0.74, blue: 0.25)],
                                       startPoint: .top, endPoint: .bottom)

struct CrownView: View {
    let time: Float

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height * 0.62
            ctx.translateBy(x: 0, y: size.height * 0.22)
            let base = h * 0.78, band = h * 0.2
            let tips: [CGPoint] = [
                CGPoint(x: w * 0.06, y: h * 0.22), CGPoint(x: w * 0.28, y: h * 0.12), CGPoint(x: w * 0.5, y: h * 0.02),
                CGPoint(x: w * 0.72, y: h * 0.12), CGPoint(x: w * 0.94, y: h * 0.22),
            ]
            let valleys: [CGPoint] = [
                CGPoint(x: w * 0.18, y: h * 0.5), CGPoint(x: w * 0.39, y: h * 0.44),
                CGPoint(x: w * 0.61, y: h * 0.44), CGPoint(x: w * 0.82, y: h * 0.5),
            ]
            var crown = Path()
            crown.move(to: CGPoint(x: w * 0.1, y: base))
            crown.addLine(to: tips[0])
            for i in 0..<4 {
                crown.addLine(to: valleys[i])
                crown.addLine(to: tips[i + 1])
            }
            crown.addLine(to: CGPoint(x: w * 0.9, y: base))
            crown.addQuadCurve(to: CGPoint(x: w * 0.1, y: base), control: CGPoint(x: w * 0.5, y: base + h * 0.1))
            crown.closeSubpath()
            var cap = Path()
            cap.move(to: CGPoint(x: w * 0.13, y: base - band))
            cap.addCurve(to: CGPoint(x: w * 0.87, y: base - band), control1: CGPoint(x: w * 0.12, y: -h * 0.05),
                         control2: CGPoint(x: w * 0.88, y: -h * 0.05))
            cap.closeSubpath()
            ctx.fill(cap, with: .radialGradient(Gradient(colors: [Color(red: 0.95, green: 0.25, blue: 0.32), Color(red: 0.5, green: 0.03, blue: 0.13)]),
                                                center: CGPoint(x: w * 0.4, y: h * 0.2), startRadius: 0, endRadius: w * 0.45))
            let gold = Gradient(colors: [Color(red: 1, green: 0.95, blue: 0.68), Color(red: 1, green: 0.78, blue: 0.3),
                                         Color(red: 0.78, green: 0.5, blue: 0.12)])
            ctx.fill(crown, with: .linearGradient(gold, startPoint: CGPoint(x: w * 0.3, y: 0), endPoint: CGPoint(x: w * 0.6, y: h)))

            var bandPath = Path()
            bandPath.move(to: CGPoint(x: w * 0.1, y: base - band))
            bandPath.addQuadCurve(to: CGPoint(x: w * 0.9, y: base - band), control: CGPoint(x: w * 0.5, y: base - band + h * 0.1))
            bandPath.addLine(to: CGPoint(x: w * 0.9, y: base))
            bandPath.addQuadCurve(to: CGPoint(x: w * 0.1, y: base), control: CGPoint(x: w * 0.5, y: base + h * 0.1))
            bandPath.closeSubpath()
            ctx.fill(bandPath, with: .linearGradient(Gradient(colors: [Color(red: 0.95, green: 0.68, blue: 0.2), Color(red: 0.62, green: 0.36, blue: 0.06)]),
                                                     startPoint: CGPoint(x: 0, y: base - band), endPoint: CGPoint(x: 0, y: base)))
            ctx.stroke(crown, with: .color(Color(red: 0.5, green: 0.3, blue: 0.05).opacity(0.85)), style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))

            let gems: [(CGFloat, Color, CGFloat)] = [
                (0.27, Color(red: 0.2, green: 0.55, blue: 1), 3.2), (0.5, Color(red: 0.95, green: 0.12, blue: 0.25), 4.4),
                (0.73, Color(red: 0.15, green: 0.8, blue: 0.45), 3.2),
            ]
            for (x, c, r) in gems {
                let cy = base - band * 0.45 + h * 0.035
                let rect = CGRect(x: w * x - r, y: cy - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [.white, c, c.opacity(0.8)]),
                                                                    center: CGPoint(x: rect.midX - r * 0.35, y: rect.midY - r * 0.35),
                                                                    startRadius: 0, endRadius: r * 1.3))
                ctx.stroke(Path(ellipseIn: rect), with: .color(Color(red: 0.5, green: 0.3, blue: 0.05)), lineWidth: 0.8)
            }
            for (i, t) in tips.enumerated() {
                let r: CGFloat = i == 2 ? 3.6 : 2.6
                let rect = CGRect(x: t.x - r, y: t.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [.white, Color(red: 0.95, green: 0.92, blue: 0.86)]),
                                                                    center: CGPoint(x: rect.midX - r * 0.3, y: rect.midY - r * 0.3),
                                                                    startRadius: 0, endRadius: r * 1.2))
            }
            let rim = Color(red: 0.5, green: 0.3, blue: 0.05)
            let orb = CGPoint(x: tips[2].x, y: tips[2].y - 3)
            var cross = Path()
            cross.move(to: CGPoint(x: orb.x, y: orb.y - 3))
            cross.addLine(to: CGPoint(x: orb.x, y: orb.y - 12))
            cross.move(to: CGPoint(x: orb.x - 3.4, y: orb.y - 8.4))
            cross.addLine(to: CGPoint(x: orb.x + 3.4, y: orb.y - 8.4))
            ctx.stroke(cross, with: .color(rim), style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
            ctx.stroke(cross, with: .color(Color(red: 1, green: 0.85, blue: 0.4)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            let orbRect = CGRect(x: orb.x - 3.8, y: orb.y - 3.8, width: 7.6, height: 7.6)
            ctx.fill(Path(ellipseIn: orbRect), with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.97, blue: 0.8), Color(red: 1, green: 0.78, blue: 0.3),
                                                                                        Color(red: 0.75, green: 0.48, blue: 0.1)]),
                                                                    center: CGPoint(x: orb.x - 1.2, y: orb.y - 1.2), startRadius: 0, endRadius: 4.6))
            ctx.stroke(Path(ellipseIn: orbRect), with: .color(rim), lineWidth: 0.8)

            let sweep = CGFloat((time * 0.35).truncatingRemainder(dividingBy: 1)) * 2.2 - 0.6
            var gleam = ctx
            gleam.clip(to: crown)
            var streak = Path()
            streak.move(to: CGPoint(x: w * sweep, y: 0))
            streak.addLine(to: CGPoint(x: w * (sweep + 0.12), y: 0))
            streak.addLine(to: CGPoint(x: w * (sweep - 0.08), y: h))
            streak.addLine(to: CGPoint(x: w * (sweep - 0.2), y: h))
            streak.closeSubpath()
            gleam.fill(streak, with: .color(.white.opacity(0.45)))

            let f0 = base - band * 0.1, f1 = base + h * 0.22, dip = h * 0.12
            var fur = Path()
            fur.move(to: CGPoint(x: w * 0.06, y: f0))
            fur.addQuadCurve(to: CGPoint(x: w * 0.94, y: f0), control: CGPoint(x: w * 0.5, y: f0 + dip))
            fur.addQuadCurve(to: CGPoint(x: w * 0.94, y: f1), control: CGPoint(x: w, y: (f0 + f1) / 2))
            fur.addQuadCurve(to: CGPoint(x: w * 0.06, y: f1), control: CGPoint(x: w * 0.5, y: f1 + dip))
            fur.addQuadCurve(to: CGPoint(x: w * 0.06, y: f0), control: CGPoint(x: 0, y: (f0 + f1) / 2))
            fur.closeSubpath()
            ctx.fill(fur, with: .linearGradient(Gradient(colors: [.white, Color(red: 0.84, green: 0.82, blue: 0.9)]),
                                                startPoint: CGPoint(x: 0, y: f0), endPoint: CGPoint(x: 0, y: f1 + dip)))
            ctx.stroke(fur, with: .color(Color(red: 0.62, green: 0.6, blue: 0.7)), lineWidth: 0.8)
            for t: CGFloat in [0.17, 0.39, 0.61, 0.83] {
                let sy = (f0 + f1) / 2 + 2 * t * (1 - t) * dip
                ctx.fill(Path(ellipseIn: CGRect(x: w * t - 1.3, y: sy - 2.2, width: 2.6, height: 4.4)),
                         with: .color(Color(red: 0.1, green: 0.08, blue: 0.12)))
            }

            let twinkle = pow(max(0, sin(time * 2.3)), 8)
            if twinkle > 0.01 {
                let c = tips[2]
                var star = Path()
                let s = 7 * CGFloat(twinkle)
                star.move(to: CGPoint(x: c.x, y: c.y - s))
                star.addQuadCurve(to: CGPoint(x: c.x + s, y: c.y), control: c)
                star.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s), control: c)
                star.addQuadCurve(to: CGPoint(x: c.x - s, y: c.y), control: c)
                star.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s), control: c)
                ctx.fill(star, with: .color(.white.opacity(Double(twinkle))))
            }
        }
    }
}

struct SandboxDomeView: View {
    static let pad: CGFloat = 30
    let strict: CGFloat
    var open: CGFloat = 0

    var body: some View {
        Canvas { ctx, size in
            let w0 = size.width - SandboxDomeView.pad * 2
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2 + SandboxDomeView.pad, dy: 2 + SandboxDomeView.pad)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = rect.width / 2
            let ball = Path(ellipseIn: rect)
            let sd = Double(strict)
            let tint = Color(red: 0.75 - 0.33 * sd, green: 0.92 - 0.2 * sd, blue: 1)
            ctx.fill(ball, with: .radialGradient(
                Gradient(colors: [.white.opacity(0.0), tint.opacity(0.04 + 0.08 * sd), tint.opacity(0.28 + 0.2 * sd)]),
                center: c, startRadius: 0, endRadius: r))
            if strict > 0.01 {
                ctx.drawLayer { l in
                    l.clip(to: ball)
                    let hex: CGFloat = 7.5
                    let w = hex * sqrt(3)
                    let reach = r * .pi / 2
                    func project(_ q: CGPoint) -> CGPoint? {
                        let d = hypot(q.x, q.y)
                        if d >= reach { return nil }
                        if d < 1e-3 { return c }
                        let k = r * sin(d / r) / d
                        return CGPoint(x: c.x + q.x * k, y: c.y + q.y * k)
                    }
                    var row = 0
                    var y = -reach
                    while y <= reach {
                        var x = -reach + (row % 2 == 0 ? 0 : w / 2)
                        while x <= reach {
                            var path = Path()
                            var ok = true
                            for i in 0..<6 {
                                let a = CGFloat(i) * .pi / 3 + .pi / 6
                                guard let p = project(CGPoint(x: x + cos(a) * hex, y: y + sin(a) * hex)) else { ok = false; break }
                                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                            }
                            if ok {
                                path.closeSubpath()
                                let t = min(hypot(x, y) / reach, 1)
                                l.stroke(path, with: .color(Color(red: 0.8, green: 0.92, blue: 1).opacity(sd * Double(0.12 + 0.4 * t * t))), lineWidth: 0.9)
                            }
                            x += w
                        }
                        y += hex * 1.5
                        row += 1
                    }
                }
            }
            let gap = Double(min(max(open, 0), 1.3)) * 34
            let rim = Color(red: 1 - 0.25 * sd, green: 1 - 0.1 * sd, blue: 1).opacity(0.6 + 0.15 * sd)
            if gap > 0.5 {
                var arc = Path()
                arc.addArc(center: c, radius: r, startAngle: .degrees(315 + gap), endAngle: .degrees(315 - gap + 360), clockwise: false)
                ctx.stroke(arc, with: .color(rim), style: StrokeStyle(lineWidth: 1.6 + 0.8 * strict, lineCap: .round))
                for i in 0..<3 {
                    let f = CGFloat(i)
                    let dist = r + (6 + f * 11) * open
                    let ang = (-45 + (f - 1) * 16) * .pi / 180
                    let dr: CGFloat = 4 - f * 0.9
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x + cos(ang) * dist - dr, y: c.y + sin(ang) * dist - dr, width: dr * 2, height: dr * 2)),
                             with: .color(.white.opacity(Double(0.75 - f * 0.18) * Double(min(open, 1)))))
                }
            } else {
                ctx.stroke(ball, with: .color(rim), lineWidth: 1.6 + 0.8 * strict)
            }
            var hl = Path()
            hl.addArc(center: c, radius: w0 * 0.4, startAngle: .degrees(195), endAngle: .degrees(245), clockwise: false)
            ctx.stroke(hl, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            let dot = CGRect(x: c.x - w0 * 0.27, y: c.y - w0 * 0.39, width: 5, height: 5)
            ctx.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.8)))
        }
    }
}

struct ConfettiView: View {
    static let size: CGFloat = 640
    let age: CGFloat
    let color: Color
    let seed: Int

    private static let palette: [Color] = [
        Color(red: 1, green: 0.36, blue: 0.5), Color(red: 1, green: 0.8, blue: 0.2), Color(red: 0.3, green: 0.85, blue: 1),
        Color(red: 0.45, green: 0.9, blue: 0.45), Color(red: 0.7, green: 0.5, blue: 1), Color(red: 1, green: 0.6, blue: 0.25),
    ]

    private func rand(_ i: Int, _ k: Int) -> CGFloat {
        var x = UInt64(truncatingIfNeeded: seed &* 7919 &+ i &* 104_729 &+ k &* 1_299_709)
        x ^= x >> 33
        x = x &* 0xff51afd7ed558ccd
        x ^= x >> 33
        x = x &* 0xc4ceb9fe1a85ec53
        x ^= x >> 33
        return CGFloat(x % 10_000) / 10_000
    }

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let t = age
            if t < 0.35 {
                let k = t / 0.35
                let ring = 20 + 90 * (1 - pow(1 - k, 3))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2)),
                           with: .color(.white.opacity(Double(0.55 * (1 - k)))), lineWidth: 3 * (1 - k) + 0.5)
            }
            for i in 0..<14 {
                let a = rand(i, 1) * 2 * .pi
                let sp = 160 + rand(i, 2) * 220
                let drag = (1 - exp(-3 * t)) / 3
                let p = CGPoint(x: c.x + cos(a) * sp * drag, y: c.y + sin(a) * sp * drag + 260 * t * t)
                let r = (3 + rand(i, 3) * 5) * max(0, 1 - t * 1.4)
                if r > 0.2 {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(color.opacity(0.9)))
                }
            }
            let fade = Double(max(0, min(1, (2.2 - t) / 0.6)))
            for i in 0..<56 {
                let a = -.pi / 2 + (rand(i, 4) - 0.5) * 2.6
                let sp = 420 + rand(i, 5) * 520
                let drag = (1 - exp(-2.2 * t)) / 2.2
                let fall = 160 * t * t
                let sway = sin(t * (5 + rand(i, 6) * 4) + rand(i, 7) * 6) * 10 * t
                let p = CGPoint(x: c.x + cos(a) * sp * drag + sway, y: c.y + sin(a) * sp * drag + fall)
                let spin = t * (6 + rand(i, 8) * 10) + rand(i, 9) * 6
                let w = 4 + rand(i, 10) * 3, h = 7 + rand(i, 11) * 5
                let flip = abs(cos(spin * 0.7))
                var piece = ctx
                piece.translateBy(x: p.x, y: p.y)
                piece.rotate(by: .radians(Double(spin)))
                let col = i % 5 == 0 ? color : Self.palette[i % Self.palette.count]
                piece.fill(Path(CGRect(x: -w / 2, y: -h * flip / 2, width: w, height: max(h * flip, 0.8))),
                           with: .color(col.opacity(fade * (0.75 + 0.25 * Double(flip)))))
            }
        }
        .allowsHitTesting(false)
    }
}
