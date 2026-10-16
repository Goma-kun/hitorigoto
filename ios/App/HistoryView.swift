import SwiftUI

/// 履歴タブ。拡張機能の履歴パネルと同じ（繰り返し → セッションのカード）
struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    /// 検索の文字。空白区切りで全部の語を含む記録だけ出す（本人要望 2026-10-12）
    @State private var query = ""
    @FocusState private var searching: Bool

    private var words: [String] {
        query.split(whereSeparator: { $0 == " " || $0 == "　" }).map { $0.lowercased() }.filter { !$0.isEmpty }
    }
    private var shown: [Session] {
        words.isEmpty ? model.snapshot.sessions : model.snapshot.sessions.filter { $0.matches(words) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                    TextField(String(localized: "履歴を検索（話した内容・直し・英語ならこう）"), text: $query)
                        .textFieldStyle(.plain)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .focused($searching)
                    if !query.isEmpty {
                        // 日本語入力の変換中（下線つき）の文字は、入力を終わらせてからでないと消えない
                        Button { searching = false; DispatchQueue.main.async { query = "" } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }.buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                // 文字選択は検索欄の外だけに付ける（ScrollView 全体に付けると ✕ が押せなかった・2026-10-12）
                VStack(spacing: 8) {
                    if !words.isEmpty {
                        Text(String(localized: "\(shown.count) 件")).font(.caption).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let recurring = Logic.topRecurring(model.snapshot.recurring)
                    if words.isEmpty, !recurring.isEmpty {
                        // 何の一覧かと、いつのことかが分かるようにする（唐突に見える・2026-09-28 本人指摘）
                        Card(title: String(localized: "また出やがった点（2 回以上出た指摘）")) {
                            ForEach(recurring, id: \.text) { r in
                                RecurringRow(item: r)
                            }
                            Note(text: String(localized: "同じ直しが 2 回以上出たものです。話す前にも出しています。"))
                        }
                    }
                    if model.snapshot.sessions.isEmpty {
                        Note(text: String(localized: "独り言の記録はまだありません"))
                    } else if shown.isEmpty {
                        Note(text: String(localized: "この言葉を含む記録はありません"))
                    }
                    LazyVStack(spacing: 8) {
                        // 検索中は見つかった記録を開いた状態で出す（4 行に畳むと該当箇所が見えない）
                        ForEach(shown, id: \.id) { s in SessionCard(session: s, words: words).id("\(s.id)-\(words.isEmpty)") }
                    }
                }
                .textSelection(.enabled)
            }
            .padding(12)
        }
        .background(Theme.bg)
        // スクショ・確認用: -HGShotSearch <語> で検索した状態から開く
        .onAppear { if query.isEmpty, let q = UserDefaults.standard.string(forKey: "HGShotSearch") { query = q } }
    }
}

struct SessionCard: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    /// 検索中の語。空でなければ、見つかった箇所を蛍光ペンの色で塗る（本人要望 2026-10-13）
    var words: [String] = []
    @State private var expanded: Bool

    init(session: Session, words: [String] = []) {
        self.session = session
        self.words = words
        // 検索中は開いた状態で出す（4 行に畳むと該当箇所が見えない）
        _expanded = State(initialValue: !words.isEmpty)
    }

    private func hl(_ s: String) -> AttributedString { Highlight.text(s, words) }

    var body: some View {
        Card {
            Text("\(dateLabel)　指摘 \(session.issues.count) 件").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
            if session.folded == true {
                let lines = session.issues.map { $0.suggestion }.filter { !$0.isEmpty }
                Text(lines.isEmpty ? AttributedString(String(localized: "古い記録（指摘だけ残しています）")) : hl(lines.joined(separator: " / ")))
                    .font(.callout).foregroundStyle(Theme.muted)
            } else {
                let body = session.correctedText ?? session.transcript ?? ""
                Text(hl(body)).font(.callout).foregroundStyle(Theme.text).lineLimit(expanded ? nil : 4).textSelection(.enabled)
                // 当たったのが表示していない欄（添削前の書き起こし・ほめ言葉など）だけのときは、その欄も出して塗る
                if !words.isEmpty {
                    ForEach(hiddenHits, id: \.label) { h in
                        Text(h.label).font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
                        Text(hl(h.text)).font(.caption).foregroundStyle(Theme.text)
                    }
                }
                if body.count > 120 {
                    // 一覧全体に textSelection が付いているので、plain なボタンの文字は選択に食われて押せなかった（2026-10-09 本人指摘）
                    Button(expanded ? String(localized: "たたむ") : String(localized: "全文")) { expanded.toggle() }
                        .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
                }
                if !session.issues.isEmpty {
                    Text("直すべし").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
                    ForEach(Array(session.issues.enumerated()), id: \.offset) { _, it in
                        HStack(alignment: .top, spacing: 6) {
                            Text(hl("• \(it.original ?? "") → \(it.suggestion)" + ((it.reason?.isEmpty == false) ? " — \(it.reason!)" : "")))
                                .font(.caption).foregroundStyle(Theme.text)
                            Spacer(minLength: 0)
                            if session.folded != true { ExplainButton(sessionId: session.id, topic: ExplainTopic(issue: it), mini: true) }
                            AddIssueButton(issue: it)
                        }
                    }
                }
                if let more = session.moreFixes, !more.isEmpty {
                    // コーチが理由つきで挙げた残りの直し（2026-10-17 から）
                    Text("ほかに直したところ").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
                    ForEach(Array(more.enumerated()), id: \.offset) { _, f in
                        Text(hl("• \(f.original) → \(f.suggestion)" + (f.note.isEmpty ? "" : " — \(f.note)"))).font(.caption).foregroundStyle(Theme.text)
                    }
                }
                let silent = SilentFixes.find(transcript: session.transcript ?? "", corrected: session.correctedText ?? "", issues: session.issues + (session.moreFixes ?? []).map(\.asIssue), asks: session.asks ?? [])
                if !silent.isEmpty {
                    Text("ほかに、添削文で直っていたところ").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
                    ForEach(silent) { f in
                        Text(hl("• \(f.from) → \(f.to)")).font(.caption).foregroundStyle(Theme.text)
                    }
                }
                if let pron = session.pronunciation, !pron.isEmpty {
                    Text("発音で伝わらなかった箇所").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
                    ForEach(Array(pron.enumerated()), id: \.offset) { _, p in
                        Text(hl("• \(p.said) → \(p.heardAs)" + (p.note.isEmpty ? "" : " — \(p.note)"))).font(.caption).foregroundStyle(Theme.text)
                    }
                }
                if let asks = session.asks, !asks.isEmpty {
                    Text("日本語で言った分、英語ならこう").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
                    ForEach(Array(asks.enumerated()), id: \.offset) { _, a in
                        Text(hl("• \(a.said) → \(a.ways.joined(separator: " / "))" + (a.note.isEmpty || !Highlight.hits(a.note, words) ? "" : " — \(a.note)"))).font(.caption).foregroundStyle(Theme.text)
                    }
                }
                if let t = session.targets, !t.isEmpty {
                    Text("今日の表現の結果").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
                    ForEach(Array(t.enumerated()), id: \.offset) { _, x in
                        Text(hl("\(Mark.symbol(x.r)) \(x.phrase)" + ((!x.as.isEmpty && x.r != "hit") ? "（\(x.as)）" : ""))).font(.caption).foregroundStyle(Theme.text)
                    }
                }
            }
            CopyButton(text: Logic.buildSessionText(session, labels: Self.labels), label: String(localized: "📋 コピー（指摘つき）"))
        }
    }

    static let labels = Logic.Labels(corrected: String(localized: "修正版"), issues: String(localized: "直すべし"), good: String(localized: "わしが買ってやる点"), said: String(localized: "話した内容（音声から書き起こし）"),
                                     pron: String(localized: "発音で伝わらなかった箇所"), asks: String(localized: "日本語で言った分、英語ならこう"), more: String(localized: "ほかに直したところ"), types: ["phrasing": String(localized: "言い回し"), "vocabulary": String(localized: "語彙"), "grammar": String(localized: "文法")])

    /// 画面に出していない欄のうち、検索語が当たったもの
    private var hiddenHits: [(label: String, text: String)] {
        let shownBody = session.correctedText ?? session.transcript ?? ""
        var out: [(label: String, text: String)] = []
        if let t = session.transcript, t != shownBody, Highlight.hits(t, words) { out.append((String(localized: "話した内容（音声から書き起こし）"), t)) }
        if let t = session.asrTranscript, !t.isEmpty, Highlight.hits(t, words) { out.append((String(localized: "字幕"), t)) }
        if let t = session.good, !t.isEmpty, Highlight.hits(t, words) { out.append((String(localized: "わしが買ってやる点"), t)) }
        return out
    }

    private var dateLabel: String {
        guard let d = ISO8601DateFormatter.withMillis.date(from: session.id) ?? ISO8601DateFormatter().date(from: session.id) else { return session.id }
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "M/d HH:mm"
        return f.string(from: d)
    }
}

struct AddIssueButton: View {
    @EnvironmentObject var model: AppModel
    let issue: Issue
    @State private var added = false
    var body: some View {
        let exists = added || model.hasPhrase(issue.suggestion)
        Button(exists ? "✓" : "＋") { if model.addFromIssue(issue) { added = true } }
            .buttonStyle(.bordered).controlSize(.mini).tint(exists ? Theme.good : Theme.accent).disabled(exists)
            .help(exists ? String(localized: "表現集に入っています") : String(localized: "表現集へ入れる"))
    }
}

/// 繰り返し指摘の 1 行。回数と、最後に出た日を添える
struct RecurringRow: View {
    let item: Recurring
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("• \(item.text)").font(.callout).foregroundStyle(Theme.text)
            Text("\(item.count) 回・最後は \(Self.short(item.lastSeen))").font(.caption).foregroundStyle(Theme.faint).padding(.leading, 12)
        }
    }
    /// "2026-09-28" → "9/28"
    static func short(_ ymd: String) -> String {
        let p = ymd.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return ymd }
        return "\(m)/\(d)"
    }
}

extension Session {
    /// 検索の語（小文字）を全部含むか。話した内容・修正版・直し・ほめ言葉・英語ならこう・発音の欄を見る
    func matches(_ words: [String]) -> Bool {
        var parts: [String] = [transcript ?? "", asrTranscript ?? "", correctedText ?? "", good ?? ""]
        for i in issues { parts += [i.original ?? "", i.suggestion, i.reason ?? ""] }
        for f in moreFixes ?? [] { parts += [f.original, f.suggestion, f.note] }
        for a in asks ?? [] { parts += [a.said] + a.ways + [a.note] }
        for p in pronunciation ?? [] { parts += [p.said, p.heardAs, p.note] }
        for t in targets ?? [] { parts += [t.phrase, t.as] }
        let hay = parts.joined(separator: "\n")
        // 塗る側と同じ当て方にする（日本語キーボードだと空白が入れにくく「worldcup」になりがちなので、空白を挟んでも当てる）
        return words.allSatisfy { Highlight.hits(hay, [$0]) }
    }
}

/// 検索語を蛍光ペンの色で塗る。大文字小文字を区別せず、空白を挟んでも当てる（「worldcup」で「World Cup」も塗る）
enum Highlight {
    static func patterns(_ words: [String]) -> [NSRegularExpression] {
        words.compactMap { w in
            let chars = w.filter { !$0.isWhitespace }.map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !chars.isEmpty else { return nil }
            return try? NSRegularExpression(pattern: chars.joined(separator: "\\s*"), options: [.caseInsensitive])
        }
    }

    static func hits(_ s: String, _ words: [String]) -> Bool {
        let ns = NSRange(s.startIndex..., in: s)
        return patterns(words).contains { $0.firstMatch(in: s, range: ns) != nil }
    }

    static func text(_ s: String, _ words: [String]) -> AttributedString {
        var out = AttributedString(s)
        guard !words.isEmpty else { return out }
        let ns = NSRange(s.startIndex..., in: s)
        for re in patterns(words) {
            for m in re.matches(in: s, range: ns) {
                guard let r = Range(m.range, in: s),
                      let lo = AttributedString.Index(r.lowerBound, within: out),
                      let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
                out[lo..<hi].backgroundColor = Theme.mark
                out[lo..<hi].foregroundColor = Theme.markText
            }
        }
        return out
    }
}
