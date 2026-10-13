import SwiftUI

/// 直し 1 件の「💬 詳しく聞く」。押すと解説のシートが開く（2026-10-13 本人の要望:
/// 「もうちょっと具体的な事例とか詳しい解説とか文法的な説明をしてもらえるボタン」）
struct ExplainButton: View {
    @EnvironmentObject var model: AppModel
    let sessionId: String
    let topic: ExplainTopic
    var mini = false
    @State private var open = false

    var body: some View {
        let asked = !model.explainTurns(sessionId: sessionId, topic: topic).isEmpty
        Button(asked ? String(localized: "💬 聞いた解説") : String(localized: "💬 詳しく聞く")) { open = true }
            .buttonStyle(.bordered).controlSize(mini ? .mini : .small).tint(Theme.info)
            .sheet(isPresented: $open) { ExplainSheet(sessionId: sessionId, topic: topic).environmentObject(model) }
    }
}

struct ExplainSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let sessionId: String
    let topic: ExplainTopic

    @State private var loading = false
    @State private var error: String?
    @State private var question = ""
    @State private var added: Set<String> = []
    @FocusState private var focused: Bool

    private var turns: [ExplainTurn] { model.explainTurns(sessionId: sessionId, topic: topic) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        ForEach(Array(turns.enumerated()), id: \.offset) { i, t in
                            turnView(t).id("turn-\(i)")
                        }
                        if loading {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("トラさんが考え中…").font(.callout).foregroundStyle(Theme.muted)
                            }
                            .id("loading")
                        }
                        if let error {
                            Text(error).font(.callout).foregroundStyle(Theme.bad).textSelection(.enabled)
                        }
                        if !turns.isEmpty || error != nil { askBox }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: turns.count) { _, n in
                    withAnimation { proxy.scrollTo("turn-\(max(0, n - 1))", anchor: .top) }
                }
                .onChange(of: loading) { _, l in
                    if l { withAnimation { proxy.scrollTo("loading", anchor: .bottom) } }
                }
            }
            .background(Theme.bg)
            .navigationTitle("トラさんに詳しく聞く").compactNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 560, idealHeight: 680)
        #endif
        .task {
            await model.refreshExplainQuota()
            // 押した時点で「詳しく」と言っているので、最初の 1 回は待たせずに聞く
            if turns.isEmpty && !loading { await send(Explain.Preset.deeper.label, preset: .deeper) }
        }
    }

    // 何について聞いているか
    private var header: some View {
        Card {
            if topic.kind == "ask" {
                Text(topic.original).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                Text("→ \(topic.suggestion)").font(.callout.weight(.bold)).foregroundStyle(Theme.good).textSelection(.enabled)
            } else {
                (Text(topic.original).strikethrough().foregroundStyle(Theme.bad)
                 + Text("  →  ").foregroundStyle(Theme.faint)
                 + Text(topic.suggestion).bold().foregroundStyle(Theme.good))
                    .font(.callout).textSelection(.enabled)
            }
            if !topic.reason.isEmpty { Text(topic.reason).font(.caption).foregroundStyle(Theme.muted) }
        }
    }

    private func turnView(_ t: ExplainTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 聞いたこと（右寄せの吹き出し）
            HStack {
                Spacer(minLength: 40)
                Text(t.q).font(.callout).foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.accentBg, in: RoundedRectangle(cornerRadius: 10))
            }
            Card {
                if !t.a.isEmpty {
                    Text(rich(t.a)).font(.callout).foregroundStyle(Theme.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !t.examples.isEmpty {
                    Divider().overlay(Theme.line)
                    Text("例文").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
                    ForEach(Array(t.examples.enumerated()), id: \.offset) { _, e in exampleRow(e) }
                }
            }
        }
    }

    private func exampleRow(_ e: ExplainExample) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.text).font(.callout.weight(.semibold)).foregroundStyle(Theme.good).textSelection(.enabled)
                if !e.ja.isEmpty { Text(e.ja).font(.caption).foregroundStyle(Theme.muted) }
            }
            Spacer(minLength: 0)
            SpeakButton(text: e.text)
            let exists = added.contains(e.text) || model.hasPhrase(e.text)
            Button(exists ? String(localized: "✓ 入れた") : String(localized: "＋ 表現集へ")) {
                if model.addPhrase(e.text, meaning: e.ja, kind: "phrase", source: "issue") { added.insert(e.text) }
            }
            .buttonStyle(.bordered).controlSize(.mini).tint(exists ? Theme.good : Theme.accent).disabled(exists)
        }
    }

    // 続けて聞く: 用意した聞き方＋自由な質問
    private var askBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("続けて聞く").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
            FlowChips(items: Explain.Preset.allCases.filter { $0 != .deeper || turns.isEmpty }) { p in
                Button(p.label) { Task { await send(p.label, preset: p) } }
                    .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent).disabled(loading)
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField("自由に質問（日本語で OK）", text: $question, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { submitFree() }
                Button("聞く") { submitFree() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(loading || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let q = model.explainQuota {
                Note(text: String(localized: "今日の「詳しく聞く」の残り \(q.remaining) 回（添削の回数とは別）。一度聞いた解説は記録に残るので、開き直しても回数は減りません。"))
            } else {
                Note(text: String(localized: "一度聞いた解説は記録に残るので、履歴から開き直せます。AI の説明なので、気になるところは辞書でも確かめてください。"))
            }
        }
    }

    private func submitFree() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !loading else { return }
        question = ""
        focused = false
        Task { await send(q, preset: nil) }
    }

    private func send(_ q: String, preset: Explain.Preset?) async {
        loading = true
        error = nil
        error = await model.askExplain(sessionId: sessionId, topic: topic, question: q, preset: preset)
        loading = false
    }

    /// **太字** だけ効かせる（段落の空行はそのまま）
    private func rich(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// ボタンを横に並べ、入りきらなければ折り返す
struct FlowChips<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        FlowLayout(spacing: 6) { ForEach(items, id: \.self) { content($0) } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
