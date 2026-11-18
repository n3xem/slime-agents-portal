import AppKit
import SwiftUI

final class AppState: ObservableObject {
    @Published var openBodyId: Int?
    @Published var editingTemplateId: String?
    @Published var shellOpen = false
    @Published var sideShellFor: Int?
    @Published var dirRequest: DirectoryRequest?
    /// 開いている Markdown。差し替えたり閉じたりしたら、前の文書を保存しきる。
    @Published var editor: MarkdownDocument? {
        didSet {
            guard let old = oldValue, old !== editor else { return }
            let message: String? = MainActor.assumeIsolated {
                if old.saveState == .conflict {
                    let ask = NSAlert()
                    ask.messageText = "「\(old.url.lastPathComponent)」はほかで変更されています"
                    ask.informativeText = "こちらの変更はまだ保存していません。閉じる前に、どちらの内容を残すか選んでください。"
                    ask.addButton(withTitle: "こちらの内容で上書き")
                    ask.addButton(withTitle: "外の内容を残す")
                    ask.alertStyle = .warning
                    if ask.runModal() == .alertFirstButtonReturn { old.overwrite() } else { old.reloadFromDisk() }
                }
                return old.close()
            }
            guard let message else { return }
            let alert = NSAlert()
            alert.messageText = "「\(old.url.lastPathComponent)」を保存できませんでした"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
    @Published var anchor: UnitPoint = .center
    /// 閉じかけのパネルの写し。縮みながら消える。
    @Published var ghosts: [PanelGhost] = []
    var panelFrames: [PanelSlot: CGRect] = [:]
    weak var window: NSWindow?
    var openRequests: [(SoftBody, URL)] = []
}

extension TemplateModel {
    var swiftColor: Color {
        Color(red: Double(color[safe: 0] ?? 0.6), green: Double(color[safe: 1] ?? 0.6), blue: Double(color[safe: 2] ?? 0.6))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

private let panelBackground = Color(red: 0.055, green: 0.06, blue: 0.085)

struct TemplateBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [color.opacity(1), color.opacity(0.55)], center: UnitPoint(x: 0.35, y: 0.3),
                                     startRadius: 1, endRadius: size * 0.7))
            Circle()
                .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0)], startPoint: .top, endPoint: .center))
                .padding(size * 0.12)
                .offset(y: -size * 0.06)
                .mask(Circle())
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.5), radius: 6)
    }
}

struct PanelChrome<Header: View, Content: View>: View {
    let color: Color
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .frame(height: 56)
            Rectangle().fill(color.opacity(0.35)).frame(height: 1)
            content
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(LinearGradient(colors: [color.opacity(0.9), color.opacity(0.15)], startPoint: .top, endPoint: .bottom),
                              lineWidth: 1.5)
        )
        .shadow(color: color.opacity(0.35), radius: 40)
        .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
    }
}

struct CloseButton: View {
    let action: () -> Void
    var help = "閉じる（セッションは動き続けます）"
    var symbol = "xmark"
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.7))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(hover ? 0.18 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

final class TerminalContainer: NSView {
    weak var terminal: NSView?

    override func layout() {
        super.layout()
        terminal?.frame = bounds
    }
}

struct TerminalHost: NSViewRepresentable {
    let terminal: NSView

    func makeNSView(context: Context) -> TerminalContainer {
        let c = TerminalContainer()
        attach(to: c)
        return c
    }

    func updateNSView(_ nsView: TerminalContainer, context: Context) {
        if terminal.superview !== nsView { attach(to: nsView) }
    }

    private func attach(to c: TerminalContainer) {
        let v = terminal
        v.removeFromSuperview()
        v.frame = c.bounds
        c.addSubview(v)
        c.terminal = v
        DispatchQueue.main.async {
            v.window?.makeFirstResponder(v)
        }
    }

    static func dismantleNSView(_ nsView: TerminalContainer, coordinator: ()) {
        nsView.terminal?.removeFromSuperview()
    }
}

struct TerminalPanel: View {
    @ObservedObject var session: ClaudeSession
    var title: String?
    let close: () -> Void
    var openShell: (() -> Void)?

    private var color: Color { session.template.swiftColor }

    var body: some View {
        PanelChrome(color: color) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    TemplateBadge(symbol: session.template.symbol, color: color)
                    EngineMark(engine: .claude, size: 16).offset(x: 4, y: 4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title ?? session.template.name)
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                        Text("宛先: \(session.name)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    HStack(spacing: 6) {
                        Text("\(session.template.name) · \((session.currentDirectory as NSString).abbreviatingWithTildeInPath)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ConfigBadge(symbol: "lock.fill", text: "サンドボックス: " + session.config.sandbox.short,
                                    active: session.config.sandbox == .on || session.config.sandbox == .strict)
                        ConfigBadge(symbol: "hand.raised.fill",
                                    text: session.config.permissionMode.isEmpty ? "権限: 既定" : "権限: " + session.config.permissionMode,
                                    active: !session.config.permissionMode.isEmpty)
                        if session.config.worktree {
                            ConfigBadge(symbol: "arrow.triangle.branch", text: "worktree", active: true)
                        }
                        if let chrome = session.config.chrome {
                            ConfigBadge(symbol: "globe", text: chrome ? "Chrome" : "Chrome なし", active: chrome)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                StatusChip(session: session)
                if let openShell {
                    CloseButton(action: openShell, help: "このスライムと同じディレクトリでターミナルを開く", symbol: "terminal.fill")
                }
                CloseButton(action: close)
            }
        } content: {
            ZStack {
                TerminalHost(terminal: session.nsView)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                if session.exited {
                    VStack(spacing: 12) {
                        Text("セッションは終了しました" + (session.exitCode.map { "（終了コード \($0)）" } ?? ""))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Button("会話を再開する") { session.start(resume: true) }
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

struct ShellPanel: View {
    @ObservedObject var session: ShellSession
    let close: () -> Void

    private let color = Color(white: 0.62)

    var body: some View {
        PanelChrome(color: color) {
            HStack(spacing: 12) {
                TemplateBadge(symbol: "terminal.fill", color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ターミナル")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text((session.currentDirectory as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                CloseButton(action: close)
            }
        } content: {
            ZStack {
                TerminalHost(terminal: session.view)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                if session.exited {
                    VStack(spacing: 12) {
                        Text("シェルは終了しました" + (session.exitCode.map { "（終了コード \($0)）" } ?? ""))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Button("もう一度開く") { session.start() }
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

struct StatusChip: View {
    @ObservedObject var session: ClaudeSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { _ in
            let (text, c): (String, Color) = {
                switch session.state {
                case .starting: return ("起動中", .yellow)
                case .busy: return ("作業中", .orange)
                case .waiting: return ("入力待ち", .green)
                case .exited: return ("終了", .gray)
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

struct TemplateEditorView: View {
    @ObservedObject var store: TemplateStore
    let id: String

    private func binding<T>(_ kp: WritableKeyPath<TemplateModel, T>, _ fallback: T) -> Binding<T> {
        Binding(
            get: { store.template(id)?[keyPath: kp] ?? fallback },
            set: { v in
                if let i = store.templates.firstIndex(where: { $0.id == id }) { store.templates[i][keyPath: kp] = v }
            }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { store.template(id)?.swiftColor ?? .gray },
            set: { c in
                guard let ns = NSColor(c).usingColorSpace(.sRGB),
                      let i = store.templates.firstIndex(where: { $0.id == id }) else { return }
                store.templates[i].color = [Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent)]
            }
        )
    }

    private var sandboxBinding: Binding<SandboxMode?> {
        Binding(
            get: { store.template(id)?.sandbox },
            set: { v in if let i = store.templates.firstIndex(where: { $0.id == id }) { store.templates[i].sandbox = v } }
        )
    }

    private var permissionBinding: Binding<String> {
        Binding(
            get: { store.template(id)?.permissionMode ?? "" },
            set: { v in if let i = store.templates.firstIndex(where: { $0.id == id }) { store.templates[i].permissionMode = v.isEmpty ? nil : v } }
        )
    }

    private var chromeBinding: Binding<Bool?> {
        Binding(
            get: { store.template(id)?.chrome },
            set: { v in if let i = store.templates.firstIndex(where: { $0.id == id }) { store.templates[i].chrome = v } }
        )
    }

    private var worktreeBinding: Binding<Bool> {
        Binding(
            get: { store.template(id)?.worktree ?? true },
            set: { v in if let i = store.templates.firstIndex(where: { $0.id == id }) { store.templates[i].worktree = v } }
        )
    }

    private var engineBinding: Binding<Engine> {
        Binding(
            get: { store.template(id)?.engine ?? .claude },
            set: { v in
                guard let i = store.templates.firstIndex(where: { $0.id == id }), (store.templates[i].engine ?? .claude) != v else { return }
                var t = store.templates[i]
                t.engine = v == .claude ? nil : v
                t.model = nil
                t.effort = nil
                if v == .agy {
                    t.sandbox = .on
                    t.permissionMode = "accept-edits"
                } else {
                    t.sandbox = nil
                    t.permissionMode = nil
                }
                store.templates[i] = t
            }
        )
    }

    private var agySandboxBinding: Binding<Bool> {
        Binding(
            get: { (store.template(id)?.sandbox ?? .on) != .off },
            set: { v in if let i = store.templates.firstIndex(where: { $0.id == id }) { store.templates[i].sandbox = v ? .on : .off } }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { store.template(id)?.model ?? "" },
            set: { v in
                let t = v.trimmingCharacters(in: .whitespaces)
                if let i = store.templates.firstIndex(where: { $0.id == id }) { store.templates[i].model = t.isEmpty ? nil : t }
            }
        )
    }

    private var effortBinding: Binding<String> {
        Binding(
            get: { store.template(id)?.effort ?? "" },
            set: { v in if let i = store.templates.firstIndex(where: { $0.id == id }) { store.templates[i].effort = v.isEmpty ? nil : v } }
        )
    }

    @State private var agyModels: [(value: String, label: String)] = []

    private var workdirBinding: Binding<String> {
        Binding(
            get: { store.template(id)?.workdir ?? "" },
            set: { v in
                if let i = store.templates.firstIndex(where: { $0.id == id }) { store.templates[i].workdir = v.isEmpty ? nil : v }
            }
        )
    }

    var body: some View {
        if let t = store.template(id) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    ZStack(alignment: .bottomTrailing) {
                        TemplateBadge(symbol: t.symbol, color: t.swiftColor, size: 56)
                        EngineMark(engine: t.engine ?? .claude, size: 22).offset(x: 5, y: 5)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("テンプレート名", text: binding(\.name, ""))
                            .textFieldStyle(.plain)
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
                        HStack(spacing: 14) {
                            ColorPicker("色", selection: colorBinding, supportsOpacity: false)
                                .fixedSize()
                            Text("アイコン")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            TextField("SF Symbols 名", text: binding(\.symbol, ""))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 12), alignment: .leading, spacing: 6) {
                    ForEach(TemplateStore.symbolPresets, id: \.self) { s in
                        Button {
                            binding(\.symbol, "").wrappedValue = s
                        } label: {
                            Image(systemName: s)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 32, height: 28)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(t.symbol == s ? t.swiftColor.opacity(0.55) : Color.white.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("作業ディレクトリ").font(.system(size: 12, weight: .semibold))
                    HStack {
                        TextField(store.settings.defaultWorkdir + "（既定）", text: workdirBinding)
                            .textFieldStyle(.roundedBorder)
                        Button("選ぶ…") {
                            if let path = chooseDirectory() { workdirBinding.wrappedValue = path }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text("エンジン").font(.system(size: 12, weight: .semibold))
                        Picker("エンジン", selection: engineBinding) {
                            ForEach(Engine.allCases, id: \.self) { e in
                                Text(e.label).tag(e)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        EngineMark(engine: t.engine ?? .claude, size: 22)
                    }
                    Text((t.engine ?? .claude) == .agy
                         ? "Antigravity CLI を端末で動かします。Claude Code のスライムとは矢印でつなげず、管理セッションからもメッセージは送れません。"
                         : "Claude Code を端末で動かします。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("起動の設定（スライムごとに右クリックで上書きできます）").font(.system(size: 12, weight: .semibold))
                    if (t.engine ?? .claude) == .agy {
                        HStack(spacing: 16) {
                            Toggle("サンドボックス（--sandbox）", isOn: agySandboxBinding)
                                .fixedSize()
                            Picker("モード", selection: permissionBinding) {
                                ForEach(AgyModes.all, id: \.value) { Text($0.label).tag($0.value) }
                            }
                        }
                        .font(.system(size: 12))
                    } else {
                        HStack(spacing: 16) {
                            Picker("サンドボックス", selection: sandboxBinding) {
                                Text("全体の既定（\(store.defaultSandbox.short)）").tag(SandboxMode?.none)
                                ForEach(SandboxMode.allCases, id: \.self) { Text($0.label).tag(SandboxMode?.some($0)) }
                            }
                            Picker("権限モード", selection: permissionBinding) {
                                ForEach(PermissionModes.all, id: \.value) { Text($0.label).tag($0.value) }
                            }
                        }
                        .font(.system(size: 12))
                        HStack(spacing: 16) {
                            Toggle("worktree を作って起動", isOn: worktreeBinding)
                                .fixedSize()
                            Picker("Chrome 連携", selection: chromeBinding) {
                                Text("既定（指定しない）").tag(Bool?.none)
                                Text("オン（--chrome）").tag(Bool?.some(true))
                                Text("オフ（--no-chrome）").tag(Bool?.some(false))
                            }
                            .fixedSize()
                        }
                        .font(.system(size: 12))
                    }
                    HStack(spacing: 10) {
                        Text("モデル").font(.system(size: 12))
                        TextField("既定（空欄）", text: modelBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                        Menu("候補") {
                            Button("既定（指定しない）") { modelBinding.wrappedValue = "" }
                            Divider()
                            ForEach((t.engine ?? .claude) == .agy ? agyModels : ModelCatalog.claude, id: \.value) { m in
                                Button(m.value == m.label ? m.value : "\(m.label)（\(m.value)）") { modelBinding.wrappedValue = m.value }
                            }
                        }
                        .fixedSize()
                        Picker("effort", selection: effortBinding) {
                            ForEach(EffortLevels.all, id: \.value) { Text($0.label).tag($0.value) }
                        }
                        .fixedSize()
                    }
                    .font(.system(size: 12))
                }
                .task(id: t.engine) {
                    guard (t.engine ?? .claude) == .agy, agyModels.isEmpty else { return }
                    let list = await Task.detached { ModelCatalog.agy() }.value
                    agyModels = list
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("AGENTS.md").font(.system(size: 13, weight: .heavy, design: .monospaced))
                        Text((t.engine ?? .claude) == .agy
                             ? "新しい会話を始めるときに、最初の依頼（agy -i）として渡します。会話を続けているスライムには反映されません。"
                             : "スライムのセッションを起動するときに --append-system-prompt で渡します。起動済みのセッションには反映されません。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    TextEditor(text: binding(\.agents, ""))
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.4)))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(t.swiftColor.opacity(0.35), lineWidth: 1))
                }
            }
        } else {
            Text("このテンプレートは削除されました").foregroundStyle(.secondary)
        }
    }
}

func chooseDirectory() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "選択"
    return panel.runModal() == .OK ? panel.url?.path : nil
}

struct TemplatePanel: View {
    @ObservedObject var store: TemplateStore
    let id: String
    let close: () -> Void

    var body: some View {
        let t = store.template(id)
        PanelChrome(color: t?.swiftColor ?? .gray) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                Text("テンプレートを編集")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Button(role: .destructive) {
                    store.deleteTemplate(id)
                    close()
                } label: {
                    Label("削除", systemImage: "trash")
                }
                .disabled(store.templates.count <= 1)
                SettingsLink {
                    Label("すべてのテンプレート", systemImage: "gearshape")
                }
                CloseButton(action: close)
            }
        } content: {
            TemplateEditorView(store: store, id: id)
                .padding(20)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: TemplateStore
    @State private var selection: String?

    var body: some View {
        TabView {
            templatesTab
                .tabItem { Label("テンプレート", systemImage: "square.stack.3d.up.fill") }
            generalTab
                .tabItem { Label("一般", systemImage: "gearshape") }
        }
        .frame(width: 900, height: 640)
        .onAppear { if selection == nil { selection = store.templates.first?.id } }
    }

    private var templatesTab: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.templates) { t in
                        HStack(spacing: 10) {
                            TemplateBadge(symbol: t.symbol, color: t.swiftColor, size: 24)
                            Text(t.name)
                            Spacer()
                            EngineMark(engine: t.engine ?? .claude, size: 16)
                        }
                        .padding(.vertical, 3)
                        .tag(t.id)
                    }
                    .onMove { store.templates.move(fromOffsets: $0, toOffset: $1) }
                }
                HStack(spacing: 0) {
                    Button {
                        selection = store.addTemplate()
                    } label: {
                        Image(systemName: "plus").frame(width: 28, height: 24)
                    }
                    Button {
                        guard let sel = selection, store.templates.count > 1 else { return }
                        let idx = store.templates.firstIndex { $0.id == sel } ?? 0
                        store.deleteTemplate(sel)
                        selection = store.templates[safe: max(0, idx - 1)]?.id
                    } label: {
                        Image(systemName: "minus").frame(width: 28, height: 24)
                    }
                    .disabled(selection == nil || store.templates.count <= 1)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 230)
            Divider()
            Group {
                if let sel = selection {
                    TemplateEditorView(store: store, id: sel)
                } else {
                    Text("左の一覧からテンプレートを選んでください").foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var generalTab: some View {
        Form {
            Section("Claude Code") {
                HStack {
                    TextField("既定の作業ディレクトリ", text: $store.settings.defaultWorkdir)
                    Button("選ぶ…") {
                        if let p = chooseDirectory() { store.settings.defaultWorkdir = p }
                    }
                }
                Picker("サンドボックスの既定", selection: Binding(
                    get: { store.settings.defaultSandbox ?? .on },
                    set: { store.settings.defaultSandbox = $0 }
                )) {
                    ForEach(SandboxMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("起動コマンド", text: $store.settings.claudeCommand)
                TextField("追加の引数", text: $store.settings.extraArgs, prompt: Text("例: --model opus"))
            }
            Section("保存先") {
                HStack {
                    Text(store.baseURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "-")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Finder で開く") { store.openInFinder() }
                }
            }
        }
        .formStyle(.grouped)
        .padding(10)
    }
}

struct ConfigBadge: View {
    let symbol: String
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(active ? 0.9 : 0.45))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(.white.opacity(active ? 0.14 : 0.05)))
        .fixedSize()
    }
}
