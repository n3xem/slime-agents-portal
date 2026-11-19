import SwiftUI

enum Costume: String, Codable, CaseIterable {
    case witch, scientist, warrior, priest, jester, dracula

    var label: String {
        switch self {
        case .witch: return "魔女"
        case .scientist: return "科学者"
        case .warrior: return "戦士"
        case .priest: return "僧侶"
        case .jester: return "遊び人"
        case .dracula: return "ドラキュラ"
        }
    }
}

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

private func fract(_ x: CGFloat) -> CGFloat { x - x.rounded(.down) }

private struct Brush {
    let ctx: GraphicsContext
    let r: CGFloat
    let c: CGPoint
    let t: CGFloat
    var k: CGFloat = 0
    var u: CGFloat = 0

    var ease: CGFloat { u * u * (3 - 2 * u) }

    func faded(_ alpha: CGFloat) -> Brush {
        var g = ctx
        g.opacity = Double(alpha)
        return Brush(ctx: g, r: r, c: c, t: t, k: k, u: u)
    }

    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * r, y: c.y + y * r) }

    func moved(_ x: CGFloat, _ y: CGFloat, _ angle: CGFloat) -> Brush {
        var g = ctx
        let o = p(x, y)
        g.translateBy(x: o.x, y: o.y)
        g.rotate(by: .radians(Double(angle)))
        return Brush(ctx: g, r: r, c: .zero, t: t, k: k, u: u)
    }

    func fill(_ path: Path, _ colors: [Color], _ a: CGPoint, _ b: CGPoint) {
        ctx.fill(path, with: .linearGradient(Gradient(colors: colors), startPoint: a, endPoint: b))
    }

    func fill(_ path: Path, _ color: Color) { ctx.fill(path, with: .color(color)) }

    func line(_ path: Path, _ color: Color, _ w: CGFloat) {
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(0.6, w * r), lineCap: .round, lineJoin: .round))
    }

    func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        let o = p(x, y)
        return Path(ellipseIn: CGRect(x: o.x - rx * r, y: o.y - ry * r, width: rx * 2 * r, height: ry * 2 * r))
    }

    func arc(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ from: CGFloat, _ to: CGFloat) -> Path {
        var path = Path()
        let n = 24
        for i in 0...n {
            let a = (from + (to - from) * CGFloat(i) / CGFloat(n)) * .pi / 180
            let q = p(x + cos(a) * rx, y + sin(a) * ry)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        return path
    }

    func curve(_ a: (CGFloat, CGFloat), _ ctrl: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> Path {
        var path = Path()
        path.move(to: p(a.0, a.1))
        path.addQuadCurve(to: p(b.0, b.1), control: p(ctrl.0, ctrl.1))
        return path
    }

    func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ corner: CGFloat) -> Path {
        let a = p(x0, y0), b = p(x1, y1)
        return Path(roundedRect: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y), cornerRadius: corner * r)
    }

    func ball(_ x: CGFloat, _ y: CGFloat, _ rad: CGFloat, _ light: Color, _ dark: Color) {
        let o = p(x, y)
        let rr = rad * r
        let path = oval(x, y, rad, rad)
        ctx.fill(path, with: .radialGradient(Gradient(colors: [light, dark]),
                                             center: CGPoint(x: o.x - rr * 0.35, y: o.y - rr * 0.4), startRadius: 0, endRadius: rr * 1.45))
        ctx.fill(oval(x - rad * 0.32, y - rad * 0.38, rad * 0.26, rad * 0.18), with: .color(.white.opacity(0.7)))
    }

    func soft(_ path: Path, _ color: Color, _ blur: CGFloat) {
        var g = ctx
        g.addFilter(.blur(radius: blur * r))
        g.fill(path, with: .color(color))
    }

    func glow(_ path: Path, _ color: Color, _ radius: CGFloat) {
        var g = ctx
        g.addFilter(.shadow(color: color, radius: radius * r))
        g.fill(path, with: .color(color))
    }

    func star4(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat) -> Path {
        let q = p(x, y)
        let s = size * r
        var path = Path()
        path.move(to: CGPoint(x: q.x, y: q.y - s))
        path.addQuadCurve(to: CGPoint(x: q.x + s, y: q.y), control: q)
        path.addQuadCurve(to: CGPoint(x: q.x, y: q.y + s), control: q)
        path.addQuadCurve(to: CGPoint(x: q.x - s, y: q.y), control: q)
        path.addQuadCurve(to: CGPoint(x: q.x, y: q.y - s), control: q)
        return path
    }

    func star5(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ spin: CGFloat = 0) -> Path {
        let q = p(x, y)
        var path = Path()
        for i in 0..<10 {
            let a = CGFloat(i) * .pi / 5 - .pi / 2 + spin
            let rr = (i % 2 == 0 ? size : size * 0.46) * r
            let v = CGPoint(x: q.x + cos(a) * rr, y: q.y + sin(a) * rr)
            if i == 0 { path.move(to: v) } else { path.addLine(to: v) }
        }
        path.closeSubpath()
        return path
    }

    func twinkle(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ phase: CGFloat, _ color: Color = .white) {
        let k = pow(max(0, sin(t * 2.6 + phase)), 3)
        if k > 0.02 { glow(star4(x, y, size * k), color, 0.08) }
    }
}

private let gold: [Color] = [rgb(1, 0.95, 0.62), rgb(1, 0.78, 0.28), rgb(0.72, 0.46, 0.1)]
private let goldEdge = rgb(0.45, 0.27, 0.04)
private let steel: [Color] = [rgb(0.97, 0.98, 1), rgb(0.68, 0.72, 0.8), rgb(0.36, 0.4, 0.5)]

struct CostumeView: View {
    static let span: CGFloat = 5.2
    let costume: Costume
    let time: Float
    var pose: CGFloat = 0

    var body: some View {
        Canvas { ctx, size in
            let r = size.width / CostumeView.span
            let b = Brush(ctx: ctx, r: r, c: CGPoint(x: size.width / 2, y: size.height / 2), t: CGFloat(time),
                          k: sin(pose * .pi), u: pose)
            switch costume {
            case .witch: witch(b)
            case .scientist: scientist(b)
            case .warrior: warrior(b)
            case .priest: priest(b)
            case .jester: jester(b)
            case .dracula: dracula(b)
            }
        }
        .allowsHitTesting(false)
    }

    private func witch(_ b: Brush) {
        b.soft(b.oval(0, -0.64, 0.98, 0.15), .black.opacity(0.32), 0.07)
        let brim = b.oval(0, -0.84, 1.16, 0.26)
        b.fill(brim, [rgb(0.5, 0.32, 0.8), rgb(0.27, 0.13, 0.48), rgb(0.14, 0.06, 0.28)], b.p(-0.7, -1.1), b.p(0.6, -0.58))
        b.line(brim, rgb(0.09, 0.03, 0.2), 0.03)
        b.line(b.arc(0, -0.84, 1.1, 0.215, 190, 262), rgb(0.78, 0.62, 1).opacity(0.7), 0.035)
        b.soft(b.oval(0.05, -0.8, 0.7, 0.1), .black.opacity(0.35), 0.05)

        var cone = Path()
        cone.move(to: b.p(-0.62, -0.9))
        cone.addCurve(to: b.p(0.16, -1.8), control1: b.p(-0.52, -1.36), control2: b.p(-0.2, -1.64))
        cone.addCurve(to: b.p(0.88, -2.02), control1: b.p(0.4, -1.92), control2: b.p(0.68, -2.08))
        cone.addCurve(to: b.p(0.42, -1.52), control1: b.p(0.72, -1.8), control2: b.p(0.52, -1.72))
        cone.addCurve(to: b.p(0.62, -0.9), control1: b.p(0.5, -1.3), control2: b.p(0.6, -1.08))
        cone.addQuadCurve(to: b.p(-0.62, -0.9), control: b.p(0, -0.74))
        cone.closeSubpath()
        b.fill(cone, [rgb(0.56, 0.36, 0.86), rgb(0.33, 0.17, 0.58), rgb(0.15, 0.06, 0.3)], b.p(-0.5, -1.5), b.p(0.6, -1.0))
        b.line(b.curve((0.1, -1.7), (0.34, -1.66), (0.45, -1.48)), rgb(0.08, 0.02, 0.18).opacity(0.55), 0.06)
        b.line(b.curve((-0.1, -1.38), (0.2, -1.3), (0.44, -1.36)), rgb(0.08, 0.02, 0.18).opacity(0.3), 0.045)
        b.line(b.curve((-0.47, -1.06), (-0.36, -1.42), (-0.1, -1.62)), .white.opacity(0.28), 0.07)
        b.line(cone, rgb(0.09, 0.03, 0.2), 0.03)

        var band = Path()
        band.move(to: b.p(-0.585, -1.1))
        band.addQuadCurve(to: b.p(0.585, -1.1), control: b.p(0, -0.95))
        band.addLine(to: b.p(0.62, -0.9))
        band.addQuadCurve(to: b.p(-0.62, -0.9), control: b.p(0, -0.74))
        band.closeSubpath()
        b.fill(band, [rgb(1, 0.72, 0.3), rgb(0.93, 0.42, 0.12)], b.p(0, -1.1), b.p(0, -0.8))
        b.line(band, rgb(0.45, 0.16, 0.02), 0.022)
        b.fill(b.box(-0.14, -1.04, 0.14, -0.8, 0.04), rgb(0.5, 0.2, 0.04))
        b.line(b.box(-0.14, -1.04, 0.14, -0.8, 0.04), rgb(1, 0.9, 0.45), 0.05)
        b.line(b.curve((-0.1, -1.02), (0, -1.03), (0.08, -1.02)), .white.opacity(0.8), 0.018)

        b.fill(b.star5(-0.14, -1.36, 0.11, 0.2), rgb(1, 0.9, 0.42))
        b.fill(b.oval(0.2, -1.24, 0.09, 0.09), rgb(1, 0.9, 0.42))
        b.fill(b.oval(0.24, -1.27, 0.075, 0.075), rgb(0.3, 0.15, 0.54))
        b.fill(b.oval(0.02, -1.62, 0.022, 0.022), rgb(1, 0.92, 0.6))
        b.fill(b.oval(-0.32, -1.2, 0.02, 0.02), rgb(1, 0.92, 0.6))
        b.twinkle(0.88, -2.02, 0.16, 0, rgb(1, 0.95, 0.7))

        let wx = 1.46 - 0.1 * b.k, wy = 0.3 + 0.04 * sin(b.t * 2.2) - 0.55 * b.k
        let spin = 0.3 + 4 * .pi * b.ease
        if b.k > 0.01 {
            for i in 0..<9 {
                let a = spin - CGFloat(i) * 0.38
                let fade = 1 - CGFloat(i) / 9
                b.glow(b.star4(wx + sin(a) * 0.62, wy - cos(a) * 0.62, 0.16 * b.k * fade),
                       i % 2 == 0 ? rgb(1, 0.92, 0.5) : rgb(0.85, 0.7, 1), 0.08)
            }
            b.line(b.oval(wx, wy, 0.62, 0.62), rgb(1, 0.92, 0.6).opacity(Double(b.k) * 0.35), 0.03)
        }
        let w = b.moved(wx, wy, spin)
        w.fill(w.box(-0.04, -0.4, 0.04, 0.5, 0.04), [rgb(0.62, 0.4, 0.22), rgb(0.3, 0.16, 0.07)], w.p(-0.04, 0), w.p(0.04, 0))
        w.fill(w.box(-0.055, 0.38, 0.055, 0.52, 0.03), gold, w.p(-0.05, 0), w.p(0.05, 0))
        w.fill(w.box(-0.055, -0.44, 0.055, -0.36, 0.03), gold, w.p(-0.05, 0), w.p(0.05, 0))
        w.glow(w.star5(0, -0.6, 0.23, sin(b.t * 1.5) * 0.25), rgb(1, 0.88, 0.35), 0.16)
        w.fill(w.star5(0, -0.6, 0.12, sin(b.t * 1.5) * 0.25), rgb(1, 0.98, 0.8))
        w.twinkle(-0.3, -0.8, 0.12, 1.2)
        w.twinkle(0.3, -0.42, 0.1, 3.1, rgb(0.85, 0.7, 1))
        w.twinkle(0.18, -0.98, 0.09, 4.6, rgb(1, 0.95, 0.6))
    }

    private func scientist(_ b: Brush) {
        let shade = rgb(0.66, 0.72, 0.86)
        let outer: [(CGFloat, CGFloat)] = [(196, 0.24), (344, 0.24), (212, 0.28), (328, 0.28), (230, 0.27), (310, 0.27),
                                           (248, 0.24), (292, 0.24), (270, 0.22)]
        for (deg, size) in outer {
            let a = deg * .pi / 180
            b.ball(cos(a) * 1.1, sin(a) * 1.1 + 0.05, size, .white, shade)
        }
        let inner: [(CGFloat, CGFloat)] = [(204, 0.2), (336, 0.2), (224, 0.22), (316, 0.22), (258, 0.2), (282, 0.2)]
        for (deg, size) in inner {
            let a = deg * .pi / 180
            b.ball(cos(a) * 0.92, sin(a) * 0.92 + 0.05, size, .white, rgb(0.78, 0.82, 0.92))
        }
        b.line(b.curve((-1.2, -0.62), (-1.42, -0.86), (-1.36, -1.02)), .white, 0.07)
        b.line(b.curve((1.2, -0.62), (1.42, -0.86), (1.36, -1.02)), .white, 0.07)
        b.line(b.curve((0.1, -1.3), (0.2, -1.52), (0.38, -1.5)), .white, 0.07)

        b.line(b.arc(0, -0.5, 1.0, 0.44, 203, 337), rgb(0.2, 0.13, 0.1), 0.15)
        b.line(b.arc(0, -0.5, 1.0, 0.44, 203, 337), rgb(0.5, 0.33, 0.2), 0.09)
        b.fill(b.box(-0.12, -0.96, 0.12, -0.84, 0.04), rgb(0.3, 0.2, 0.14))
        for s: CGFloat in [-1, 1] {
            let x = 0.33 * s
            b.soft(b.oval(x, -0.84, 0.27, 0.27), .black.opacity(0.3), 0.04)
            b.ball(x, -0.9, 0.28, rgb(1, 0.9, 0.6), rgb(0.5, 0.32, 0.1))
            b.fill(b.oval(x, -0.9, 0.215, 0.215), rgb(0.16, 0.12, 0.1))
            let o = b.p(x, -0.9)
            b.ctx.fill(b.oval(x, -0.9, 0.19, 0.19),
                       with: .radialGradient(Gradient(colors: [rgb(0.85, 1, 1), rgb(0.3, 0.75, 0.95), rgb(0.1, 0.35, 0.7)]),
                                             center: CGPoint(x: o.x - 0.07 * b.r, y: o.y - 0.08 * b.r), startRadius: 0, endRadius: 0.3 * b.r))
            b.fill(b.oval(x - 0.07, -0.97, 0.07, 0.045), .white.opacity(0.9))
            b.fill(b.oval(x + 0.07, -0.83, 0.03, 0.02), .white.opacity(0.6))
        }
        let glint = pow(max(0, sin(b.t * 1.4)), 10)
        if glint > 0.02 { b.glow(b.star4(0.42, -1.0, 0.2 * glint), .white, 0.08) }
        if b.k > 0.02 {
            b.glow(b.star4(0.42, -1.0, 0.3 * b.k), .white, 0.1)
            b.glow(b.star4(-0.24, -1.0, 0.22 * b.k), .white, 0.1)
        }

        let f = b.moved(1.5 + 0.05 * b.k, 0.38 + 0.03 * sin(b.t * 1.8) - 0.6 * b.k, -0.14 - 0.4 * b.k)
        let reacted = b.u > 0.3
        if b.k > 0.02 {
            let puffs: [Color] = [rgb(1, 0.75, 0.9), rgb(0.8, 0.9, 1), rgb(1, 0.95, 0.7), rgb(0.85, 1, 0.85), .white]
            for i in 0..<7 {
                let ci = CGFloat(i)
                let rise = b.u * (0.5 + 0.16 * ci)
                f.faded(b.k * 0.85).ball(sin(ci * 1.7) * 0.32 * b.u, -0.5 - rise, (0.07 + 0.025 * ci) * (0.5 + b.u),
                                         .white, puffs[i % 5])
            }
            f.glow(f.star4(0, -0.6 - b.u * 0.5, 0.2 * b.k), rgb(1, 0.95, 0.7), 0.1)
        }
        f.soft(f.oval(0, 0.16, 0.3, 0.22), (reacted ? rgb(1, 0.4, 0.8) : rgb(0.4, 1, 0.5)).opacity(0.35 + 0.3 * Double(b.k)), 0.1)
        var glass = Path()
        glass.move(to: f.p(-0.075, -0.46))
        glass.addLine(to: f.p(-0.075, -0.2))
        glass.addLine(to: f.p(-0.31, 0.24))
        glass.addQuadCurve(to: f.p(-0.24, 0.34), control: f.p(-0.34, 0.33))
        glass.addLine(to: f.p(0.24, 0.34))
        glass.addQuadCurve(to: f.p(0.31, 0.24), control: f.p(0.34, 0.33))
        glass.addLine(to: f.p(0.075, -0.2))
        glass.addLine(to: f.p(0.075, -0.46))
        glass.closeSubpath()
        f.fill(glass, .white.opacity(0.16))
        let wave = 0.012 * sin(b.t * 3)
        var liquid = Path()
        liquid.move(to: f.p(-0.2, 0.03 + wave))
        liquid.addQuadCurve(to: f.p(0.2, 0.03 - wave), control: f.p(0, 0.06))
        liquid.addLine(to: f.p(0.29, 0.23))
        liquid.addQuadCurve(to: f.p(0.23, 0.315), control: f.p(0.31, 0.31))
        liquid.addLine(to: f.p(-0.23, 0.315))
        liquid.addQuadCurve(to: f.p(-0.29, 0.23), control: f.p(-0.31, 0.31))
        liquid.closeSubpath()
        f.fill(liquid, reacted ? [rgb(1, 0.7, 0.95), rgb(0.9, 0.2, 0.7)] : [rgb(0.7, 1, 0.45), rgb(0.15, 0.8, 0.4)], f.p(0, 0), f.p(0, 0.32))
        for i in 0..<4 {
            let u = fract(b.t * 0.5 + CGFloat(i) * 0.27)
            let x = sin(CGFloat(i) * 2.1) * 0.1 * (1 - u * 0.6)
            let rad = (0.03 + 0.015 * CGFloat(i % 2)) * (0.6 + u * 0.6)
            let y = 0.22 - u * 0.78
            f.fill(f.oval(x, y, rad, rad), rgb(0.8, 1, 0.75).opacity(Double(1 - u) * 0.9))
            f.line(f.oval(x, y, rad, rad), .white.opacity(Double(1 - u) * 0.8), 0.012)
        }
        f.line(glass, .white.opacity(0.85), 0.03)
        f.line(f.oval(0, -0.46, 0.1, 0.03), .white.opacity(0.9), 0.03)
        f.line(f.curve((-0.21, 0.2), (-0.17, 0.08), (-0.11, -0.04)), .white.opacity(0.75), 0.03)
    }

    private func warrior(_ b: Brush) {
        b.soft(b.oval(0, -0.44, 0.95, 0.14), .black.opacity(0.35), 0.07)
        for s: CGFloat in [-1, 1] {
            var horn = Path()
            horn.move(to: b.p(0.62 * s, -0.84))
            horn.addCurve(to: b.p(1.34 * s, -1.84), control1: b.p(1.16 * s, -0.84), control2: b.p(1.5 * s, -1.3))
            horn.addCurve(to: b.p(0.8 * s, -1.2), control1: b.p(1.24 * s, -1.42), control2: b.p(1.06 * s, -1.2))
            horn.closeSubpath()
            b.fill(horn, [rgb(1, 0.98, 0.9), rgb(0.93, 0.85, 0.68), rgb(0.66, 0.54, 0.38)], b.p(0.8 * s, -1.7), b.p(1.1 * s, -0.85))
            b.line(b.curve((0.86 * s, -1.2), (0.98 * s, -1.06), (1.02 * s, -0.86)), rgb(0.5, 0.36, 0.2).opacity(0.5), 0.03)
            b.line(b.curve((1.02 * s, -1.26), (1.16 * s, -1.16), (1.24 * s, -0.98)), rgb(0.5, 0.36, 0.2).opacity(0.4), 0.03)
            b.line(b.curve((0.84 * s, -1.08), (1.2 * s, -1.2), (1.3 * s, -1.7)), .white.opacity(0.55), 0.035)
            b.line(horn, rgb(0.35, 0.24, 0.1), 0.028)
            b.ball(0.74 * s, -0.98, 0.17, gold[0], gold[2])
            b.line(b.oval(0.74 * s, -0.98, 0.17, 0.17), goldEdge, 0.025)

            var cheek = Path()
            cheek.move(to: b.p(0.7 * s, -0.52))
            cheek.addLine(to: b.p(1.03 * s, -0.52))
            cheek.addQuadCurve(to: b.p(0.9 * s, 0.02), control: b.p(1.12 * s, -0.2))
            cheek.addQuadCurve(to: b.p(0.7 * s, -0.52), control: b.p(0.72 * s, -0.16))
            cheek.closeSubpath()
            b.fill(cheek, steel, b.p(0.7 * s, -0.5), b.p(1.0 * s, 0))
            b.line(cheek, rgb(0.16, 0.18, 0.25), 0.028)
            b.ball(0.9 * s, -0.36, 0.045, gold[0], gold[2])
        }
        var dome = Path()
        dome.addArc(center: b.p(0, -0.5), radius: 0.96 * b.r, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        dome.closeSubpath()
        b.fill(dome, steel, b.p(-0.45, -1.45), b.p(0.5, -0.5))
        b.soft(b.oval(-0.42, -1.12, 0.2, 0.12), .white.opacity(0.75), 0.05)
        b.line(b.curve((-0.5, -0.56), (-0.52, -1.1), (-0.14, -1.42)), rgb(0.16, 0.18, 0.25).opacity(0.5), 0.022)
        b.line(b.curve((0.5, -0.56), (0.52, -1.1), (0.14, -1.42)), rgb(0.16, 0.18, 0.25).opacity(0.5), 0.022)
        b.line(dome, rgb(0.16, 0.18, 0.25), 0.03)
        let ridge = b.box(-0.075, -1.5, 0.075, -0.6, 0.06)
        b.fill(ridge, gold, b.p(-0.08, 0), b.p(0.08, 0))
        b.line(ridge, goldEdge, 0.022)
        b.ball(0, -1.5, 0.11, gold[0], gold[2])
        b.line(b.oval(0, -1.5, 0.11, 0.11), goldEdge, 0.022)
        let rim = b.box(-1.03, -0.68, 1.03, -0.44, 0.1)
        b.fill(rim, gold, b.p(0, -0.7), b.p(0, -0.42))
        b.line(rim, goldEdge, 0.028)
        b.line(b.curve((-0.94, -0.63), (0, -0.64), (0.94, -0.63)), .white.opacity(0.7), 0.02)
        for i in 0..<7 {
            b.ball(-0.84 + CGFloat(i) * 0.28, -0.555, 0.05, rgb(0.9, 0.6, 0.2), rgb(0.4, 0.22, 0.04))
        }

        let s = b.moved(1.56 - 0.06 * b.k, 0.42 + 0.03 * sin(b.t * 1.7) - 0.85 * b.k, 0.14 - 0.14 * b.k)
        if b.k > 0.02 {
            s.soft(s.oval(0, -1.26, 0.5 * b.k, 0.5 * b.k), .white.opacity(0.5 * Double(b.k)), 0.12)
            for i in 0..<8 {
                let a = CGFloat(i) / 8 * 2 * .pi + b.u
                let d0 = 0.2 + 0.25 * b.u, d1 = d0 + 0.3 * b.k
                var ray = Path()
                ray.move(to: s.p(cos(a) * d0, -1.26 + sin(a) * d0))
                ray.addLine(to: s.p(cos(a) * d1, -1.26 + sin(a) * d1))
                s.line(ray, rgb(1, 0.97, 0.75).opacity(Double(b.k)), 0.035)
            }
        }
        var blade = Path()
        blade.move(to: s.p(-0.1, -0.1))
        blade.addLine(to: s.p(-0.1, -1.02))
        blade.addLine(to: s.p(0, -1.26))
        blade.addLine(to: s.p(0.1, -1.02))
        blade.addLine(to: s.p(0.1, -0.1))
        blade.closeSubpath()
        s.fill(blade, [rgb(1, 1, 1), rgb(0.8, 0.84, 0.92), rgb(0.5, 0.55, 0.66)], s.p(-0.1, 0), s.p(0.1, 0))
        s.line(s.curve((0, -0.16), (0, -0.6), (0, -1.0)), rgb(0.3, 0.34, 0.45).opacity(0.5), 0.035)
        s.line(blade, rgb(0.16, 0.18, 0.25), 0.025)
        let u = fract(b.t * 0.4)
        if u < 0.35 {
            let k = u / 0.35
            s.glow(s.star4(-0.03, -0.15 - k * 1.0, 0.2 * sin(k * .pi)), .white, 0.1)
        }
        if b.k > 0.02 { s.glow(s.star4(0, -1.26, 0.42 * b.k), .white, 0.14) }
        let guardBar = s.box(-0.34, -0.16, 0.34, -0.03, 0.06)
        s.fill(guardBar, gold, s.p(0, -0.17), s.p(0, -0.02))
        s.line(guardBar, goldEdge, 0.022)
        s.ball(0, -0.095, 0.06, rgb(1, 0.5, 0.55), rgb(0.7, 0.04, 0.12))
        let grip = s.box(-0.065, -0.03, 0.065, 0.3, 0.03)
        s.fill(grip, [rgb(0.55, 0.3, 0.16), rgb(0.26, 0.12, 0.05)], s.p(-0.07, 0), s.p(0.07, 0))
        for i in 0..<4 {
            let y = 0.03 + CGFloat(i) * 0.07
            s.line(s.curve((-0.06, y), (0, y + 0.03), (0.06, y)), rgb(0.15, 0.06, 0.02).opacity(0.7), 0.018)
        }
        s.ball(0, 0.36, 0.1, gold[0], gold[2])
        s.line(s.oval(0, 0.36, 0.1, 0.1), goldEdge, 0.02)
    }

    private func priest(_ b: Brush) {
        let pulse = min(1.4, 0.75 + 0.25 * sin(b.t * 2) + 0.6 * b.k)
        let haloColor = rgb(1, 0.9, 0.5).opacity(Double(min(1, pulse)))
        let hs = 1 + 0.3 * b.k, hy = -1.86 - 0.14 * b.k
        if b.k > 0.02 {
            for i in 0..<5 {
                let x = (CGFloat(i) - 2) * 0.42
                var beam = Path()
                beam.move(to: b.p(x * 0.5 - 0.07, -2.6))
                beam.addLine(to: b.p(x * 0.5 + 0.07, -2.6))
                beam.addLine(to: b.p(x * 1.5 + 0.24, -0.7 - 1.2 * (1 - b.ease)))
                beam.addLine(to: b.p(x * 1.5 - 0.24, -0.7 - 1.2 * (1 - b.ease)))
                beam.closeSubpath()
                b.fill(beam, [rgb(1, 0.97, 0.75).opacity(0), rgb(1, 0.97, 0.75).opacity(0.5 * Double(b.k)), rgb(1, 0.9, 0.5).opacity(0)], b.p(0, -2.6), b.p(0, -0.7))
            }
        }
        var back = b.ctx
        back.addFilter(.shadow(color: rgb(1, 0.85, 0.4).opacity(0.9), radius: (0.12 + 0.2 * b.k) * b.r))
        back.stroke(b.arc(0, hy, 0.84 * hs, 0.17 * hs, 180, 360), with: .color(haloColor), style: StrokeStyle(lineWidth: 0.075 * b.r, lineCap: .round))

        b.soft(b.oval(0, -0.62, 0.72, 0.13), .black.opacity(0.3), 0.06)
        for s: CGFloat in [-1, 1] {
            var lap = Path()
            lap.move(to: b.p(0.4 * s, -0.88))
            lap.addQuadCurve(to: b.p(1.08 * s, -0.5), control: b.p(0.9 * s, -0.9))
            lap.addLine(to: b.p(0.94 * s, -0.32))
            lap.addQuadCurve(to: b.p(0.44 * s, -0.72), control: b.p(0.84 * s, -0.72))
            lap.closeSubpath()
            b.fill(lap, [.white, rgb(0.8, 0.85, 0.97)], b.p(0.5 * s, -0.9), b.p(1.0 * s, -0.4))
            b.line(lap, rgb(0.5, 0.56, 0.75), 0.022)
            b.line(b.curve((1.08 * s, -0.5), (1.02 * s, -0.4), (0.94 * s, -0.32)), gold[1], 0.07)
            b.line(b.curve((0.98 * s, -0.6), (0.92 * s, -0.5), (0.85 * s, -0.42)), gold[1], 0.03)
        }

        var hat = Path()
        hat.move(to: b.p(-0.64, -0.78))
        hat.addCurve(to: b.p(0, -2.08), control1: b.p(-0.78, -1.42), control2: b.p(-0.32, -1.82))
        hat.addCurve(to: b.p(0.64, -0.78), control1: b.p(0.32, -1.82), control2: b.p(0.78, -1.42))
        hat.addQuadCurve(to: b.p(-0.64, -0.78), control: b.p(0, -0.62))
        hat.closeSubpath()
        b.fill(hat, [.white, rgb(0.95, 0.96, 1), rgb(0.74, 0.8, 0.95)], b.p(-0.5, -1.6), b.p(0.6, -0.9))
        b.line(b.curve((-0.5, -1.0), (-0.52, -1.45), (-0.2, -1.8)), .white, 0.07)
        b.line(hat, gold[1], 0.075)
        b.line(hat, goldEdge.opacity(0.55), 0.018)

        var orphrey = Path()
        orphrey.move(to: b.p(-0.12, -0.72))
        orphrey.addLine(to: b.p(-0.08, -1.72))
        orphrey.addLine(to: b.p(0, -2.02))
        orphrey.addLine(to: b.p(0.08, -1.72))
        orphrey.addLine(to: b.p(0.12, -0.72))
        orphrey.closeSubpath()
        b.fill(orphrey, gold, b.p(-0.12, 0), b.p(0.12, 0))

        var band = Path()
        band.move(to: b.p(-0.66, -1.02))
        band.addQuadCurve(to: b.p(0.66, -1.02), control: b.p(0, -0.88))
        band.addLine(to: b.p(0.64, -0.78))
        band.addQuadCurve(to: b.p(-0.64, -0.78), control: b.p(0, -0.62))
        band.closeSubpath()
        b.fill(band, gold, b.p(0, -1.02), b.p(0, -0.68))
        b.line(band, goldEdge, 0.022)
        let gems: [(Color, Color)] = [(rgb(0.6, 0.8, 1), rgb(0.1, 0.3, 0.85)), (rgb(1, 0.6, 0.65), rgb(0.75, 0.05, 0.15)),
                                      (rgb(0.6, 1, 0.75), rgb(0.05, 0.6, 0.3))]
        for i in 0..<5 {
            let x = -0.44 + CGFloat(i) * 0.22
            let y = -0.83 - 0.07 * (1 - (x / 0.5) * (x / 0.5))
            let g = gems[i % 3]
            b.ball(x, y + 0.03, 0.06, g.0, g.1)
        }
        b.line(b.curve((0, -1.62), (0, -1.4), (0, -1.14)), rgb(0.5, 0.02, 0.1), 0.15)
        b.line(b.curve((-0.18, -1.44), (0, -1.44), (0.18, -1.44)), rgb(0.5, 0.02, 0.1), 0.15)
        b.line(b.curve((0, -1.62), (0, -1.4), (0, -1.14)), rgb(0.93, 0.18, 0.28), 0.1)
        b.line(b.curve((-0.18, -1.44), (0, -1.44), (0.18, -1.44)), rgb(0.93, 0.18, 0.28), 0.1)
        b.fill(b.star4(-0.34, -1.26, 0.09), gold[1])
        b.fill(b.star4(0.34, -1.26, 0.09), gold[1])

        var front = b.ctx
        front.addFilter(.shadow(color: rgb(1, 0.85, 0.4).opacity(0.9), radius: (0.12 + 0.2 * b.k) * b.r))
        front.stroke(b.arc(0, hy, 0.84 * hs, 0.17 * hs, 0, 180), with: .color(haloColor), style: StrokeStyle(lineWidth: 0.075 * b.r, lineCap: .round))
        b.twinkle(-0.84, -1.86, 0.12, 0.5, rgb(1, 0.95, 0.7))
        b.twinkle(0.6, -2.0, 0.1, 2.8, rgb(1, 0.95, 0.7))

        let st = b.moved(1.5 - 0.1 * b.k, 0.08 + 0.025 * sin(b.t * 1.6) - 0.4 * b.k, 0.07 - 0.07 * b.k)
        st.soft(st.oval(0, -1.0, 0.36 + 0.3 * b.k, 0.36 + 0.3 * b.k), rgb(1, 0.9, 0.5).opacity(0.3 * Double(pulse)), 0.12)
        if b.k > 0.02 { st.glow(st.star4(0, -1.0, 0.5 * b.k), rgb(1, 0.97, 0.8), 0.14) }
        let pole = st.box(-0.04, -0.76, 0.04, 0.95, 0.04)
        st.fill(pole, gold, st.p(-0.04, 0), st.p(0.04, 0))
        st.line(pole, goldEdge, 0.018)
        st.ball(0, -0.74, 0.075, gold[0], gold[2])
        st.line(st.oval(0, -1.0, 0.22, 0.22), goldEdge, 0.1)
        st.line(st.oval(0, -1.0, 0.22, 0.22), gold[1], 0.065)
        st.line(st.curve((0, -1.34), (0, -1.0), (0, -0.78)), gold[1], 0.06)
        st.line(st.curve((-0.22, -1.0), (0, -1.0), (0.22, -1.0)), gold[1], 0.06)
        st.ball(0, -1.0, 0.085, rgb(0.75, 0.92, 1), rgb(0.1, 0.4, 0.9))
        st.twinkle(0.12, -1.16, 0.12, 1.7)
    }

    private func jester(_ b: Brush) {
        let red: [Color] = [rgb(1, 0.5, 0.5), rgb(0.93, 0.2, 0.3), rgb(0.6, 0.05, 0.18)]
        let yellow: [Color] = [rgb(1, 0.97, 0.6), rgb(1, 0.82, 0.25), rgb(0.82, 0.52, 0.06)]
        let purple: [Color] = [rgb(0.62, 0.45, 0.95), rgb(0.38, 0.22, 0.7), rgb(0.2, 0.1, 0.42)]
        let dark = rgb(0.2, 0.06, 0.12)
        let swing = sin(b.t * 3) + b.k * sin(b.u * 44) * 1.6

        func bell(_ x: CGFloat, _ y: CGFloat, _ rad: CGFloat) {
            b.ball(x, y, rad, gold[0], rgb(0.85, 0.55, 0.08))
            b.line(b.oval(x, y, rad, rad), goldEdge, 0.022)
            b.line(b.curve((x - rad * 0.5, y + rad * 0.3), (x, y + rad * 0.55), (x + rad * 0.5, y + rad * 0.3)), goldEdge, 0.025)
            b.fill(b.oval(x, y + rad * 0.45, rad * 0.14, rad * 0.14), goldEdge)
        }

        b.soft(b.oval(0, -0.62, 0.8, 0.13), .black.opacity(0.3), 0.06)
        var mid = Path()
        mid.move(to: b.p(-0.34, -0.9))
        mid.addQuadCurve(to: b.p(0.04 + swing * 0.03, -1.82), control: b.p(-0.4, -1.5))
        mid.addQuadCurve(to: b.p(0.34, -0.9), control: b.p(0.36, -1.45))
        mid.closeSubpath()
        b.fill(mid, purple, b.p(-0.3, -1.6), b.p(0.3, -0.9))
        b.line(mid, rgb(0.1, 0.04, 0.25), 0.028)
        bell(0.04 + swing * 0.04, -1.9, 0.12)

        var left = Path()
        left.move(to: b.p(-0.74, -0.8))
        left.addCurve(to: b.p(-1.52, -1.0), control1: b.p(-0.86, -1.82), control2: b.p(-1.56, -1.78))
        left.addQuadCurve(to: b.p(0.04, -0.84), control: b.p(-0.84, -1.3))
        left.closeSubpath()
        var right = Path()
        right.move(to: b.p(0.74, -0.8))
        right.addCurve(to: b.p(1.52, -1.0), control1: b.p(0.86, -1.82), control2: b.p(1.56, -1.78))
        right.addQuadCurve(to: b.p(-0.04, -0.84), control: b.p(0.84, -1.3))
        right.closeSubpath()
        b.fill(left, red, b.p(-1.1, -1.7), b.p(-0.4, -0.8))
        b.line(b.curve((-0.8, -1.0), (-0.92, -1.52), (-1.3, -1.52)), .white.opacity(0.35), 0.06)
        for (x, y) in [(-0.6, -1.08), (-0.98, -1.34), (-1.34, -1.3)] as [(CGFloat, CGFloat)] {
            b.fill(b.oval(x, y, 0.065, 0.065), yellow[1])
        }
        b.line(left, dark, 0.028)
        b.fill(right, yellow, b.p(0.5, -1.7), b.p(1.1, -0.8))
        b.line(b.curve((0.62, -1.06), (0.7, -1.5), (1.1, -1.56)), .white.opacity(0.5), 0.06)
        for (x, y) in [(0.6, -1.08), (0.98, -1.34), (1.34, -1.3)] as [(CGFloat, CGFloat)] {
            b.fill(b.oval(x, y, 0.065, 0.065), red[1])
        }
        b.line(right, rgb(0.4, 0.22, 0.02), 0.028)
        bell(-1.56, -0.92 + swing * 0.05, 0.15)
        bell(1.56, -0.92 - swing * 0.05, 0.15)

        var band = Path()
        band.move(to: b.p(-0.78, -0.98))
        band.addQuadCurve(to: b.p(0.78, -0.98), control: b.p(0, -0.86))
        band.addLine(to: b.p(0.78, -0.76))
        band.addQuadCurve(to: b.p(-0.78, -0.76), control: b.p(0, -0.62))
        band.closeSubpath()
        b.fill(band, purple, b.p(0, -1.0), b.p(0, -0.66))
        b.line(band, rgb(0.1, 0.04, 0.25), 0.028)
        for i in 0..<7 {
            let x = -0.6 + CGFloat(i) * 0.2
            let y = -0.8 - 0.07 * (1 - (x / 0.7) * (x / 0.7)) + 0.02
            var d = Path()
            d.move(to: b.p(x, y - 0.085))
            d.addLine(to: b.p(x + 0.07, y))
            d.addLine(to: b.p(x, y + 0.085))
            d.addLine(to: b.p(x - 0.07, y))
            d.closeSubpath()
            b.fill(d, i % 2 == 0 ? yellow[1] : red[0])
        }

        let ruff: [[Color]] = [red, yellow, purple]
        for i in 0..<9 {
            let a = (50 + CGFloat(i) * 10) * .pi / 180
            let col = ruff[i % 3]
            b.ball(cos(a) * 1.04, sin(a) * 1.04, 0.17, col[0], col[2])
        }
        for i in 0..<8 {
            let a = (55 + CGFloat(i) * 10) * .pi / 180
            b.ball(cos(a) * 0.9, sin(a) * 0.9 + 0.02, 0.07, .white, rgb(0.8, 0.8, 0.9))
        }

        let balls: [(Color, Color)] = [(rgb(1, 0.6, 0.65), rgb(0.85, 0.1, 0.25)), (rgb(0.65, 0.9, 1), rgb(0.1, 0.5, 0.95)),
                                       (rgb(0.7, 1, 0.7), rgb(0.1, 0.7, 0.3))]
        for i in 0..<3 {
            for trail in [2, 1, 0] {
                let u = fract(b.t * 0.5 + CGFloat(i) / 3 - CGFloat(trail) * (0.022 + 0.03 * b.k) + b.ease * 2)
                let x = -1.5 + 3.0 * u
                let y = -1.2 - (1.15 + 0.4 * b.k) * sin(u * .pi)
                let edge = min(1, sin(u * .pi) * 4)
                if trail == 0 {
                    var g = b.ctx
                    g.opacity = Double(edge)
                    Brush(ctx: g, r: b.r, c: b.c, t: b.t).ball(x, y, 0.13, balls[i].0, balls[i].1)
                } else {
                    b.fill(b.oval(x, y, 0.11 - CGFloat(trail) * 0.02, 0.11 - CGFloat(trail) * 0.02),
                           balls[i].1.opacity(Double(edge) * (0.3 - Double(trail) * 0.1)))
                }
            }
        }
    }

    private func dracula(_ b: Brush) {
        for side: CGFloat in [-1, 1] {
            let s = side * (1 + 0.22 * b.k)
            var outer = Path()
            outer.move(to: b.p(0.36 * s, 0.98))
            outer.addQuadCurve(to: b.p(1.56 * s, -1.02), control: b.p(1.56 * s, 0.4))
            outer.addQuadCurve(to: b.p(0.9 * s, 0.22), control: b.p(1.06 * s, -0.5))
            outer.addQuadCurve(to: b.p(0.36 * s, 0.98), control: b.p(0.74 * s, 0.76))
            outer.closeSubpath()
            b.fill(outer, [rgb(0.3, 0.27, 0.36), rgb(0.12, 0.1, 0.16), rgb(0.03, 0.02, 0.05)], b.p(1.5 * s, -0.8), b.p(0.6 * s, 0.9))
            var lining = Path()
            lining.move(to: b.p(0.54 * s, 0.86))
            lining.addQuadCurve(to: b.p(1.42 * s, -0.78), control: b.p(1.4 * s, 0.34))
            lining.addQuadCurve(to: b.p(0.9 * s, 0.34), control: b.p(1.04 * s, -0.32))
            lining.closeSubpath()
            b.fill(lining, [rgb(1, 0.3, 0.36), rgb(0.8, 0.06, 0.14), rgb(0.42, 0.01, 0.07)], b.p(1.3 * s, -0.6), b.p(0.7 * s, 0.8))
            b.line(b.curve((1.3 * s, -0.5), (1.2 * s, 0.1), (0.92 * s, 0.5)), .white.opacity(0.28), 0.05)
            b.line(outer, rgb(0.02, 0.01, 0.04), 0.03)
            b.line(b.curve((0.42 * s, 0.98), (1.58 * s, 0.42), (1.56 * s, -1.0)), gold[1].opacity(0.9), 0.025)
        }
        b.soft(b.oval(0, -0.58, 0.8, 0.12), .black.opacity(0.3), 0.06)
        var hair = Path()
        hair.move(to: b.p(-0.98, -0.46))
        hair.addCurve(to: b.p(0.98, -0.46), control1: b.p(-1.04, -1.44), control2: b.p(1.04, -1.44))
        hair.addQuadCurve(to: b.p(0.26, -0.78), control: b.p(0.62, -0.7))
        hair.addLine(to: b.p(0, -0.52))
        hair.addLine(to: b.p(-0.26, -0.78))
        hair.addQuadCurve(to: b.p(-0.98, -0.46), control: b.p(-0.62, -0.7))
        hair.closeSubpath()
        b.fill(hair, [rgb(0.34, 0.33, 0.45), rgb(0.1, 0.1, 0.15), rgb(0.02, 0.02, 0.04)], b.p(-0.4, -1.25), b.p(0.4, -0.5))
        b.line(b.arc(0, -0.5, 0.74, 0.58, 216, 262), .white.opacity(0.55), 0.06)
        b.line(b.arc(0, -0.5, 0.6, 0.44, 222, 250), .white.opacity(0.25), 0.04)
        b.line(b.arc(0, -0.5, 0.78, 0.62, 292, 318), rgb(0.6, 0.62, 0.85).opacity(0.3), 0.04)
        b.line(hair, rgb(0.01, 0.01, 0.03), 0.03)

        b.line(b.curve((-0.5, 0.9), (-0.3, 1.04), (-0.12, 1.0)), gold[1], 0.03)
        b.line(b.curve((0.5, 0.9), (0.3, 1.04), (0.12, 1.0)), gold[1], 0.03)
        b.ball(0, 1.0, 0.16, gold[0], gold[2])
        b.line(b.oval(0, 1.0, 0.16, 0.16), goldEdge, 0.022)
        b.ball(0, 1.0, 0.1, rgb(1, 0.55, 0.6), rgb(0.7, 0.02, 0.1))
        b.twinkle(0.05, 0.95, 0.12, 2.2)

        drawBat(b.moved(1.42 + 0.2 * cos(b.t * 1.3), -1.52 + 0.1 * sin(b.t * 2.6), 0.12 * sin(b.t * 1.3)), 0)
        if b.k > 0.02 {
            for i in 0..<4 {
                let a = -0.35 - CGFloat(i) * 0.8
                let d = 0.9 + 1.3 * b.ease
                drawBat(b.faded(min(1, b.k * 1.5)).moved(cos(a) * d, -0.4 + sin(a) * d, sin(b.t * 3 + CGFloat(i)) * 0.3), CGFloat(i) * 1.3)
            }
        }
    }

    private func drawBat(_ bat: Brush, _ phase: CGFloat) {
        let flap = sin(bat.t * 11 + phase)
        let body = rgb(0.16, 0.1, 0.24)
        for s: CGFloat in [-1, 1] {
            var wing = Path()
            wing.move(to: bat.p(0.04 * s, -0.04))
            wing.addLine(to: bat.p(0.24 * s, -0.12 - 0.18 * flap))
            wing.addLine(to: bat.p(0.5 * s, -0.02 - 0.26 * flap))
            wing.addQuadCurve(to: bat.p(0.36 * s, 0.07 - 0.1 * flap), control: bat.p(0.44 * s, 0.0 - 0.14 * flap))
            wing.addQuadCurve(to: bat.p(0.22 * s, 0.07 - 0.04 * flap), control: bat.p(0.29 * s, 0.0 - 0.08 * flap))
            wing.addQuadCurve(to: bat.p(0.05 * s, 0.07), control: bat.p(0.14 * s, 0.02))
            wing.closeSubpath()
            bat.fill(wing, [rgb(0.36, 0.24, 0.5), body], bat.p(0.3 * s, -0.3), bat.p(0.2 * s, 0.1))
            bat.line(wing, rgb(0.05, 0.02, 0.1), 0.015)
            var ear = Path()
            ear.move(to: bat.p(0.025 * s, -0.09))
            ear.addLine(to: bat.p(0.075 * s, -0.19))
            ear.addLine(to: bat.p(0.085 * s, -0.07))
            ear.closeSubpath()
            bat.fill(ear, body)
        }
        bat.fill(bat.oval(0, 0, 0.09, 0.12), body)
        bat.fill(bat.oval(-0.035, -0.03, 0.018, 0.018), rgb(1, 0.3, 0.35))
        bat.fill(bat.oval(0.035, -0.03, 0.018, 0.018), rgb(1, 0.3, 0.35))
    }
}

struct SparkleView: View {
    static let size: CGFloat = 520
    let age: CGFloat
    let seed: Int

    private func rand(_ i: Int, _ k: Int) -> CGFloat {
        var x = UInt64(truncatingIfNeeded: seed &* 6151 &+ i &* 92_821 &+ k &* 3_571)
        x ^= x >> 31
        x = x &* 0x9e3779b97f4a7c15
        x ^= x >> 29
        return CGFloat(x % 10_000) / 10_000
    }

    private func star(_ q: CGPoint, _ s: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: q.x, y: q.y - s))
        path.addQuadCurve(to: CGPoint(x: q.x + s * 0.8, y: q.y), control: q)
        path.addQuadCurve(to: CGPoint(x: q.x, y: q.y + s), control: q)
        path.addQuadCurve(to: CGPoint(x: q.x - s * 0.8, y: q.y), control: q)
        path.addQuadCurve(to: CGPoint(x: q.x, y: q.y - s), control: q)
        return path
    }

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let tints: [Color] = [.white, rgb(1, 0.92, 0.55), rgb(0.75, 0.95, 1), rgb(1, 0.75, 0.9)]

            let flash = max(0, 1 - abs(age - 0.45) / 0.2)
            if flash > 0 {
                let fr = 80 + 50 * flash
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - fr, y: c.y - fr, width: fr * 2, height: fr * 2)),
                         with: .radialGradient(Gradient(colors: [.white.opacity(Double(0.85 * flash)), rgb(1, 0.95, 0.7).opacity(Double(0.35 * flash)), .white.opacity(0)]),
                                               center: c, startRadius: 0, endRadius: fr))
            }

            let ringT = (age - 0.45) / 0.55
            if ringT > 0 && ringT < 1 {
                let e = 1 - pow(1 - ringT, 3)
                let rr = 50 + 70 * e
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                           with: .color(rgb(1, 0.95, 0.7).opacity(Double(0.45 * (1 - ringT)))), lineWidth: 2.5 * (1 - ringT) + 0.5)
                for i in 0..<12 {
                    let a = CGFloat(i) / 12 * 2 * .pi + 0.2
                    let d = 60 + 110 * e
                    let q = CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d)
                    var g = ctx
                    g.addFilter(.shadow(color: tints[i % 4].opacity(0.9), radius: 5))
                    g.fill(star(q, (i % 2 == 0 ? 13 : 8) * (1 - ringT)), with: .color(tints[i % 4]))
                }
            }

            let orbitFade = min(1, age / 0.15) * max(0, min(1, (1.0 - age) / 0.25))
            if orbitFade > 0 {
                for i in 0..<10 {
                    let lane = CGFloat(i % 2)
                    let a = age * 9 + CGFloat(i) / 10 * 2 * .pi
                    let depth = sin(a)
                    let rise = (CGFloat(i) / 10 - 0.5) * 120 - age * 30
                    let q = CGPoint(x: c.x + cos(a) * (72 + lane * 18), y: c.y + rise + depth * 12)
                    let s = (5 + 5 * (depth + 1) / 2) * orbitFade
                    var g = ctx
                    g.opacity = Double(0.35 + 0.65 * (depth + 1) / 2)
                    g.addFilter(.shadow(color: tints[i % 4].opacity(0.9), radius: 4))
                    g.fill(star(q, s), with: .color(tints[i % 4]))
                }
            }

            let poseT = (age - 0.9) / 0.6
            if poseT > 0 && poseT < 1 {
                let k = sin(poseT * .pi)
                let q = CGPoint(x: c.x + 78, y: c.y - 92)
                var g = ctx
                g.addFilter(.shadow(color: .white, radius: 8))
                g.translateBy(x: q.x, y: q.y)
                g.rotate(by: .radians(Double(poseT) * 1.2))
                g.fill(star(.zero, 30 * k), with: .color(.white))
                g.rotate(by: .radians(.pi / 4))
                g.fill(star(.zero, 14 * k), with: .color(rgb(1, 0.95, 0.7)))
                let e = 1 - pow(1 - poseT, 3)
                for i in 0..<10 {
                    let a = CGFloat(i) / 10 * 2 * .pi + 0.3
                    let d0 = 92 + 26 * e, d1 = d0 + 20 * (1 - poseT)
                    var dash = Path()
                    dash.move(to: CGPoint(x: c.x + cos(a) * d0, y: c.y + sin(a) * d0))
                    dash.addLine(to: CGPoint(x: c.x + cos(a) * d1, y: c.y + sin(a) * d1))
                    ctx.stroke(dash, with: .color(rgb(1, 0.95, 0.65).opacity(Double(1 - poseT))),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round))
                }
            }

            for i in 0..<22 {
                let start = 0.4 + rand(i, 1) * 0.7
                let life = 0.45 + rand(i, 2) * 0.35
                let t = (age - start) / life
                if t <= 0 || t >= 1 { continue }
                let a = rand(i, 3) * 2 * .pi
                let dist = 55 + rand(i, 4) * 95
                let q = CGPoint(x: c.x + cos(a) * dist, y: c.y + sin(a) * dist * 0.85 - t * 30)
                let s = (5 + rand(i, 5) * 10) * sin(t * .pi)
                var g = ctx
                g.addFilter(.shadow(color: tints[i % 4].opacity(0.9), radius: 4))
                g.fill(star(q, s), with: .color(tints[i % 4]))
            }
        }
        .allowsHitTesting(false)
    }
}
