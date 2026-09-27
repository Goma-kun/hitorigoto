import SwiftUI

/// 履歴タブ。拡張機能の履歴パネルと同じ（繰り返し → セッションのカード）
struct HistoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                let recurring = Logic.topRecurring(model.snapshot.recurring)
                if !recurring.isEmpty {
                    Card(title: "また出やがった点") {
                        ForEach(recurring, id: \.text) { r in
                            Text("• \(r.text)（\(r.count) 回）").font(.callout).foregroundStyle(Theme.text)
                        }
                    }
                }
                if model.snapshot.sessions.isEmpty {
                    Note(text: "独り言の記録はまだありません")
                }
                LazyVStack(spacing: 8) {
                    ForEach(model.snapshot.sessions, id: \.id) { s in SessionCard(session: s) }
                }
            }
            .padding(12)
        }
        .background(Theme.bg)
    }
}

struct SessionCard: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    @State private var expanded = false

    var body: some View {
        Card {
            Text("\(dateLabel)　指摘 \(session.issues.count) 件").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
            if session.folded == true {
                let lines = session.issues.map { $0.suggestion }.filter { !$0.isEmpty }
                Text(lines.isEmpty ? "古い記録（指摘だけ残しています）" : lines.joined(separator: " / "))
                    .font(.callout).foregroundStyle(Theme.muted)
            } else {
                let body = session.correctedText ?? session.transcript ?? ""
                Text(body).font(.callout).foregroundStyle(Theme.text).lineLimit(expanded ? nil : 4).textSelection(.enabled)
                if body.count > 120 {
                    Button(expanded ? "たたむ" : "全文") { expanded.toggle() }.buttonStyle(.plain).font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                }
                if !session.issues.isEmpty {
                    Text("直すべし").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
                    ForEach(Array(session.issues.enumerated()), id: \.offset) { _, it in
                        HStack(alignment: .top, spacing: 6) {
                            Text("• \(it.original ?? "") → \(it.suggestion)" + ((it.reason?.isEmpty == false) ? " — \(it.reason!)" : ""))
                                .font(.caption).foregroundStyle(Theme.text)
                            Spacer(minLength: 0)
                            AddIssueButton(issue: it)
                        }
                    }
                }
                if let pron = session.pronunciation, !pron.isEmpty {
                    Text("発音で伝わらなかった箇所").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
                    ForEach(Array(pron.enumerated()), id: \.offset) { _, p in
                        Text("• \(p.said) → \(p.heardAs)" + (p.note.isEmpty ? "" : " — \(p.note)")).font(.caption).foregroundStyle(Theme.text)
                    }
                }
                if let t = session.targets, !t.isEmpty {
                    Text("今日の表現の結果").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
                    ForEach(Array(t.enumerated()), id: \.offset) { _, x in
                        Text("\(Mark.symbol(x.r)) \(x.phrase)" + ((!x.as.isEmpty && x.r != "hit") ? "（\(x.as)）" : "")).font(.caption).foregroundStyle(Theme.text)
                    }
                }
            }
            CopyButton(text: Logic.buildSessionText(session, labels: Self.labels), label: "📋 コピー（指摘つき）")
        }
    }

    static let labels = Logic.Labels(corrected: "修正版", issues: "直すべし", good: "わしが買ってやる点", said: "話した内容（音声から書き起こし）",
                                     pron: "発音で伝わらなかった箇所", types: ["phrasing": "言い回し", "vocabulary": "語彙", "grammar": "文法"])

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
            .help(exists ? "表現集に入っています" : "表現集へ入れる")
    }
}
