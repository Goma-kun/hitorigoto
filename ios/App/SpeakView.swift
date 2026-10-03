import SwiftUI

/// 話すタブ。拡張機能の「話す」パネルと同じ並び：
/// 話す前＝今日の表現＋また出やがった点 → 録音中＝字幕 → 添削中 → 結果
struct SpeakView: View {
    @EnvironmentObject var model: AppModel
    var goPhrases: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    if let e = model.errorMessage {
                        Card { Text(e).font(.callout).foregroundStyle(Theme.bad) }
                    }
                    switch model.phase {
                    case .idle: idleBody
                    case .recording: RecordingBody(recorder: model.recorder)
                    case .reviewing: reviewingBody
                    case .result: resultBody
                    }
                }
                .padding(12)
                // 画面の文字はどこでも選んでコピーできるようにする（指摘・理由・褒め言葉も。2026-09-28 本人要望）
                .textSelection(.enabled)
            }
            .background(Theme.bg)
            actionBar
        }
        .background(Theme.bg)
        .navigationTitle("独り言")
    }

    // MARK: - 話す前

    @State private var confirmDiscard = false

    private var idleBody: some View {
        Group {
            if let p = model.pending {
                Card(title: "送っていない録音があります") {
                    Text(p.label).font(.callout.weight(.bold)).foregroundStyle(Theme.text)
                    if !p.transcript.isEmpty {
                        Text(p.transcript).font(.caption).foregroundStyle(Theme.muted).lineLimit(3)
                    }
                    HStack(spacing: 8) {
                        Button("もう一度送る") { Task { await model.review() } }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                        Button("捨てる") { confirmDiscard = true }
                            .buttonStyle(.bordered).tint(Theme.muted)
                    }
                    Note(text: "添削が終わるまで録音は手元に残ります。送れたら自動で消えます。")
                }
                .confirmationDialog("この録音を捨てますか？ 添削されていない話した内容が消えます。", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("捨てる", role: .destructive) { model.discardPending() }
                    Button("やめる", role: .cancel) {}
                }
            }
            if !model.hasKey {
                Card {
                    Text("添削には Google Gemini の API キーが必要です。「設定」で登録してください（自分のキーで、自分と Google の間の通信だけです）。")
                        .font(.callout).foregroundStyle(Theme.text)
                }
            }
            // 押し方は下の丸ボタンとその一行で分かるので、ここは「止めたあと何が起きるか」だけにする
            Note(text: "停止すると、録音した音声を Gemini に送って、書き起こしと添削をします。")
            TodayCard(goPhrases: goPhrases)
            let recurring = Logic.topRecurring(model.snapshot.recurring, limit: 3)
            if !recurring.isEmpty {
                Card(title: "また出やがった点（今日はここに気をつける）") {
                    ForEach(recurring, id: \.text) { r in RecurringRow(item: r) }
                }
            }
        }
    }

    // MARK: - 録音中


    private var reviewingBody: some View {
        Card {
            HStack(spacing: 10) {
                ProgressView()
                Text("🧠 音声を聞き直して添削中…（少し時間がかかります）").font(.callout).foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: - 結果

    @ViewBuilder
    private var resultBody: some View {
        if let fb = model.latest {
            if !fb.good.isEmpty {
                Card(title: "わしが買ってやる点") { Text(fb.good).font(.callout).foregroundStyle(Theme.good) }
            }
            // 結果を丸ごと持ち出す（チャットに貼って台本にする型）。履歴の「コピー（指摘つき）」と同じ本文
            CopyButton(text: Logic.buildSessionText(model.latestSession ?? Session(id: ""), labels: SessionCard.labels),
                       label: "📋 結果をまとめてコピー（指摘つき）")
            if !model.latestJudged.isEmpty { TodayResultCard(judged: model.latestJudged) }
            Card(title: "直すべし") {
                if fb.issues.isEmpty {
                    Note(text: "今日は言うことがねえ。指摘なし")
                } else {
                    ForEach(Array(fb.issues.enumerated()), id: \.offset) { i, it in
                        if i > 0 { Divider().overlay(Theme.line) }
                        IssueRow(issue: it)
                    }
                }
            }
            if !fb.recurring.isEmpty {
                Card(title: "また出やがった点") {
                    ForEach(fb.recurring, id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(Theme.text) }
                }
            }
            if !fb.pronunciation.isEmpty {
                Card(title: "発音で伝わらなかった箇所") {
                    ForEach(Array(fb.pronunciation.enumerated()), id: \.offset) { i, p in
                        if i > 0 { Divider().overlay(Theme.line) }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(p.said).font(.callout.weight(.bold)).foregroundStyle(Theme.good)
                                Text("→").foregroundStyle(Theme.faint)
                                Text(p.heardAs).font(.callout).foregroundStyle(Theme.warn)
                            }
                            if !p.note.isEmpty { Text(p.note).font(.caption).foregroundStyle(Theme.muted) }
                        }
                    }
                    Note(text: "左が言おうとした語、右がそう聞こえた語です。ここを直すと伝わります。")
                }
            }
            if !fb.recognitionDoubt.isEmpty {
                Card(title: "端末の聞き取りが外した箇所") {
                    ForEach(fb.recognitionDoubt, id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(Theme.muted) }
                    Note(text: "端末の音声認識が外した箇所です。音声ではちゃんと言えていました。誤りとしては数えていません。")
                }
            }
            if !fb.correctedText.isEmpty {
                Card(title: "あしたのために（音読用）") {
                    Text(fb.correctedText).font(.body).foregroundStyle(Theme.text).textSelection(.enabled)
                    CopyButton(text: fb.correctedText)
                }
            }
            if !fb.transcript.isEmpty {
                Card(title: "実際に話した内容（音声から書き起こし）") {
                    Text(fb.transcript).font(.callout).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
            }
            Note(text: "※ 音声を Gemini に送って書き起こし・添削しました。音声は添削のためにその場で送るだけで、保存されません。")
        }
    }

    // MARK: - 下のボタン

    /// 画面の下の「開始／停止」。**録音アプリの定石どおり、大きな丸ひとつにしてある**
    /// （本人の要望・2026-10-03「ここで独り言を始めるのだと、ぱっと見て分かるようにしたい」）。
    /// 横いっぱいのバーだと下のタブと一体に見えて、押す場所が沈んでいた。
    /// 丸の周りは空けておく。**ここだけが押す場所**だと目で分かるのが大事なので、隣に何も置かない
    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.line)
            VStack(spacing: 7) {
                Button {
                    Task {
                        switch model.phase {
                        case .recording: await model.stopAndReview()
                        case .reviewing: break
                        default:
                            if model.pending != nil { model.errorMessage = "送っていない録音があります。先に「もう一度送る」か「捨てる」を選んでください。" }
                            else {
                                Speaker.shared.stop()   // 読み上げ中なら止める。録音に混ざらないように
                                await model.startRecording()
                            }
                        }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(micColor)
                            .frame(width: 96, height: 96)
                            // 録音中は赤がうっすら広がる。押したあと「始まっている」が目でも分かる
                            .shadow(color: micColor.opacity(model.phase == .recording ? 0.5 : 0.3), radius: 12, y: 3)
                        VStack(spacing: 1) {
                            Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 31, weight: .semibold))
                            Text(micLabel).font(.system(size: 14, weight: .bold))
                        }
                        .foregroundStyle(.white)
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.phase == .reviewing)
                .animation(.easeInOut(duration: 0.2), value: model.phase)

                Text(micHint).font(.caption).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14).padding(.bottom, 10)
        }
        .background(Theme.bg)
    }

    private var micColor: Color {
        switch model.phase {
        case .recording: return Theme.rec
        case .reviewing: return Theme.faint
        default: return Theme.accent
        }
    }

    private var micLabel: String {
        switch model.phase {
        case .recording: return "停止"
        case .reviewing: return "添削中"
        default: return "開始"
        }
    }

    private var micHint: String {
        switch model.phase {
        case .recording: return "話し終えたら、もう一度押してください"
        case .reviewing: return "音声を Gemini に送っています"
        default: return "押すと録音が始まります。英語で独り言をどうぞ"
        }
    }
}

/// 音の大きさ。声が入っていることを見せるためだけ
struct LevelBar: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(Theme.accent).frame(width: max(4, geo.size.width * CGFloat(level)))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.1), value: level)
    }
}

/// 話す前の「今日の表現」
struct TodayCard: View {
    @EnvironmentObject var model: AppModel
    var goPhrases: () -> Void

    var body: some View {
        let cards = model.todayCards()
        Card(title: "今日の表現") {
            if cards.isEmpty {
                Note(text: model.snapshot.phrases.isEmpty
                     ? "覚えたい表現を「表現」タブに入れると、毎日ここに出ます。添削の「直すべし」からも 1 タップで入れられます。"
                     : "今日出す表現はありません。表現を足すか、明日また来てください。")
                Button("📚 表現を入れる", action: goPhrases).buttonStyle(.bordered)
            } else {
                ForEach(Array(cards.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { Divider().overlay(Theme.line) }
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.phrase).font(.callout.weight(.bold)).foregroundStyle(Theme.text)
                            if !c.meaning.isEmpty || !c.note.isEmpty {
                                Text(c.meaning.isEmpty ? "✗ \(c.note)" : c.meaning).font(.caption).foregroundStyle(Theme.muted)
                            }
                            let marks = PhraseLogic.marks(c)
                            if !marks.isEmpty { Text(marks).font(.caption).foregroundStyle(Theme.muted).kerning(2) }
                        }
                        Spacer(minLength: 4)
                        // 真似して口に出すための読み上げ（端末の声。通信もお金もかからない）
                        SpeakButton(text: c.phrase)
                        todayTag(c)
                        Button("見送り") { model.skipToday(c.id) }
                            .buttonStyle(.bordered).controlSize(.small).tint(Theme.muted)
                            .help("今日の話に合わないので外す（回数には数えません。2 日あけて戻ります）")
                    }
                }
                Note(text: "話す前に目を通しておき、無理のない範囲で独り言に混ぜてください（\(cards.count) 個）。停止すると、出たかどうかを判定します。")
            }
        }
    }

    private func todayTag(_ c: PhraseCard) -> some View {
        let last = PhraseLogic.lastSpeechResult(c)
        if PhraseLogic.isNew(c) { return Tag(text: "新", fg: Theme.good, bg: Theme.goodBg) }
        if last == "miss" || last == "partial" { return Tag(text: "再挑戦", fg: Theme.warn, bg: Theme.warnBg) }
        return Tag(text: "再登場")
    }
}

/// 添削のあとの「今日の表現の結果」。記号をタップして直せる
struct TodayResultCard: View {
    @EnvironmentObject var model: AppModel
    let judged: [Judged]

    var body: some View {
        Card(title: "今日の表現の結果") {
            ForEach(Array(judged.enumerated()), id: \.element.id) { i, j in
                if let card = model.snapshot.phrases.first(where: { $0.id == j.id }) {
                    if i > 0 { Divider().overlay(Theme.line) }
                    let r = model.todayResult(j.id)?.r ?? j.result
                    HStack(alignment: .top, spacing: 10) {
                        Button { model.cycleTodayResult(j.id) } label: {
                            Text(Mark.symbol(r)).font(.title3.weight(.bold)).foregroundStyle(Mark.color(r))
                                .frame(width: 34, height: 34)
                                .background(Mark.bg(r), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Mark.color(r).opacity(0.5)))
                        }
                        .buttonStyle(.plain)
                        .help("タップで ◎ → △ → ✗ → − と切り替え")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.phrase).font(.callout.weight(.bold)).foregroundStyle(Theme.text)
                            let asSaid = model.todayResult(j.id)?.as ?? j.asSaid
                            if !asSaid.isEmpty, PhraseLogic.phraseKey(asSaid) != PhraseLogic.phraseKey(card.phrase) {
                                (Text("口から出た形: ").foregroundStyle(Theme.muted) + Text(asSaid).foregroundStyle(Theme.text).bold())
                                    .font(.caption)
                            }
                            let note = model.todayResult(j.id)?.note ?? j.note
                            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(Theme.muted) }
                        }
                    }
                }
            }
            Note(text: "◎ 形のまま出た ／ △ 崩れて出た ／ ✗ 出なかった ／ − 見送り。判定が違っていたら記号をタップして直してください。")
        }
    }
}

/// 指摘 1 件（拡張の .en-issue）
struct IssueRow: View {
    @EnvironmentObject var model: AppModel
    let issue: Issue
    @State private var added = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Tag(text: typeLabel, fg: typeColor, bg: typeColor.opacity(0.15))
            HStack(alignment: .top, spacing: 4) {
                (Text(issue.original ?? "").strikethrough().foregroundStyle(Theme.bad)
                 + Text("  →  ").foregroundStyle(Theme.faint)
                 + Text(issue.suggestion).bold().foregroundStyle(Theme.good))
                    .font(.callout)
                Spacer(minLength: 0)
                // 読み上げるのは**直されたあとの形**だけ。間違えた形を耳に入れても仕方がない
                SpeakButton(text: issue.suggestion)
            }
            if let r = issue.reason, !r.isEmpty { Text(r).font(.caption).foregroundStyle(Theme.muted) }
            let exists = added || model.hasPhrase(issue.suggestion)
            Button(exists ? "✓ 入れた" : "＋ 表現集へ") {
                if model.addFromIssue(issue) { added = true }
            }
            .buttonStyle(.bordered).controlSize(.small).tint(exists ? Theme.good : Theme.accent).disabled(exists)
        }
    }

    private var typeLabel: String { ["phrasing": "言い回し", "vocabulary": "語彙", "grammar": "文法"][issue.type] ?? "言い回し" }
    private var typeColor: Color {
        switch issue.type { case "vocabulary": return Theme.info; case "grammar": return Theme.warn; default: return Theme.muted }
    }
}

struct CopyButton: View {
    let text: String
    var label = "📋 コピー"
    @State private var done = false
    var body: some View {
        Button(done ? "✓ コピーしました" : label) {
            Platform.copy(text); done = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { done = false }
        }
        .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// 録音中の表示。Recorder の変化で描き直すために、観測する側を分けておく
struct RecordingBody: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        Group {
            HStack(spacing: 10) {
                Circle().fill(Theme.rec).frame(width: 10, height: 10)
                Text(String(format: "%d:%02d", recorder.seconds / 60, recorder.seconds % 60))
                    .font(.title3.monospacedDigit().weight(.bold)).foregroundStyle(Theme.text)
                LevelBar(level: recorder.level)
            }
            let live = recorder.transcript + recorder.interim
            if live.isEmpty {
                Note(text: recorder.captionsAvailable ? "聞き取り中…（字幕は参考です。添削は音声そのものから行います）" : "録音中。字幕は出ませんが、音声はそのまま添削に使います")
            } else {
                Text(live).font(.body).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}
