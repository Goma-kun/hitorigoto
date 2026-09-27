import SwiftUI

/// 表現タブ。覚えたい表現・単語の一覧と、追加・カードで復習
struct PhrasesView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter = "all"
    @State private var adding = false
    @State private var flashing = false
    @State private var confirmDelete: PhraseCard?

    private let filters: [(String, String)] = [("all", "すべて"), ("today", "今日"), ("active", "稽古中"), ("fresh", "未挑戦"), ("graduated", "卒業"), ("word", "単語")]

    var body: some View {
        let today = model.today
        let todayIds = Set(model.todayCards().map { $0.id })
        let st = PhraseLogic.stats(model.snapshot.phrases)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    stat("稽古中", st.active); stat("まだ試していない", st.fresh); stat("卒業", st.graduated)
                }
                HStack(spacing: 8) {
                    Button("＋ 追加") { adding = true }.buttonStyle(.borderedProminent).tint(Theme.accent)
                    Button("🃏 カードで復習") { flashing = true }.buttonStyle(.bordered).tint(Theme.accent)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(filters, id: \.0) { key, label in
                            Button(label) { filter = key }
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(filter == key ? Theme.accentBg : Color.clear, in: Capsule())
                                .overlay(Capsule().stroke(filter == key ? Theme.accent : Theme.line))
                                .foregroundStyle(filter == key ? Theme.accent : Theme.muted)
                                .buttonStyle(.plain)
                        }
                    }
                }
                let shown = shownCards(todayIds: todayIds)
                if model.snapshot.phrases.isEmpty {
                    Note(text: "まだ表現がありません。「＋ 追加」で入れるか、添削の「直すべし」から 1 タップで入れてください。")
                } else if shown.isEmpty {
                    Note(text: "この絞り込みに当てはまる表現はありません")
                }
                LazyVStack(spacing: 6) {
                    ForEach(shown) { p in
                        PhraseRow(card: p, today: today, isToday: todayIds.contains(p.id),
                                  onToggle: { model.toggleGraduate(p.id) }, onDelete: { confirmDelete = p })
                    }
                }
                Note(text: "独り言の中で形のまま使えたら ◎。◎ 1 回目のあとは 1 週間後、2 回目のあとは 3 週間後に戻り、3 回で卒業です。△ と ✗ は翌日、見送りは 2 日あけて戻ります。")
            }
            .padding(12)
        }
        .background(Theme.bg)
        .sheet(isPresented: $adding) { AddPhraseSheet().environmentObject(model) }
        .sheet(isPresented: $flashing) { FlashSheet().environmentObject(model) }
        .confirmationDialog("「\(confirmDelete?.phrase ?? "")」を削除しますか？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("削除", role: .destructive) { if let c = confirmDelete { model.deletePhrase(c.id) }; confirmDelete = nil }
            Button("やめる", role: .cancel) { confirmDelete = nil }
        }
    }

    private func stat(_ label: String, _ n: Int) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption.weight(.bold)).foregroundStyle(Theme.muted)
            Text(String(n)).font(.caption.weight(.bold)).foregroundStyle(Theme.text)
        }
    }

    private func shownCards(todayIds: Set<String>) -> [PhraseCard] {
        model.snapshot.phrases.filter { p in
            switch filter {
            case "today": return todayIds.contains(p.id)
            case "active": return p.status == "active" && !PhraseLogic.isNew(p)
            case "fresh": return p.status == "active" && PhraseLogic.isNew(p)
            case "graduated": return p.status == "graduated"
            case "word": return p.kind == "word"
            default: return true
            }
        }.sorted { a, b in
            let ga = a.status == "graduated", gb = b.status == "graduated"
            if ga != gb { return !ga }
            if ga { return a.added > b.added }
            let da = a.due ?? "", db = b.due ?? ""
            if da != db { return da < db }
            return a.added > b.added
        }
    }
}

struct PhraseRow: View {
    let card: PhraseCard
    let today: String
    let isToday: Bool
    var onToggle: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(card.phrase).font(.callout.weight(.bold)).foregroundStyle(Theme.text)
                if card.kind == "word" { Tag(text: "単語", fg: Theme.info, bg: Theme.info.opacity(0.15)) }
                Spacer(minLength: 0)
            }
            if !card.meaning.isEmpty || !card.note.isEmpty {
                Text(card.meaning.isEmpty ? "✗ \(card.note)" : card.meaning).font(.caption).foregroundStyle(Theme.muted)
            }
            HStack {
                let marks = PhraseLogic.marks(card)
                Text(marks.isEmpty ? "まだ試していない" : marks).font(.caption.weight(.bold)).foregroundStyle(Theme.muted).kerning(marks.isEmpty ? 0 : 2)
                Spacer()
                let d = dueLabel
                Text(d.text).font(.caption.weight(.bold)).foregroundStyle(d.color)
            }
            HStack(spacing: 6) {
                Spacer()
                Button(card.status == "graduated" ? "稽古に戻す" : "卒業にする", action: onToggle)
                    .buttonStyle(.bordered).controlSize(.small).tint(Theme.muted)
                Button("削除", action: onDelete).buttonStyle(.bordered).controlSize(.small).tint(Theme.muted)
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isToday ? Theme.accent.opacity(0.6) : Theme.line))
        .opacity(card.status == "graduated" ? 0.65 : 1)
    }

    private var dueLabel: (text: String, color: Color) {
        if card.status == "graduated" { return ("卒業", Theme.good) }
        guard let due = card.due else { return ("", Theme.faint) }
        let n = PhraseLogic.daysBetween(today, due)
        if n < 0 { return ("\(-n) 日遅れ", Theme.warn) }
        if n == 0 { return ("今日", Theme.accent) }
        if n == 1 { return ("明日", Theme.faint) }
        return ("\(n) 日後", Theme.faint)
    }
}

/// 追加（1 件ずつ／まとめて）
struct AddPhraseSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var meaning = ""
    @State private var kind = "phrase"
    @State private var bulk = ""
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("1 件ずつ") {
                    TextField("表現", text: $phrase, prompt: Text("例: for a split second"))
                        .autocorrectionDisabled()
                        .frame(maxWidth: .infinity)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("意味", text: $meaning, prompt: Text("例: ほんの一瞬"))
                        .frame(maxWidth: .infinity)
                    Picker("種類", selection: $kind) { Text("表現").tag("phrase"); Text("単語").tag("word") }
                    Button("入れる") {
                        if model.addPhrase(phrase, meaning: meaning, kind: kind) { status = "入れました"; phrase = ""; meaning = "" }
                        else { status = phrase.trimmingCharacters(in: .whitespaces).isEmpty ? "表現を入力してください" : "その表現はもう入っています" }
                    }
                    .disabled(phrase.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section("まとめて入れる") {
                    TextEditor(text: $bulk).frame(minHeight: 110).font(.callout)
                    Text("1 行に 1 つ。「表現 ｜ 意味」の形。区切りは ｜ か — かタブ。区切りが無い行は表現だけ入ります。同じ表現は増えません。")
                        .font(.caption).foregroundStyle(Theme.muted)
                    Button("まとめて入れる") {
                        let n = model.addBulk(bulk, kind: kind)
                        status = "\(n) 件入れました"; bulk = ""
                    }
                    .disabled(bulk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !status.isEmpty { Text(status).font(.callout).foregroundStyle(Theme.accent) }
            }
            .navigationTitle("表現を追加").compactNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }
}

/// カードで復習（意味を見て、英語で言えるか自分で確かめる）
struct FlashSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var cards: [PhraseCard] = []
    @State private var i = 0
    @State private var open = false
    @State private var ok = 0
    @State private var ng = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if cards.isEmpty {
                    Text("カードで復習できる表現（意味つき・稽古中）がありません").font(.callout).foregroundStyle(Theme.muted)
                } else if i >= cards.count {
                    face {
                        Text("おしまい。言えた \(ok)・言えなかった \(ng)").font(.headline).foregroundStyle(Theme.text)
                        Text("言えなかったものは明日の「今日の表現」に戻ります").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Button("一覧に戻る") { dismiss() }.buttonStyle(.borderedProminent).tint(Theme.accent)
                } else {
                    let c = cards[i]
                    Text("\(i + 1) / \(cards.count)").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
                    face {
                        Text(c.meaning).font(.title3.weight(.bold)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                        if open {
                            Text(c.phrase).font(.title2.weight(.heavy)).foregroundStyle(Theme.accent).multilineTextAlignment(.center)
                        } else {
                            Text("英語で言ってみてから、答えを見てください").font(.caption).foregroundStyle(Theme.faint)
                        }
                    }
                    if open {
                        HStack(spacing: 8) {
                            Button("言えた") { answer(true) }.buttonStyle(.borderedProminent).tint(Theme.good).frame(maxWidth: .infinity)
                            Button("言えなかった") { answer(false) }.buttonStyle(.borderedProminent).tint(Theme.bad).frame(maxWidth: .infinity)
                        }
                    } else {
                        Button("答えを見る") { open = true }.buttonStyle(.borderedProminent).tint(Theme.accent).frame(maxWidth: .infinity)
                    }
                }
                Spacer()
            }
            .padding(16)
            .background(Theme.bg)
            .navigationTitle("カードで復習").compactNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } } }
            .onAppear {
                cards = model.snapshot.phrases.filter { $0.status == "active" && !$0.meaning.isEmpty }
                    .sorted { ($0.due ?? "") < ($1.due ?? "") }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 360)
        #endif
    }

    private func face<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, minHeight: 140)
            .padding(20)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }

    private func answer(_ good: Bool) {
        model.recall(cards[i].id, ok: good)
        if good { ok += 1 } else { ng += 1 }
        i += 1; open = false
    }
}
