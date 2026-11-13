import AppKit
import SwiftUI

struct DirectoryRequest: Equatable {
    var point: V2
    var islandId: Int?
    var title: String
}

struct DirectoryMatch: Identifiable {
    let path: String
    let name: String
    let detail: String
    let recent: Bool
    let score: Int
    var id: String { path }
}

enum DirectorySearch {
    static func tokens(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init)
    }

    private static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.makeIterator()
        for c in needle {
            var found = false
            while let h = it.next() {
                if h == c { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    private static func score(_ path: String, tokens: [String]) -> Int? {
        let comps = path.lowercased().split(separator: "/")
        let name = comps.last.map(String.init) ?? ""
        let tail = comps.suffix(2).joined(separator: "/")
        let full = path.lowercased()
        var total = 0
        for t in tokens {
            if name == t { total += 100 }
            else if name.hasPrefix(t) { total += 60 }
            else if name.contains(t) { total += 40 }
            else if tail.contains(t) { total += 25 }
            else if full.contains(t) { total += 10 }
            else if isSubsequence(t, of: name) { total += 5 }
            else { return nil }
        }
        return total
    }

    static func filter(_ query: String, recent: [String], repos: [String], limit: Int = 200) -> [DirectoryMatch] {
        var seen = Set<String>()
        var list: [(String, Bool)] = []
        for r in recent where seen.insert(r).inserted { list.append((r, true)) }
        for r in repos where seen.insert(r).inserted { list.append((r, false)) }
        let toks = tokens(query)
        var out: [DirectoryMatch] = []
        let raw = query.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let p = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue, !seen.contains(p) {
                out.append(match(p, recent: false, score: 1000))
            }
        }
        for (p, isRecent) in list {
            if toks.isEmpty {
                out.append(match(p, recent: isRecent, score: isRecent ? 1 : 0))
            } else if let s = score(p, tokens: toks) {
                out.append(match(p, recent: isRecent, score: s + (isRecent ? 15 : 0)))
            }
        }
        if !toks.isEmpty {
            out.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.name.count != b.name.count { return a.name.count < b.name.count }
                return a.name.lowercased() < b.name.lowercased()
            }
        }
        return Array(out.prefix(limit))
    }

    private static func match(_ path: String, recent: Bool, score: Int) -> DirectoryMatch {
        let name = (path as NSString).lastPathComponent
        let parent = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        return DirectoryMatch(path: path, name: name, detail: parent, recent: recent, score: score)
    }

    static func highlighted(_ text: String, tokens: [String], color: Color) -> AttributedString {
        var s = AttributedString(text)
        let lower = text.lowercased()
        for t in tokens {
            guard let r = lower.range(of: t), let ar = Range(NSRange(r, in: lower), in: s) else { continue }
            s[ar].foregroundColor = color
            s[ar].underlineStyle = .single
        }
        return s
    }
}

struct DirectoryPicker: View {
    let title: String
    let recent: [String]
    var existing: Set<String> = []
    var preloaded: [String]?
    var initialQuery = ""
    let choose: (String) -> Void
    let browse: () -> Void
    let close: () -> Void

    @State private var query = ""
    @State private var repos: [String] = []
    @State private var loading = true
    @State private var selection = 0
    @FocusState private var focused: Bool

    private let accent = Color(red: 0.45, green: 0.78, blue: 1.0)

    var body: some View {
        let results = DirectorySearch.filter(query, recent: recent, repos: repos)
        let toks = DirectorySearch.tokens(query)
        PanelChrome(color: accent) {
            HStack(spacing: 12) {
                TemplateBadge(symbol: "folder.fill", color: accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text(loading ? "ghq のリポジトリを読み込んでいます…" : "最近使ったディレクトリ \(recent.count) 件・ghq のリポジトリ \(repos.count) 件")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                CloseButton(action: close)
            }
        } content: {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(accent)
                    TextField("名前やパスで検索（スペースで区切ると絞り込み、/ や ~ で始めるとパスを直接指定）", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .focused($focused)
                        .onSubmit { pick(results) }
                        .onKeyPress(.upArrow) {
                            selection = max(0, selection - 1)
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            selection = min(max(results.count - 1, 0), selection + 1)
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            close()
                            return .handled
                        }
                    if !query.isEmpty {
                        Text("\(results.count) 件")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(accent.opacity(0.45), lineWidth: 1))
                .padding(14)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { idx, m in
                                row(m, tokens: toks, selected: idx == selection)
                                    .contentShape(Rectangle())
                                    .onTapGesture { choose(m.path) }
                                    .onHover { if $0 { selection = idx } }
                            }
                            if results.isEmpty && !loading {
                                Text("「\(query)」に一致するディレクトリはありません")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .padding(.vertical, 30)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    }
                    .onChange(of: selection) { _, s in
                        if results.indices.contains(s) { proxy.scrollTo(results[s].id) }
                    }
                }

                Rectangle().fill(accent.opacity(0.2)).frame(height: 1)
                HStack(spacing: 14) {
                    Text("↑↓ で選ぶ・Enter で決める・Esc で閉じる")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Button("フォルダを選ぶ…", action: browse)
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .onChange(of: query) { _, _ in selection = 0 }
        .onAppear {
            query = initialQuery
            if let preloaded {
                repos = preloaded
                loading = false
            } else {
                DispatchQueue.global(qos: .userInitiated).async {
                    let list = DirectoryCandidates.ghq()
                    DispatchQueue.main.async {
                        repos = list
                        loading = false
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }

    private func pick(_ results: [DirectoryMatch]) {
        guard results.indices.contains(selection) else { return }
        choose(results[selection].path)
    }

    private func row(_ m: DirectoryMatch, tokens: [String], selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: m.recent ? "clock.arrow.circlepath" : "folder")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(m.recent ? accent : .white.opacity(0.55))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(DirectorySearch.highlighted(m.name, tokens: tokens, color: accent))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text(DirectorySearch.highlighted(m.detail, tokens: tokens.filter { !m.name.lowercased().contains($0) },
                                                 color: accent.opacity(0.85)))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if existing.contains(m.path) {
                Text("島あり")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accent.opacity(0.15)))
            }
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? accent.opacity(0.22) : .clear))
    }
}
