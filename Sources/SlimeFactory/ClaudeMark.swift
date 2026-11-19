import SwiftUI

struct ClaudeMark: View {
    var size: CGFloat = 18

    var body: some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let r = min(sz.width, sz.height) / 2
            ctx.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: sz.width, height: sz.height)), with: .color(Color(white: 0.08).opacity(0.92)))
            ctx.stroke(Path(ellipseIn: CGRect(x: 0.5, y: 0.5, width: sz.width - 1, height: sz.height - 1)),
                       with: .color(.white.opacity(0.22)), lineWidth: 1)
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
        }
        .frame(width: size, height: size)
        .help("Claude Code")
    }
}
