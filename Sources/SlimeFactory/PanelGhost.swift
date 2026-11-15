import AppKit
import SwiftUI

/// ターミナルとエディタのパネル。中身が AppKit のビューなので、SwiftUI の縮小やぼかしが中身にかからない。
/// そこで閉じるときはパネルを画像に写し取り、その画像を縮めながら消す（`PanelGhost`）。
enum PanelSlot: Hashable {
    case terminal
    case editor
}

struct PanelGhost: Identifiable {
    let id = UUID()
    let image: NSImage
    let frame: CGRect
    /// 縮む先。パネルの左上を (0, 0)、右下を (1, 1) とした位置で、パネルの外でもよい。
    let anchor: UnitPoint
    var p: CGFloat = 0
}

struct PanelGhostView: View {
    let ghost: PanelGhost

    var body: some View {
        Image(nsImage: ghost.image)
            .resizable()
            .frame(width: ghost.frame.width, height: ghost.frame.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.5 * Double(1 - ghost.p)), radius: 20, y: 10)
            .scaleEffect(1 - 0.14 * ghost.p, anchor: ghost.anchor)
            .blur(radius: 6 * ghost.p)
            .opacity(Double(1 - ghost.p))
            .position(x: ghost.frame.midX, y: ghost.frame.midY)
            .allowsHitTesting(false)
    }
}

extension AnyTransition {
    /// 出るときだけのトランジション。消えるときは `PanelGhost` が受け持つ。
    static func panelIn(anchor: UnitPoint) -> AnyTransition {
        .asymmetric(insertion: .scale(scale: 0.15, anchor: anchor).combined(with: .opacity), removal: .identity)
    }
}

extension View {
    /// パネルの位置（ウィンドウの左上が原点）を覚えておく。閉じるときに写し取る範囲になる。
    func trackPanelFrame(_ slot: PanelSlot, in ui: AppState) -> some View {
        background(GeometryReader { g in
            Color.clear
                .onAppear { ui.panelFrames[slot] = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in ui.panelFrames[slot] = f }
        })
    }
}

/// SwiftUI のビューが載っているウィンドウを知らせる。
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    final class Probe: NSView {
        var found: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found?(window)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.found = found
        return v
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.found = found
    }
}

@MainActor
func snapshotPanel(in window: NSWindow?, rect: CGRect) -> NSImage? {
    guard let view = window?.contentView, rect.width > 1, rect.height > 1 else { return nil }
    let r = view.isFlipped ? rect : CGRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    guard let rep = view.bitmapImageRepForCachingDisplay(in: r) else { return nil }
    view.cacheDisplay(in: r, to: rep)
    let image = NSImage(size: rect.size)
    image.addRepresentation(rep)
    return image
}
