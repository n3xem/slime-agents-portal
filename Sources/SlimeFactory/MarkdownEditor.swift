import AppKit
import SwiftUI

/// アプリの中で開いた .md ファイル。編集すると少し待ってから自動で保存し、
/// ほかのプロセス（Claude Code のセッションなど）が書き換えたら、こちらで編集中でなければ読み込み直す。
/// こちらの未保存の編集と外の変更がぶつかったら、どちらも捨てずに止まり、人に選んでもらう（`conflict`）。
@MainActor
final class MarkdownDocument: ObservableObject {
    enum SaveState: Equatable {
        case saved
        case editing
        /// 未保存の編集があるうちに、ほかで書き換えられた。自動保存を止めている。
        case conflict
        case failed(String)
    }

    enum OpenError: LocalizedError {
        case notUTF8
        var errorDescription: String? { "UTF-8 のテキストとして読めませんでした。" }
    }

    static let saveDelay: TimeInterval = 0.3
    /// 終了時に保存しきるため、開いている文書を覚えておく。
    static weak var current: MarkdownDocument?

    let url: URL
    private(set) var text: String
    @Published private(set) var saveState: SaveState = .saved
    /// ディスクから読み込み直して `text` を差し替えたら増える。エディタはこれを見て表示を入れ替える。
    @Published private(set) var revision = 0

    private var pending: DispatchWorkItem?
    /// 最後に読み込んだか保存したときのディスクの内容と更新日時。外で変わったかをこれと比べて決める。
    private var diskText: String
    private var diskDate: Date?
    private var watcher: Timer?

    init(url: URL) throws {
        self.url = url.resolvingSymlinksInPath()
        guard let s = try Self.read(self.url) else { throw OpenError.notUTF8 }
        text = s
        diskText = s
        diskDate = Self.modificationDate(self.url)
        watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDisk() }
        }
        Self.current = self
    }

    func edit(_ s: String) {
        text = s
        if saveState == .conflict { return }
        saveState = .editing
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    /// 待っている保存をすぐに行う。保存できたら true。ぶつかっているときは保存しない。
    @discardableResult
    func flush() -> Bool {
        pending?.cancel()
        pending = nil
        if saveState == .editing || isFailed { save() }
        return saveState == .saved
    }

    /// ぶつかったとき: こちらの内容で上書きする。
    func overwrite() {
        pending?.cancel()
        pending = nil
        write()
    }

    /// ぶつかったとき: こちらの編集を捨てて、ディスクの内容を読み込む。
    func reloadFromDisk() {
        pending?.cancel()
        pending = nil
        guard let s = try? Self.read(url) else {
            saveState = .failed("ファイルを読み込めませんでした。")
            return
        }
        take(s)
        saveState = .saved
    }

    /// 保存しきってから監視を止める。保存できなかったときはその理由を返す。
    func close() -> String? {
        let ok = flush()
        watcher?.invalidate()
        watcher = nil
        if Self.current === self { Self.current = nil }
        if ok { return nil }
        switch saveState {
        case .conflict: return "ほかで変更されていたため、こちらの変更は保存していません。"
        case .failed(let message): return message
        default: return "保存できませんでした。"
        }
    }

    private var isFailed: Bool {
        if case .failed = saveState { return true }
        return false
    }

    private func save() {
        if externalChange() != nil {
            saveState = .conflict
            return
        }
        write()
    }

    private func write() {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            diskText = text
            diskDate = Self.modificationDate(url)
            saveState = .saved
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    /// ディスクの内容と日時をこちらに取り込み、エディタの表示を入れ替える。
    private func take(_ s: String) {
        diskText = s
        diskDate = Self.modificationDate(url)
        guard s != text else { return }
        text = s
        revision += 1
    }

    /// 最後に読み込むか保存してから、ほかで内容が変わっていればその内容を返す。日時だけ変わったときは nil。
    private func externalChange() -> String? {
        guard let date = Self.modificationDate(url), date != diskDate else { return nil }
        guard let s = try? Self.read(url) else { return nil }
        if s == diskText {
            diskDate = date
            return nil
        }
        return s
    }

    private func checkDisk() {
        guard let s = externalChange() else { return }
        switch saveState {
        case .saved:
            take(s)
        case .editing, .failed:
            if s == text {
                pending?.cancel()
                take(s)
                saveState = .saved
            } else {
                pending?.cancel()
                saveState = .conflict
            }
        case .conflict:
            // ぶつかったあと、外の内容がこちらと同じになったら、ぶつかりは解けている。
            if s == text {
                take(s)
                saveState = .saved
            }
        }
    }

    private static func read(_ url: URL) throws -> String? {
        String(data: try Data(contentsOf: url), encoding: .utf8)
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

struct MarkdownTextView: NSViewRepresentable {
    /// 見張っていないと、ディスクから読み込み直しても updateNSView が呼ばれない。
    @ObservedObject var document: MarkdownDocument

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let document: MarkdownDocument
        var revision: Int
        /// ウィンドウの取り消し履歴と分けておく。読み込み直したら、この履歴だけを消す。
        let undo = UndoManager()

        init(_ document: MarkdownDocument) {
            self.document = document
            revision = document.revision
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let s = tv.string
            document.edit(s)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(document) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.drawsBackground = false
        tv.font = .monospacedSystemFont(ofSize: 13.5, weight: .regular)
        tv.textColor = NSColor(white: 0.92, alpha: 1)
        tv.insertionPointColor = .white
        tv.textContainerInset = NSSize(width: 22, height: 16)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        tv.defaultParagraphStyle = para
        tv.typingAttributes[.paragraphStyle] = para
        tv.string = document.text
        tv.delegate = context.coordinator
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.revision != document.revision, let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.revision = document.revision
        // 中身を差し替えると、古い文章を前提にした取り消しが文章を壊すので、履歴を消す。
        // スクロール位置とカーソルは、できるだけ元の場所に戻す。
        let selection = tv.selectedRange()
        let origin = scroll.contentView.bounds.origin
        tv.string = document.text
        context.coordinator.undo.removeAllActions()
        let length = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        if let lm = tv.layoutManager, let tc = tv.textContainer { lm.ensureLayout(for: tc) }
        let maxY = max(0, tv.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: origin.x, y: min(origin.y, maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

struct MarkdownPanel: View {
    @ObservedObject var document: MarkdownDocument
    let close: () -> Void

    private let color = Color(red: 0.38, green: 0.64, blue: 0.98)

    var body: some View {
        PanelChrome(color: color) {
            HStack(spacing: 12) {
                TemplateBadge(symbol: "doc.text.fill", color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.url.lastPathComponent)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text((document.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                saveIndicator
                    .font(.system(size: 11, weight: .semibold))
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([document.url])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Finder で表示")
                CloseButton(action: close, help: "閉じる（保存してから閉じます）")
            }
        } content: {
            VStack(spacing: 0) {
                if document.saveState == .conflict {
                    conflictBanner
                }
                MarkdownTextView(document: document)
            }
        }
    }

    private var conflictBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("このファイルはほかで変更されました")
                    .font(.system(size: 12.5, weight: .bold))
                Text("こちらの変更はまだ保存していません。どちらの内容を残すか選んでください。")
                    .font(.system(size: 11))
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            Spacer()
            Button("外の内容を読み込む") { document.reloadFromDisk() }
                .help("こちらの変更を捨てて、ファイルの今の内容を表示します")
            Button("こちらの内容で上書き") { document.overwrite() }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .help("ほかで変更された内容を、こちらの内容で上書きします")
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.14))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.orange.opacity(0.35)).frame(height: 1) }
    }

    @ViewBuilder private var saveIndicator: some View {
        switch document.saveState {
        case .saved:
            Label("保存済み", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.white.opacity(0.45))
        case .editing:
            Label("保存中…", systemImage: "pencil.circle.fill")
                .foregroundStyle(color.opacity(0.9))
        case .conflict:
            Label("保存を止めています", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .failed(let message):
            Label("保存できません", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(message)
        }
    }
}
