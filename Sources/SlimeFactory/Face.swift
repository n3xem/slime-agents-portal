import SwiftUI

struct FacePose {
    var open: Float = 1
    var happy: Float = 0
    var brow: Float = 0
    var tilt: Float = 0
    var smile: Float = 0.35
    var mouth: Float = 0
    var blush: Float = 0.25

    static func mix(_ a: FacePose, _ b: FacePose, _ t: Float) -> FacePose {
        FacePose(open: mixf(a.open, b.open, t), happy: mixf(a.happy, b.happy, t), brow: mixf(a.brow, b.brow, t),
                 tilt: mixf(a.tilt, b.tilt, t), smile: mixf(a.smile, b.smile, t), mouth: mixf(a.mouth, b.mouth, t),
                 blush: mixf(a.blush, b.blush, t))
    }
}

struct FaceState {
    var pose = FacePose(open: 0.05, smile: 0.25)
    var vel = FacePose(open: 0, happy: 0, brow: 0, tilt: 0, smile: 0, mouth: 0, blush: 0)
    var look = V2(0, 0)
    var lookGoal = V2(0, 0)
    var nextGlance: Float = 0
    var blink: Float = 0
    var nextBlink: Float = 0
    var doubleBlink = false
    var surprise: Float = 0
    var wasGrabbed = false
    var lastStatus: BodyStatus = .idle

    mutating func update(_ b: SoftBody, world: World, dt: Float) {
        let t = world.time
        if nextBlink == 0 { nextBlink = t + Float.random(in: 0.5...3) }

        if b.grabbed && !wasGrabbed { surprise = 1 }
        if b.status == .received && lastStatus != .received { surprise = 1 }
        if len(b.vcom) > 750 { surprise = max(surprise, 0.8) }
        wasGrabbed = b.grabbed
        lastStatus = b.status
        surprise = max(0, surprise - dt * 1.4)

        var goal = FaceState.target(b)
        if surprise > 0 {
            let shock = FacePose(open: 1.3, happy: 0, brow: 0.9, tilt: 0, smile: 0.1, mouth: 0.7, blush: goal.blush)
            goal = FacePose.mix(goal, shock, smooth(0, 0.35, surprise))
        }
        spring(&pose.open, &vel.open, goal.open, dt, k: 150, c: 18)
        spring(&pose.happy, &vel.happy, goal.happy, dt, k: 90, c: 15)
        spring(&pose.brow, &vel.brow, goal.brow, dt, k: 110, c: 16)
        spring(&pose.tilt, &vel.tilt, goal.tilt, dt, k: 90, c: 15)
        spring(&pose.smile, &vel.smile, goal.smile, dt, k: 120, c: 13)
        spring(&pose.mouth, &vel.mouth, goal.mouth, dt, k: 160, c: 14)
        spring(&pose.blush, &vel.blush, goal.blush, dt, k: 40, c: 11)

        let toMouse = world.mouse - b.com
        let d = len(toMouse)
        if b.grabbed {
            lookGoal = clampLen(b.vcom / 500, 1)
        } else if d < 320 && d > 1 {
            lookGoal = toMouse / d * min(1, d / 90)
        } else if t > nextGlance {
            switch (b.badge?.kind, b.sessionState) {
            case (.some(let k), _) where k.needsAttention || k == .plan:
                lookGoal = V2(0.55, -0.75)
                nextGlance = t + Float.random(in: 1.2...2.4)
            case (.none, .busy):
                lookGoal = V2(lookGoal.x > 0 ? -0.7 : 0.7, 0.35)
                nextGlance = t + Float.random(in: 0.45...0.9)
            default:
                lookGoal = Float.random(in: 0...1) < 0.45 ? V2(0, 0) : V2(Float.random(in: -0.8...0.8), Float.random(in: -0.5...0.4))
                nextGlance = t + Float.random(in: 1.8...4.5)
            }
        }
        if !b.pending.isEmpty && !b.grabbed && d >= 320 { lookGoal = V2(0, 0.85) }
        look = mixv(look, lookGoal, min(1, dt * 11))

        if t > nextBlink {
            blink = 1
            if doubleBlink {
                doubleBlink = false
                nextBlink = t + 0.28
            } else {
                doubleBlink = Float.random(in: 0...1) < 0.18
                let calm: Float = b.sessionState == .waiting || b.badge?.kind == .idle ? 1.6 : 1
                nextBlink = t + Float.random(in: 2.2...5.5) * calm
            }
        }
        blink = max(0, blink - dt * 7)
    }

    private func spring(_ x: inout Float, _ v: inout Float, _ goal: Float, _ dt: Float, k: Float, c: Float) {
        v += (k * (goal - x) - c * v) * dt
        x += v * dt
    }

    var eyeOpen: Float {
        let b = blink > 0.5 ? (1 - blink) * 2 : blink * 2
        return max(0, pose.open * (1 - b))
    }

    static func target(_ b: SoftBody) -> FacePose {
        if b.grabbed { return FacePose(open: 1.2, happy: 0, brow: 0.5, tilt: -0.1, smile: 0.7, mouth: 0.45, blush: 0.6) }
        if b.posing { return FacePose(open: 1.1, happy: 1, brow: 0.2, tilt: -0.3, smile: 1, mouth: 0.5, blush: 0.9) }
        if !b.pending.isEmpty { return FacePose(open: 1.05, happy: 0, brow: 0.5, tilt: 0.45, smile: 0.05, mouth: 0.12, blush: 0.3) }
        if let kind = b.badge?.kind {
            switch kind {
            case .done: return FacePose(open: 1, happy: 1, brow: 0, tilt: 0, smile: 1, mouth: 0.35, blush: 0.65)
            case .needDecision, .question:
                return FacePose(open: 1.15, happy: 0, brow: 0.8, tilt: 0.6, smile: -0.05, mouth: 0.22, blush: 0.3)
            case .blocked: return FacePose(open: 0.85, happy: 0, brow: 0.9, tilt: 0.85, smile: -0.6, mouth: 0, blush: 0.15)
            case .permission: return FacePose(open: 1.2, happy: 0, brow: 0.6, tilt: 0.3, smile: 0.1, mouth: 0.18, blush: 0.3)
            case .plan: return FacePose(open: 1, happy: 0, brow: 0.55, tilt: -0.15, smile: 0.3, mouth: 0, blush: 0.3)
            case .error: return FacePose(open: 0.7, happy: 0, brow: 1, tilt: 1, smile: -0.85, mouth: 0.1, blush: 0)
            case .idle: return FacePose(open: 0.45, happy: 0, brow: 0, tilt: 0, smile: 0.25, mouth: 0, blush: 0.25)
            }
        }
        let woke = b.hover > 0.5
        switch b.sessionState {
        case .none:
            return woke ? FacePose(open: 1.05, happy: 0, brow: 0.3, tilt: 0, smile: 0.5, mouth: 0.15, blush: 0.4)
                        : FacePose(open: 0.05, happy: 0, brow: 0, tilt: 0, smile: 0.25, mouth: 0, blush: 0.3)
        case .starting: return FacePose(open: 1.1, happy: 0, brow: 0.4, tilt: 0, smile: 0.3, mouth: 0.2, blush: 0.3)
        case .busy: return FacePose(open: 0.78, happy: 0, brow: 0.55, tilt: -0.35, smile: 0.1, mouth: 0, blush: 0.2)
        case .waiting: return FacePose(open: 0.95, happy: 0, brow: 0, tilt: 0, smile: 0.45, mouth: 0, blush: 0.3)
        case .exited: return FacePose(open: 0, happy: 0, brow: 0, tilt: 0, smile: 0, mouth: 0, blush: 0)
        }
    }
}

enum FaceStyle: String, Codable, CaseIterable {
    case standard, shoujo, shounen, cat, dot

    var label: String {
        switch self {
        case .standard: return "標準"
        case .shoujo: return "少女漫画"
        case .shounen: return "少年漫画"
        case .cat: return "ねこ"
        case .dot: return "ゆるい点目"
        }
    }
}

private let faceInk = Color(red: 0.08, green: 0.07, blue: 0.12).opacity(0.85)
private let blushPink = Color(red: 1, green: 0.45, blue: 0.55)

private struct FaceFrame {
    let c: CGPoint
    let p: FacePose
    let look: CGPoint
    let open: CGFloat
    let happy: CGFloat
    let shut: CGFloat
    let time: CGFloat

    init(face: FaceState, center: CGPoint, time: Float) {
        c = center
        p = face.pose
        look = CGPoint(x: CGFloat(face.look.x) * 2.6, y: CGFloat(face.look.y) * 1.8)
        open = CGFloat(face.eyeOpen)
        happy = CGFloat(clampf(face.pose.happy, 0, 1))
        shut = 1 - CGFloat(smooth(0.06, 0.3, face.eyeOpen))
        self.time = CGFloat(time)
    }

    func eye(_ s: CGFloat, spread: CGFloat) -> CGPoint {
        CGPoint(x: c.x + s * spread + look.x, y: c.y + look.y)
    }

    var mouthCenter: CGPoint { CGPoint(x: c.x + look.x * 0.6, y: c.y + 9 + look.y * 0.4) }
}

struct FaceView: View {
    let face: FaceState
    let style: FaceStyle
    let tint: Color
    let time: Float
    var royal = false

    var body: some View {
        Canvas { ctx, size in
            let f = FaceFrame(face: face, center: CGPoint(x: size.width / 2, y: size.height / 2 - 2), time: time)
            switch style {
            case .standard: drawStandard(&ctx, f)
            case .shoujo: drawShoujo(&ctx, f, tint: tint)
            case .shounen: drawShounen(&ctx, f)
            case .cat: drawCat(&ctx, f)
            case .dot: drawDot(&ctx, f)
            }
            if royal { drawMustache(&ctx, f) }
        }
        .frame(width: 64, height: 30)
    }
}

private func stroke(_ ctx: inout GraphicsContext, _ path: Path, _ width: CGFloat, alpha: CGFloat = 1, color: Color = faceInk) {
    var g = ctx
    g.opacity = Double(alpha)
    g.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
}

private func arc(_ a: CGPoint, _ b: CGPoint, _ control: CGPoint) -> Path {
    var p = Path()
    p.move(to: a)
    p.addQuadCurve(to: b, control: control)
    return p
}

private func drawBlush(_ ctx: inout GraphicsContext, _ f: FaceFrame, dx: CGFloat, w: CGFloat, h: CGFloat, alpha: CGFloat) {
    guard f.p.blush > 0.02 else { return }
    for s: CGFloat in [-1, 1] {
        let r = CGRect(x: f.c.x + s * dx - w / 2, y: f.c.y + 5, width: w, height: h)
        ctx.fill(Path(ellipseIn: r), with: .color(blushPink.opacity(Double(CGFloat(f.p.blush) * alpha))))
    }
}

private func drawClosed(_ ctx: inout GraphicsContext, _ f: FaceFrame, _ e: CGPoint, w: CGFloat, width: CGFloat) {
    guard f.shut > 0.02 && f.happy < 0.98 else { return }
    stroke(&ctx, arc(CGPoint(x: e.x - w, y: e.y - 0.5), CGPoint(x: e.x + w, y: e.y - 0.5), CGPoint(x: e.x, y: e.y + w * 0.9)),
           width, alpha: f.shut * (1 - f.happy))
}

private func drawHappy(_ ctx: inout GraphicsContext, _ f: FaceFrame, _ e: CGPoint, w: CGFloat, width: CGFloat) {
    guard f.happy > 0.02 else { return }
    stroke(&ctx, arc(CGPoint(x: e.x - w, y: e.y + 1.5), CGPoint(x: e.x + w, y: e.y + 1.5), CGPoint(x: e.x, y: e.y - w * 1.25)),
           width, alpha: f.happy)
}

private func drawBrow(_ ctx: inout GraphicsContext, _ f: FaceFrame, _ e: CGPoint, _ s: CGFloat, y: CGFloat, half: CGFloat,
                      width: CGFloat, tilt: CGFloat, alpha: CGFloat) {
    guard alpha > 0.05 else { return }
    var br = Path()
    br.move(to: CGPoint(x: e.x - s * half - f.look.x * 0.5, y: y - tilt))
    br.addLine(to: CGPoint(x: e.x + s * half - f.look.x * 0.5, y: y + tilt))
    stroke(&ctx, br, width, alpha: min(1, alpha))
}

private func drawMouth(_ ctx: inout GraphicsContext, _ f: FaceFrame, scale k: CGFloat, width: CGFloat) {
    let m = f.mouthCenter
    let p = f.p
    let w: CGFloat = (5.5 + CGFloat(max(0, p.smile)) * 1.5) * k
    let curve = CGFloat(p.smile) * 4.5 * k
    let gap = CGFloat(max(0, p.mouth)) * 6.5 * k
    if gap > 0.8 {
        var mouth = Path()
        mouth.move(to: CGPoint(x: m.x - w, y: m.y))
        mouth.addQuadCurve(to: CGPoint(x: m.x + w, y: m.y), control: CGPoint(x: m.x, y: m.y + curve * 0.4 - gap * 0.3))
        mouth.addQuadCurve(to: CGPoint(x: m.x - w, y: m.y), control: CGPoint(x: m.x, y: m.y + curve + gap * 1.6))
        mouth.closeSubpath()
        var g = ctx
        g.fill(mouth, with: .color(faceInk))
        g.clip(to: mouth)
        g.fill(Path(ellipseIn: CGRect(x: m.x - w * 0.55, y: m.y + gap * 0.55 + curve * 0.5, width: w * 1.1, height: gap * 1.2)),
               with: .color(Color(red: 1, green: 0.42, blue: 0.5).opacity(0.85)))
    } else {
        stroke(&ctx, arc(CGPoint(x: m.x - w, y: m.y), CGPoint(x: m.x + w, y: m.y), CGPoint(x: m.x, y: m.y + curve)), width)
    }
}

private func drawMustache(_ ctx: inout GraphicsContext, _ f: FaceFrame) {
    let x = f.c.x + f.look.x * 0.6, y = f.c.y + 5 + f.look.y * 0.4
    let wiggle = CGFloat(sin(f.time * 1.7)) * 0.6
    var m = Path()
    for s: CGFloat in [-1, 1] {
        m.move(to: CGPoint(x: x, y: y))
        m.addQuadCurve(to: CGPoint(x: x + s * 14, y: y + 4.4), control: CGPoint(x: x + s * 5, y: y + 6.4))
        m.addQuadCurve(to: CGPoint(x: x + s * 18.5, y: y - 2 - wiggle), control: CGPoint(x: x + s * 19.5, y: y + 4))
        m.addQuadCurve(to: CGPoint(x: x + s * 13, y: y + 2), control: CGPoint(x: x + s * 16.4, y: y + 1.6))
        m.addQuadCurve(to: CGPoint(x: x, y: y + 0.8), control: CGPoint(x: x + s * 6.5, y: y + 0.4))
        m.closeSubpath()
    }
    ctx.fill(m, with: .color(Color(red: 0.2, green: 0.12, blue: 0.08)))
    ctx.stroke(m, with: .color(Color(red: 0.2, green: 0.12, blue: 0.08)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
}

private func sparkle(_ ctx: inout GraphicsContext, _ p: CGPoint, size r: CGFloat, alpha: CGFloat) {
    var s = Path()
    s.move(to: CGPoint(x: p.x, y: p.y - r))
    s.addQuadCurve(to: CGPoint(x: p.x + r, y: p.y), control: p)
    s.addQuadCurve(to: CGPoint(x: p.x, y: p.y + r), control: p)
    s.addQuadCurve(to: CGPoint(x: p.x - r, y: p.y), control: p)
    s.addQuadCurve(to: CGPoint(x: p.x, y: p.y - r), control: p)
    ctx.fill(s, with: .color(.white.opacity(Double(alpha))))
}

private func drawStandard(_ ctx: inout GraphicsContext, _ f: FaceFrame) {
    drawBlush(&ctx, f, dx: 15, w: 9, h: 5, alpha: 0.45)
    for s: CGFloat in [-1, 1] {
        let e = f.eye(s, spread: 9)
        let h = max(0.9, 9 * f.open)
        drawClosed(&ctx, f, e, w: 4, width: 2)
        if f.happy < 0.98 && f.shut < 0.98 {
            var g = ctx
            g.opacity = Double((1 - f.happy) * (1 - f.shut))
            let r = CGRect(x: e.x - 3.6, y: e.y - h / 2, width: 7.2, height: h)
            g.fill(Path(roundedRect: r, cornerRadius: min(3.6, h / 2)), with: .color(faceInk))
            if h > 4 {
                g.fill(Path(ellipseIn: CGRect(x: e.x - 2.2, y: e.y - h / 2 + 1.4, width: 2.4, height: 2.4)), with: .color(.white.opacity(0.9)))
            }
        }
        drawHappy(&ctx, f, e, w: 4, width: 2.2)
        drawBrow(&ctx, f, e, s, y: f.c.y - 9 - CGFloat(f.p.brow) * 1.6, half: 3.8, width: 1.8,
                 tilt: CGFloat(f.p.tilt) * 2.4, alpha: CGFloat(f.p.brow))
    }
    drawMouth(&ctx, f, scale: 1, width: 2)
}

private func drawShoujo(_ ctx: inout GraphicsContext, _ f: FaceFrame, tint: Color) {
    drawBlush(&ctx, f, dx: 17, w: 10, h: 5, alpha: 0.5)
    if f.p.blush > 0.3 {
        for s: CGFloat in [-1, 1] {
            for k in 0..<3 {
                let x = f.c.x + s * 17 + CGFloat(k - 1) * 2.6
                var l = Path()
                l.move(to: CGPoint(x: x + 1, y: f.c.y + 6))
                l.addLine(to: CGPoint(x: x - 0.6, y: f.c.y + 9))
                stroke(&ctx, l, 0.8, alpha: CGFloat(f.p.blush) * 0.7, color: blushPink)
            }
        }
    }
    let worried = CGFloat(smooth(0.35, 0.6, f.p.tilt)) * CGFloat(min(1, f.p.brow))
    for s: CGFloat in [-1, 1] {
        let e = f.eye(s, spread: 10.5)
        let w: CGFloat = 9.5
        let h = max(1, 13 * f.open)
        let a = (1 - f.happy) * (1 - f.shut)
        if f.shut > 0.02 && f.happy < 0.98 {
            let alpha = f.shut * (1 - f.happy)
            stroke(&ctx, arc(CGPoint(x: e.x - 5, y: e.y), CGPoint(x: e.x + 5, y: e.y), CGPoint(x: e.x, y: e.y + 4)), 1.8, alpha: alpha)
            for k in 0..<3 {
                let x = e.x + CGFloat(k - 1) * 3
                var l = Path()
                l.move(to: CGPoint(x: x, y: e.y + 2.2))
                l.addLine(to: CGPoint(x: x + s * 0.6, y: e.y + 4.4))
                stroke(&ctx, l, 1, alpha: alpha)
            }
        }
        if a > 0.02 {
            var g = ctx
            g.opacity = Double(a)
            let r = CGRect(x: e.x - w / 2, y: e.y - h / 2, width: w, height: h)
            let shape = Path(ellipseIn: r)
            g.fill(shape, with: .linearGradient(Gradient(colors: [faceInk, tint]), startPoint: CGPoint(x: e.x, y: r.minY + h * 0.2),
                                                endPoint: CGPoint(x: e.x, y: r.maxY)))
            g.stroke(shape, with: .color(faceInk), lineWidth: 1.1)
            if h > 5 {
                let wob = sin(f.time * 9 + s) * worried * 0.8
                g.fill(Path(ellipseIn: CGRect(x: e.x - 3.8 + wob, y: r.minY + 1.6, width: 4, height: 4)), with: .color(.white))
                g.fill(Path(ellipseIn: CGRect(x: e.x + 1.3 - wob, y: r.maxY - 4.2, width: 1.9, height: 1.9)), with: .color(.white.opacity(0.85)))
                let tw = 0.5 + 0.5 * sin(f.time * 3 + s * 1.7)
                sparkle(&g, CGPoint(x: e.x + 1.8, y: r.minY + 3.4), size: 1.4 + 0.9 * tw, alpha: 0.55 + 0.45 * tw)
                if worried > 0.05 {
                    stroke(&g, arc(CGPoint(x: e.x - 3.5, y: r.maxY - 1.6), CGPoint(x: e.x + 3.5, y: r.maxY - 1.6),
                                   CGPoint(x: e.x, y: r.maxY + 0.4)), 1.1, alpha: worried * (0.6 + 0.4 * abs(sin(f.time * 5))), color: .white)
                }
            }
            var lid = Path()
            lid.move(to: CGPoint(x: e.x - w / 2 - 0.6, y: e.y - h / 2 + 1.6))
            lid.addQuadCurve(to: CGPoint(x: e.x + w / 2 + 0.6, y: e.y - h / 2 + 1.6), control: CGPoint(x: e.x, y: e.y - h / 2 - 2.4))
            stroke(&g, lid, 2.2)
            let o = CGPoint(x: e.x + s * (w / 2), y: e.y - h / 2 + 2.4)
            for k in 0..<2 {
                var l = Path()
                l.move(to: CGPoint(x: o.x - s * CGFloat(k) * 1.6, y: o.y - CGFloat(k) * 1.2))
                l.addLine(to: CGPoint(x: o.x + s * (3.2 - CGFloat(k)), y: o.y - 2.6 - CGFloat(k) * 1.4))
                stroke(&g, l, 1.2)
            }
        }
        if f.happy > 0.02 {
            stroke(&ctx, arc(CGPoint(x: e.x - 5, y: e.y + 1.5), CGPoint(x: e.x + 5, y: e.y + 1.5), CGPoint(x: e.x, y: e.y - 5.5)), 1.9, alpha: f.happy)
            var l = Path()
            l.move(to: CGPoint(x: e.x + s * 4.6, y: e.y))
            l.addLine(to: CGPoint(x: e.x + s * 7, y: e.y - 1.6))
            stroke(&ctx, l, 1.2, alpha: f.happy)
        }
        drawBrow(&ctx, f, e, s, y: f.c.y - 12.5 - CGFloat(f.p.brow) * 1.2, half: 3.4, width: 1,
                 tilt: CGFloat(f.p.tilt) * 1.8, alpha: CGFloat(f.p.brow) * 0.8)
    }
    if f.happy > 0.3 {
        let spots: [(CGFloat, CGFloat, CGFloat)] = [(-25, -7, 0), (24, -9, 1.3), (27, 5, 2.4), (-23, 7, 3.6)]
        for (dx, dy, ph) in spots {
            let tw = 0.5 + 0.5 * sin(f.time * 4 + ph)
            sparkle(&ctx, CGPoint(x: f.c.x + dx, y: f.c.y + dy), size: 1.5 + 2 * tw, alpha: (f.happy - 0.3) * 1.4 * tw)
        }
    }
    drawMouth(&ctx, f, scale: 0.55, width: 1.6)
}

private func drawShounen(_ ctx: inout GraphicsContext, _ f: FaceFrame) {
    drawBlush(&ctx, f, dx: 16, w: 8, h: 3.5, alpha: 0.3)
    for s: CGFloat in [-1, 1] {
        let e = f.eye(s, spread: 9.5)
        let h = max(0.8, 9 * f.open)
        drawClosed(&ctx, f, e, w: 4.6, width: 2.6)
        let a = (1 - f.happy) * (1 - f.shut)
        if a > 0.02 {
            var g = ctx
            g.opacity = Double(a)
            var shape = Path()
            shape.move(to: CGPoint(x: e.x - s * 4.6, y: e.y - h * 0.22))
            shape.addLine(to: CGPoint(x: e.x + s * 5.2, y: e.y - h * 0.55 - 0.6))
            shape.addQuadCurve(to: CGPoint(x: e.x + s * 4.2, y: e.y + h * 0.35), control: CGPoint(x: e.x + s * 5.6, y: e.y + h * 0.1))
            shape.addQuadCurve(to: CGPoint(x: e.x - s * 4.6, y: e.y + h * 0.4), control: CGPoint(x: e.x, y: e.y + h * 0.55))
            shape.closeSubpath()
            g.fill(shape, with: .color(.white.opacity(0.95)))
            var inner = g
            inner.clip(to: shape)
            let pc = CGPoint(x: e.x + f.look.x * 0.5, y: e.y + f.look.y * 0.4)
            inner.fill(Path(ellipseIn: CGRect(x: pc.x - 2.6, y: pc.y - 3, width: 5.2, height: 6)), with: .color(faceInk))
            inner.fill(Path(ellipseIn: CGRect(x: pc.x - 1.6, y: pc.y - 2.2, width: 1.6, height: 1.6)), with: .color(.white))
            g.stroke(shape, with: .color(faceInk), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
        if f.happy > 0.02 {
            var l = Path()
            l.move(to: CGPoint(x: e.x - 4.6, y: e.y + 2))
            l.addLine(to: CGPoint(x: e.x, y: e.y - 3))
            l.addLine(to: CGPoint(x: e.x + 4.6, y: e.y + 2))
            stroke(&ctx, l, 2.6, alpha: f.happy)
        }
        let tilt = CGFloat(clampf(f.p.tilt * 1.2 - 0.55, -1, 1)) * (1 - f.shut)
        drawBrow(&ctx, f, e, s, y: f.c.y - 9.5 - CGFloat(f.p.brow) * 1.2 - f.shut * 1.5, half: 5, width: 3.2,
                 tilt: tilt * 2.8, alpha: max(0.85, CGFloat(f.p.brow)))
    }
    let m = f.mouthCenter
    let gap = CGFloat(max(0, f.p.mouth)) * 6
    let grin = CGFloat(smooth(0.45, 0.8, f.p.smile))
    if gap > 0.8 || grin > 0.3 {
        let w: CGFloat = 6.5 + grin * 1.5
        let depth = 3 + gap * 1.4 + grin * 2.5
        var mouth = Path()
        mouth.move(to: CGPoint(x: m.x - w, y: m.y - 1))
        mouth.addLine(to: CGPoint(x: m.x + w, y: m.y - 1))
        mouth.addQuadCurve(to: CGPoint(x: m.x - w, y: m.y - 1), control: CGPoint(x: m.x, y: m.y - 1 + depth * 2))
        mouth.closeSubpath()
        var g = ctx
        g.fill(mouth, with: .color(faceInk))
        g.clip(to: mouth)
        g.fill(Path(CGRect(x: m.x - w, y: m.y - 1, width: w * 2, height: 2.4)), with: .color(.white))
        g.fill(Path(ellipseIn: CGRect(x: m.x - w * 0.5, y: m.y - 1 + depth * 0.9, width: w, height: depth)), with: .color(Color(red: 1, green: 0.4, blue: 0.45)))
    } else {
        let curve = CGFloat(f.p.smile) * 3.5
        var l = Path()
        l.move(to: CGPoint(x: m.x - 5.5, y: m.y))
        l.addQuadCurve(to: CGPoint(x: m.x + 5.5, y: m.y - 0.6), control: CGPoint(x: m.x + 1, y: m.y + curve))
        stroke(&ctx, l, 2.4)
    }
    let sweat = CGFloat(smooth(0.4, 0.7, f.p.tilt)) * CGFloat(smooth(0.4, 0.7, f.p.brow))
    if sweat > 0.02 {
        let slide = (f.time * 0.35).truncatingRemainder(dividingBy: 1) * 5
        let d = CGPoint(x: f.c.x + 21, y: f.c.y - 8 + slide)
        var drop = Path()
        drop.move(to: CGPoint(x: d.x, y: d.y - 4.5))
        drop.addQuadCurve(to: CGPoint(x: d.x, y: d.y + 3), control: CGPoint(x: d.x + 4.5, y: d.y + 2.5))
        drop.addQuadCurve(to: CGPoint(x: d.x, y: d.y - 4.5), control: CGPoint(x: d.x - 4.5, y: d.y + 2.5))
        var g = ctx
        g.opacity = Double(sweat)
        g.fill(drop, with: .color(Color(red: 0.6, green: 0.85, blue: 1)))
        g.stroke(drop, with: .color(.white.opacity(0.9)), lineWidth: 0.8)
    }
    let anger = CGFloat(smooth(-0.45, -0.75, f.p.smile)) * CGFloat(smooth(0.6, 0.9, f.p.tilt))
    if anger > 0.02 {
        let pulse = 1 + 0.12 * sin(f.time * 7)
        let a = CGPoint(x: f.c.x - 22, y: f.c.y - 9)
        for k in 0..<4 {
            let ang = CGFloat(k) * .pi / 2 + .pi / 4
            let dir = CGPoint(x: cos(ang), y: sin(ang))
            let base = CGPoint(x: a.x + dir.x * 1.6 * pulse, y: a.y + dir.y * 1.6 * pulse)
            let side = CGPoint(x: -dir.y * 2.2 * pulse, y: dir.x * 2.2 * pulse)
            stroke(&ctx, arc(CGPoint(x: base.x + side.x, y: base.y + side.y), CGPoint(x: base.x - side.x, y: base.y - side.y),
                             CGPoint(x: base.x + dir.x * 2.6 * pulse, y: base.y + dir.y * 2.6 * pulse)),
                   1.6, alpha: anger, color: Color(red: 1, green: 0.25, blue: 0.3))
        }
    }
}

private func drawCat(_ ctx: inout GraphicsContext, _ f: FaceFrame) {
    drawBlush(&ctx, f, dx: 15, w: 8, h: 4.5, alpha: 0.4)
    let squint = max(f.happy, CGFloat(smooth(0.9, 0.82, Float(f.open))) * (1 - f.shut))
    let sad = CGFloat(smooth(-0.2, -0.6, f.p.smile)) * (1 - f.happy)
    let slit = CGFloat(smooth(1.1, 1.28, Float(f.open)))
    for s: CGFloat in [-1, 1] {
        let e = f.eye(s, spread: 9)
        drawClosed(&ctx, f, e, w: 4, width: 2)
        let a = (1 - squint) * (1 - f.shut)
        if a > 0.02 {
            var g = ctx
            g.opacity = Double(a)
            let h = max(1, 9.5 * f.open)
            let w = 7.4 - 4.4 * slit
            g.fill(Path(ellipseIn: CGRect(x: e.x - w / 2, y: e.y - h / 2, width: w, height: h)), with: .color(faceInk))
            if h > 4 {
                g.fill(Path(ellipseIn: CGRect(x: e.x - 2.3 + slit * 1.2, y: e.y - h / 2 + 1.5, width: 2.3, height: 2.3)),
                       with: .color(.white.opacity(0.9)))
            }
        }
        if squint > 0.02 {
            stroke(&ctx, arc(CGPoint(x: e.x - 4.2, y: e.y + 1.4), CGPoint(x: e.x + 4.2, y: e.y + 1.4), CGPoint(x: e.x, y: e.y - 4.8)),
                   2, alpha: squint * (1 - sad))
            var v = Path()
            v.move(to: CGPoint(x: e.x + s * 3.6, y: e.y - 3))
            v.addLine(to: CGPoint(x: e.x - s * 3, y: e.y))
            v.addLine(to: CGPoint(x: e.x + s * 3.6, y: e.y + 3))
            stroke(&ctx, v, 2, alpha: squint * sad)
        }
        drawBrow(&ctx, f, e, s, y: f.c.y - 9 - CGFloat(f.p.brow) * 1.4, half: 3, width: 1.4,
                 tilt: CGFloat(f.p.tilt) * 2, alpha: CGFloat(f.p.brow) * 0.7)
        for k in 0..<3 {
            let sway = sin(f.time * 1.8 + s * 0.9 + CGFloat(k)) * 0.6
            var l = Path()
            l.move(to: CGPoint(x: f.c.x + s * 14, y: f.c.y + 6 + CGFloat(k) * 2.4))
            l.addLine(to: CGPoint(x: f.c.x + s * 24, y: f.c.y + 3.5 + CGFloat(k) * 4.2 + sway))
            stroke(&ctx, l, 0.9, alpha: 0.55)
        }
    }
    let n = CGPoint(x: f.c.x + f.look.x * 0.6, y: f.c.y + 5.5 + f.look.y * 0.4)
    var nose = Path()
    nose.move(to: CGPoint(x: n.x - 1.8, y: n.y - 1))
    nose.addLine(to: CGPoint(x: n.x + 1.8, y: n.y - 1))
    nose.addLine(to: CGPoint(x: n.x, y: n.y + 1))
    nose.closeSubpath()
    ctx.fill(nose, with: .color(Color(red: 1, green: 0.5, blue: 0.6)))
    let m = CGPoint(x: n.x, y: n.y + 1.4)
    let gap = CGFloat(max(0, f.p.mouth)) * 5.5
    if gap > 0.8 {
        var o = Path()
        o.move(to: CGPoint(x: m.x - 2.6, y: m.y + 1.2))
        o.addLine(to: CGPoint(x: m.x + 2.6, y: m.y + 1.2))
        o.addQuadCurve(to: CGPoint(x: m.x - 2.6, y: m.y + 1.2), control: CGPoint(x: m.x, y: m.y + 1.2 + gap * 1.6))
        ctx.fill(o, with: .color(faceInk))
    }
    let k = CGFloat(clampf(f.p.smile * 2 + 0.6, -1, 1))
    stroke(&ctx, arc(CGPoint(x: m.x - 5, y: m.y + 0.6), CGPoint(x: m.x, y: m.y), CGPoint(x: m.x - 2.5, y: m.y + 0.3 + 3.4 * k)), 1.7)
    stroke(&ctx, arc(CGPoint(x: m.x, y: m.y), CGPoint(x: m.x + 5, y: m.y + 0.6), CGPoint(x: m.x + 2.5, y: m.y + 0.3 + 3.4 * k)), 1.7)
}

private func drawDot(_ ctx: inout GraphicsContext, _ f: FaceFrame) {
    drawBlush(&ctx, f, dx: 12, w: 6, h: 3.5, alpha: 0.35)
    for s: CGFloat in [-1, 1] {
        let e = CGPoint(x: f.c.x + s * 8 + f.look.x * 0.6, y: f.c.y + 1 + f.look.y * 0.6)
        drawClosed(&ctx, f, e, w: 2.4, width: 1.6)
        let a = (1 - f.happy) * (1 - f.shut)
        if a > 0.02 {
            var g = ctx
            g.opacity = Double(a)
            let h = max(0.9, 4.4 * f.open)
            g.fill(Path(ellipseIn: CGRect(x: e.x - 2.2, y: e.y - h / 2, width: 4.4, height: h)), with: .color(faceInk))
        }
        drawHappy(&ctx, f, e, w: 2.6, width: 1.6)
        drawBrow(&ctx, f, e, s, y: f.c.y - 5 - CGFloat(f.p.brow), half: 2, width: 1.2,
                 tilt: CGFloat(f.p.tilt) * 1.3, alpha: CGFloat(f.p.brow) * 0.5)
    }
    let m = CGPoint(x: f.c.x + f.look.x * 0.4, y: f.c.y + 7 + f.look.y * 0.3)
    let gap = CGFloat(max(0, f.p.mouth)) * 4
    if gap > 0.9 {
        ctx.fill(Path(ellipseIn: CGRect(x: m.x - 1.8, y: m.y - gap * 0.4, width: 3.6, height: gap)), with: .color(faceInk))
    } else {
        stroke(&ctx, arc(CGPoint(x: m.x - 2.8, y: m.y), CGPoint(x: m.x + 2.8, y: m.y), CGPoint(x: m.x, y: m.y + CGFloat(f.p.smile) * 2.4)), 1.4)
    }
}

struct FaceGallery: View {
    private static let samples: [(String, (SoftBody) -> Void)] = [
        ("起動前", { _ in }),
        ("作業中", { $0.sessionState = .busy }),
        ("入力待ち", { $0.sessionState = .waiting }),
        ("完了", { $0.badge = Badge(kind: .done, time: 0, summary: "") }),
        ("判断", { $0.badge = Badge(kind: .needDecision, time: 0, summary: "") }),
        ("進めない", { $0.badge = Badge(kind: .blocked, time: 0, summary: "") }),
        ("エラー", { $0.badge = Badge(kind: .error, time: 0, summary: "") }),
        ("つかむ", { $0.grabbed = true }),
    ]

    var body: some View {
        let colors: [Color] = [.green, .purple, .orange, .pink, .blue]
        Grid(horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("")
                ForEach(Self.samples.indices, id: \.self) { i in
                    Text(Self.samples[i].0).font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                }
            }
            ForEach(Array(FaceStyle.allCases.enumerated()), id: \.offset) { row, style in
                GridRow {
                    Text(style.label).font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                    ForEach(Self.samples.indices, id: \.self) { i in
                        let b = SoftBody(id: 0, template: Template(id: "x", name: "x", symbol: "star", color: V3(0.5, 0.5, 0.5)),
                                         name: "x", center: V2(0, 0), radius: 54)
                        let _ = Self.samples[i].1(b)
                        var f = FaceState()
                        let _ = { f.pose = FaceState.target(b) }()
                        Circle()
                            .fill(colors[row].gradient)
                            .frame(width: 96, height: 96)
                            .overlay(FaceView(face: f, style: style, tint: colors[row], time: 1.3).scaleEffect(1.4))
                    }
                }
            }
        }
    }
}
