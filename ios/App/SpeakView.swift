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
                    // 録音を始めたら「話す → AI が聞く → 直しが届く」が進み具合の表示になる（押すものではないと伝わる形）
                    if model.phase != .idle { FlowStrip(stage: stage) }
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

    private var stage: Int {
        switch model.phase {
        case .recording: return 0
        case .reviewing: return 1
        default: return 2
        }
    }

    // MARK: - 話す前

    @State private var confirmDiscard = false

    private var idleBody: some View {
        Group {
            if let p = model.pending {
                Card(title: String(localized: "送っていない録音があります")) {
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
                    Note(text: String(localized: "添削が終わるまで録音は手元に残ります。送れたら自動で消えます。"))
                }
                .confirmationDialog("この録音を捨てますか？ 添削されていない話した内容が消えます。", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("捨てる", role: .destructive) { model.discardPending() }
                    Button("やめる", role: .cancel) {}
                }
            }
            if let why = model.reviewBlocker {
                Card { Text(why).font(.callout).foregroundStyle(Theme.text) }
            }
            // 文章で説明する代わりに、挨拶と 3 つの絵で流れを見せる（2026-10-04 本人要望「ぱっと見て直感的に」）
            Welcome()
            // 三人で話す（ネイティブ役＋トラさん＋自分）。独り言と並ぶもう一つの入口（2026-10-28）
            TalkCard()
            // 英検 1 級 2 次の練習（2026-10-30）。英検は日本の試験なので、英語を話す・説明が日本語の設定のときだけ
            if model.targetLanguage.locale.hasPrefix("en"), TargetLanguage.explanation == .ja { ExamCard() }
            QuizCard()
            CandidatesCard()
            TodayCard(goPhrases: goPhrases)
            let recurring = Logic.topRecurring(model.snapshot.recurring, limit: 3)
            if !recurring.isEmpty {
                Card(title: String(localized: "また出やがった点（今日はここに気をつける）")) {
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
                Card(title: String(localized: "わしが買ってやる点")) { Text(fb.good).font(.callout).foregroundStyle(Theme.good) }
            }
            // 結果を丸ごと持ち出す（チャットに貼って台本にする型）。履歴の「コピー（指摘つき）」と同じ本文
            CopyButton(text: Logic.buildSessionText(model.latestSession ?? Session(id: ""), labels: SessionCard.labels),
                       label: String(localized: "📋 結果をまとめてコピー（指摘つき）"))
            if !model.latestJudged.isEmpty { TodayResultCard(judged: model.latestJudged) }
            Card(title: String(localized: "直すべし")) {
                if fb.issues.isEmpty {
                    Note(text: String(localized: "今日は言うことがねえ。指摘なし"))
                } else {
                    ForEach(Array(fb.issues.enumerated()), id: \.offset) { i, it in
                        if i > 0 { Divider().overlay(Theme.line) }
                        IssueRow(issue: it, sessionId: model.latestSession?.id)
                    }
                }
            }
            if !fb.moreFixes.isEmpty {
                // コーチが「直すべし」に入れきれなかった直し。理由つき（2026-10-17 から）
                Card(title: String(localized: "ほかに直したところ")) {
                    ForEach(Array(fb.moreFixes.enumerated()), id: \.offset) { i, f in
                        if i > 0 { Divider().overlay(Theme.line) }
                        VStack(alignment: .leading, spacing: 3) {
                            (Text(f.original).strikethrough().foregroundStyle(Theme.bad) + Text("  →  ").foregroundStyle(Theme.faint) + Text(f.suggestion).bold().foregroundStyle(Theme.good))
                                .font(.callout)
                            if !f.note.isEmpty { Text(f.note).font(.caption).foregroundStyle(Theme.muted) }
                        }
                    }
                    Note(text: String(localized: "「直すべし」は大事なものから 5 件までです。修正版で直した残りを、理由つきで並べています。"))
                }
            }
            // コーチが挙げきれなかった直しが残っていれば、機械で突き合わせて拾う（理由は付かない）
            let silent = SilentFixes.find(transcript: fb.transcript, corrected: fb.correctedText, issues: fb.issues + fb.moreFixes.map(\.asIssue), asks: fb.asks)
            if !silent.isEmpty {
                Card(title: String(localized: "ほかに、添削文で直っていたところ")) {
                    ForEach(silent) { f in
                        (Text(f.from).strikethrough().foregroundStyle(Theme.bad) + Text("  →  ").foregroundStyle(Theme.faint) + Text(f.to).bold().foregroundStyle(Theme.good))
                            .font(.caption)
                    }
                    Note(text: String(localized: "コーチの指摘は大事なものだけに絞られています。添削文と話した内容を比べて拾った、残りの直しです。"))
                }
            }
            if !fb.recurring.isEmpty {
                Card(title: String(localized: "また出やがった点")) {
                    ForEach(fb.recurring, id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(Theme.text) }
                }
            }
            if !fb.asks.isEmpty {
                // 日本語で言った分（英語が出てこなかったところ）→ 英語ならこう。
                // 英語が話せる友だちに「これ、英語でどう言う？」と聞いた答え。叱る枠ではない
                Card(title: String(localized: "日本語で言った分、英語ならこう")) {
                    ForEach(Array(fb.asks.enumerated()), id: \.offset) { i, a in
                        if i > 0 { Divider().overlay(Theme.line) }
                        AskRow(ask: a, sessionId: model.latestSession?.id)
                    }
                    Note(text: String(localized: "英語が出てこなくて日本語で言ったところです。友だちに聞いたつもりで、いちばん上の言い方から口に出してみてください。"))
                }
            }
            if !fb.pronunciation.isEmpty {
                Card(title: String(localized: "発音で伝わらなかった箇所")) {
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
                    Note(text: String(localized: "左が言おうとした語、右がそう聞こえた語です。ここを直すと伝わります。"))
                }
            }
            if !fb.recognitionDoubt.isEmpty {
                Card(title: String(localized: "端末の聞き取りが外した箇所")) {
                    ForEach(fb.recognitionDoubt, id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(Theme.muted) }
                    Note(text: String(localized: "端末の音声認識が外した箇所です。音声ではちゃんと言えていました。誤りとしては数えていません。"))
                }
            }
            if !fb.correctedText.isEmpty {
                Card(title: String(localized: "あしたのために（音読用）")) {
                    Text(fb.correctedText).font(.body).foregroundStyle(Theme.text).textSelection(.enabled)
                    CopyButton(text: fb.correctedText)
                }
            }
            if !fb.transcript.isEmpty {
                Card(title: String(localized: "実際に話した内容（音声から書き起こし）")) {
                    Text(fb.transcript).font(.callout).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
            }
            Note(text: model.latestSession?.engine == "apple"
                 ? String(localized: "※ この端末の AI が、録音中の字幕の文字を添削しました。音声は端末の外に出ていません。")
                 : String(localized: "※ 音声を Gemini に送って書き起こし・添削しました。音声は添削のためにその場で送るだけで、保存されません。"))
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
                            if model.pending != nil { model.errorMessage = String(localized: "送っていない録音があります。先に「もう一度送る」か「捨てる」を選んでください。") }
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
                if Platform.canChooseInput, model.phase != .recording, model.phase != .reviewing {
                    // 話す前に、どのマイクで録るかを見せる。無音のまま話してしまうのを先に防ぐ。
                    // イヤホンは後からつながるので、数秒おきに見直す
                    TimelineView(.periodic(from: .now, by: 2)) { _ in micLine }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14).padding(.bottom, 10)
        }
        .background(Theme.bg)
    }

    @ViewBuilder
    private var micLine: some View {
        if model.micUID.isEmpty {
            Label(Platform.inputDeviceName, systemImage: "mic").font(.caption2).foregroundStyle(Theme.faint)
        } else if let name = Platform.inputName(uid: model.micUID) {
            Label(name, systemImage: "mic").font(.caption2).foregroundStyle(Theme.faint)
        } else if model.micUID == Platform.micAuto {
            if let held = Platform.bluetoothOutputsWithoutMic().first {
                // つながってはいるが、通話用（マイク）を iPhone など別の機器が掴んでいる
                Label("\(held) はつながっていますが、マイクが Mac に出ていません（iPhone などが通話用に掴んでいるとこうなります）。今は \(Platform.inputDeviceName) で録ります", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.bold)).foregroundStyle(Theme.warn).multilineTextAlignment(.center)
            } else {
                // イヤホンがつながっていないだけなので、警告にはしない
                Label("イヤホンなし（\(Platform.inputDeviceName) で録ります）", systemImage: "mic").font(.caption2).foregroundStyle(Theme.faint)
            }
        } else {
            Label("選んだマイクがつながっていません（\(Platform.inputDeviceName) で録ります）", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.bold)).foregroundStyle(Theme.warn)
        }
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
        case .recording: return String(localized: "停止")
        case .reviewing: return String(localized: "添削中")
        default: return String(localized: "開始")
        }
    }

    private var micHint: String {
        switch model.phase {
        case .recording: return String(localized: "話し終えたら、もう一度押してください")
        case .reviewing: return String(localized: "音声を Gemini に送っています")
        default: return String(localized: "押して、\(model.targetLanguage.name)で話すだけ")
        }
    }
}

/// 話す前のいちばん上。挨拶と「話す → AI が聞く → 直しが届く」の絵。
/// 何が起きるアプリなのかを、読まなくても分かるようにする
struct Welcome: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            // 誰が添削してくれるのかを顔で見せる（手を挙げた丹下。2026-10-04 本人承認）
            HStack(spacing: 14) {
                VStack(spacing: 4) {
                    Image("Tange").resizable().scaledToFill()
                        .frame(width: 76, height: 76).clipShape(Circle())
                        .overlay(Circle().stroke(Theme.accent.opacity(0.6), lineWidth: 2))
                    // コーチの名前は寅吉（トラキチ）、呼ぶときは「トラさん」（2026-10-10 本人決定。作品のキャラ名は使わない）
                    Text("寅吉（トラさん）").font(.caption2.weight(.bold)).foregroundStyle(Theme.muted)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting).font(.title2.weight(.bold)).fontDesign(.rounded).foregroundStyle(Theme.text)
                    Text(sub).font(.subheadline).foregroundStyle(Theme.muted)
                }
            }
            // 流れの説明は、使い始めの数回だけ控えめな 1 行で出す。
            // 丸い背景つきの大きな絵はボタンに見えて押されてしまう（2026-10-17 本人指摘）ので、押せそうな形にしない
            if model.snapshot.sessions.count < FlowStrip.introSessions { FlowStrip(stage: nil) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private var greeting: String {
        var hour = Calendar.current.component(.hour, from: Date())
        #if DEBUG
        if UserDefaults.standard.object(forKey: "HGHour") != nil { hour = UserDefaults.standard.integer(forKey: "HGHour") }   // スクショ用
        #endif
        switch hour {
        case 5..<11: return String(localized: "おはようございます")
        case 11..<18: return String(localized: "こんにちは")
        default: return String(localized: "こんばんは")
        }
    }

    private var sub: String {
        let n = model.snapshot.sessions.count
        return n == 0 ? String(localized: "\(model.targetLanguage.name)でひとりごと、はじめましょう") : String(localized: "これまで \(n) 回。今日も聞かせてくれ")
    }

}

/// 「話す → AI が聞く → 直しが届く」。押すものではなく、流れと今いる場所を見せる帯。
/// - stage が nil：使い始めの説明。小さな絵と文字を 1 行に、控えめな色で並べる
/// - stage が 0〜2：録音中・添削中・結果。今の段だけ色を付け、済んだ段にはチェック、添削中は回る印
struct FlowStrip: View {
    let stage: Int?
    /// 説明として出すのは、記録がこの回数に届くまで
    static let introSessions = 3

    private struct Step { let icon: String; let label: String; let color: Color }
    private var steps: [Step] {
        [Step(icon: "mic.fill", label: String(localized: "話す"), color: Theme.accent),
         Step(icon: "sparkles", label: String(localized: "AI が聞く"), color: Theme.warn),
         Step(icon: "checkmark.bubble.fill", label: String(localized: "直しが届く"), color: Theme.good)]
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, st in
                if i > 0 {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(Theme.faint)
                }
                item(i, st)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, stage == nil ? 2 : 6)
        .animation(.easeInOut(duration: 0.25), value: stage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private func item(_ i: Int, _ st: Step) -> some View {
        let current = stage == i
        let done = (stage ?? -1) > i || (stage == 2 && i == 2)
        HStack(spacing: 4) {
            if current && i == 1 {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: done && i < 2 ? "checkmark.circle.fill" : st.icon)
                    .font(.caption.weight(.semibold))
                    .symbolEffect(.pulse, isActive: current && i == 0)
            }
            Text(st.label).font(.caption.weight(current ? .bold : .regular))
        }
        .foregroundStyle(color(i, st, current: current, done: done))
    }

    private func color(_ i: Int, _ st: Step, current: Bool, done: Bool) -> Color {
        guard let stage else { return Theme.muted }        // 説明のときは全部控えめ
        if current { return st.color }
        if done || i < stage { return Theme.good.opacity(0.8) }
        return Theme.faint
    }

    private var accessibilityText: String {
        guard let stage else { return String(localized: "流れ: 話す、AI が聞く、直しが届く") }
        return [String(localized: "いま録音しています"), String(localized: "AI が聞いて添削しています"), String(localized: "直しが届きました")][stage]
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

/// 話す画面の「覚えてますか？」の入口。独り言をしない日でもクイズだけ解ける（2026-10-15 本人要望）
struct QuizCard: View {
    @EnvironmentObject var model: AppModel
    @State private var quizzing = false

    var body: some View {
        let n = Quiz.dueToday(model.snapshot.phrases, today: model.today).count
        // シートはカードの外に付ける（最後の 1 問に答えて 0 問になった瞬間に、終わりの画面ごと閉じないように）
        Group {
          if n > 0 {
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "brain.head.profile").font(.title2).foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44).background(Theme.accentBg, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("覚えてますか？").font(.callout.weight(.bold)).foregroundStyle(Theme.text)
                        Text(String(localized: "今日の問題 \(n) 問（言えたら間をあけて、言えなかったら明日また出ます）"))
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 4)
                    Button("解く") { quizzing = true }.buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            }
          }
        }
        .sheet(isPresented: $quizzing) { FlashSheet().environmentObject(model) }
    }
}

/// 話す前の「前に言えなかった表現」。過去の直しから数個出し、選んだものだけ今日の表現に足す（2026-10-15 本人要望）
struct CandidatesCard: View {
    @EnvironmentObject var model: AppModel
    @State private var chosen: Set<String> = []

    var body: some View {
        let items = model.candidateItems()
        if !items.isEmpty {
            Card(title: String(localized: "前に言えなかった表現（今日使ってみる？）")) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                    if i > 0 { Divider().overlay(Theme.line) }
                    row(it)
                }
                HStack(spacing: 8) {
                    Button(chosen.isEmpty ? String(localized: "選んで今日使う") : String(localized: "選んだ \(chosen.count) 個を今日使う")) {
                        model.useCandidates(items.filter { chosen.contains($0.key) })
                        chosen = []
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(chosen.isEmpty)
                    Button("今日は使わない") {
                        model.snoozeCandidates(items.filter { !chosen.contains($0.key) })
                        chosen = []
                    }
                    .buttonStyle(.bordered).tint(Theme.muted)
                    .help("選んでいない表現をしばらく寝かせます（3 日 → 7 日 → 21 日。責めません）")
                }
                Note(text: String(localized: "選んだ表現は表現集に入り、今日の表現に並びます。話し終えると出たかどうかを判定し、言えるまで間をあけて戻ってきます。"))
            }
        }
    }

    private func row(_ it: Candidates.Item) -> some View {
        let on = chosen.contains(it.key)
        return HStack(alignment: .center, spacing: 8) {
            Button {
                if on { chosen.remove(it.key) } else { chosen.insert(it.key) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(on ? Theme.accent : Theme.faint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(it.phrase).font(.callout.weight(.bold)).foregroundStyle(Theme.text)
                        Text(it.origin == "ask" ? String(localized: "日本語で「\(it.said)」と言っていた") : "✗ \(it.said)")
                            .font(.caption).foregroundStyle(Theme.muted)
                        HStack(spacing: 6) {
                            Text(String(localized: "\(Self.dayLabel(it.date)) の独り言")).font(.caption2).foregroundStyle(Theme.faint)
                            if it.count >= 2 { Tag(text: String(localized: "\(it.count) 回直された"), fg: Theme.warn, bg: Theme.warnBg) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            SpeakButton(text: it.phrase)
            Button {
                chosen.remove(it.key)
                model.dismissCandidate(it)
            } label: {
                Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("この表現はもう出さない")
        }
    }

    /// "2026-10-08" → "10/8"
    static func dayLabel(_ ymd: String) -> String {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? "\(p[1])/\(p[2])" : ymd
    }
}

/// 話す前の「今日の表現」
struct TodayCard: View {
    @EnvironmentObject var model: AppModel
    var goPhrases: () -> Void
    /// 「覚えてますか？」で答えを開いた表現
    @State private var revealed: Set<String> = []

    var body: some View {
        let cards = model.todayCards()
        Card(title: String(localized: "今日の表現")) {
            if cards.isEmpty {
                // 空のときは絵と一言だけ。細かい入れ方は「表現」タブ側で分かる
                HStack(spacing: 12) {
                    Image(systemName: "books.vertical.fill").font(.title2).foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44).background(Theme.accentBg, in: Circle())
                    Text(model.snapshot.phrases.isEmpty ? String(localized: "覚えたい表現を入れると、毎日ここに出ます")
                                                        : String(localized: "今日出す表現はありません"))
                        .font(.callout).foregroundStyle(Theme.text)
                    Spacer(minLength: 4)
                    Button("入れる", action: goPhrases).buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            } else {
                ForEach(Array(cards.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { Divider().overlay(Theme.line) }
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            let cue = c.meaning.isEmpty ? (c.note.isEmpty ? "" : "✗ \(c.note)") : c.meaning
                            // 2 回目以降は答えを隠して「覚えてますか？」から入る（思い出す手間が定着になる）
                            if !PhraseLogic.isNew(c), !cue.isEmpty, !revealed.contains(c.id) {
                                Text(String(localized: "覚えてますか？")).font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                                Text(cue).font(.callout.weight(.bold)).foregroundStyle(Theme.text)
                                Button("答えを見る") { revealed.insert(c.id) }
                                    .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
                            } else {
                                Text(c.phrase).font(.callout.weight(.bold)).foregroundStyle(Theme.text)
                                if !cue.isEmpty { Text(cue).font(.caption).foregroundStyle(Theme.muted) }
                            }
                            let marks = PhraseLogic.marks(c)
                            if !marks.isEmpty { Text(marks).font(.caption).foregroundStyle(Theme.muted).kerning(2) }
                        }
                        Spacer(minLength: 4)
                        // 真似して口に出すための読み上げ（端末の声。通信もお金もかからない）
                        // 答えを隠している間は読み上げも出さない（音で答えが分かってしまうため）
                        if PhraseLogic.isNew(c) || revealed.contains(c.id) || (c.meaning.isEmpty && c.note.isEmpty) {
                            SpeakButton(text: c.phrase)
                        }
                        todayTag(c)
                        Button("見送り") { model.skipToday(c.id) }
                            .buttonStyle(.bordered).controlSize(.small).tint(Theme.muted)
                            .help("今日の話に合わないので外す（回数には数えません。2 日あけて戻ります）")
                    }
                }
                Note(text: String(localized: "話す前に目を通しておき、無理のない範囲で独り言に混ぜてください（\(cards.count) 個）。停止すると、出たかどうかを判定します。"))
            }
        }
    }

    private func todayTag(_ c: PhraseCard) -> some View {
        let last = PhraseLogic.lastSpeechResult(c)
        if PhraseLogic.isNew(c) { return Tag(text: String(localized: "新"), fg: Theme.good, bg: Theme.goodBg) }
        if last == "miss" || last == "partial" { return Tag(text: String(localized: "再挑戦"), fg: Theme.warn, bg: Theme.warnBg) }
        return Tag(text: String(localized: "再登場"))
    }
}

/// 添削のあとの「今日の表現の結果」。記号をタップして直せる
struct TodayResultCard: View {
    @EnvironmentObject var model: AppModel
    let judged: [Judged]

    var body: some View {
        Card(title: String(localized: "今日の表現の結果")) {
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
            Note(text: String(localized: "◎ 形のまま出た ／ △ 崩れて出た ／ ✗ 出なかった ／ − 見送り。判定が違っていたら記号をタップして直してください。"))
        }
    }
}

/// 「日本語で言った分 → 英語ならこう」1 件。言い方ごとに読み上げと「表現集へ」
struct AskRow: View {
    @EnvironmentObject var model: AppModel
    let ask: Ask
    var sessionId: String? = nil
    @State private var added: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ask.said).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
            ForEach(Array(ask.ways.enumerated()), id: \.offset) { i, w in
                HStack(alignment: .top, spacing: 6) {
                    Text(i == 0 ? "→" : "　").foregroundStyle(Theme.faint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(w).font(.callout.weight(i == 0 ? .bold : .regular)).foregroundStyle(Theme.good).textSelection(.enabled)
                        // 発音記号（IPA）。カタカナでは表せない音を確かめるためのもの
                        if i < ask.ipa.count, !ask.ipa[i].isEmpty {
                            Text(ask.ipa[i]).font(.caption.monospaced()).foregroundStyle(Theme.muted).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                    SpeakButton(text: w)
                    let exists = added.contains(w) || model.hasPhrase(w)
                    Button(exists ? String(localized: "✓ 入れた") : String(localized: "＋ 表現集へ")) {
                        if model.addFromAsk(ask, way: w) { added.insert(w) }
                    }
                    .buttonStyle(.bordered).controlSize(.mini).tint(exists ? Theme.good : Theme.accent).disabled(exists)
                }
            }
            if !ask.note.isEmpty { Text(ask.note).font(.caption).foregroundStyle(Theme.muted) }
            if let sessionId { ExplainButton(sessionId: sessionId, topic: ExplainTopic(ask: ask)) }
        }
    }
}

/// 指摘 1 件（拡張の .en-issue）
struct IssueRow: View {
    @EnvironmentObject var model: AppModel
    let issue: Issue
    var sessionId: String? = nil
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
            HStack(spacing: 8) {
                let exists = added || model.hasPhrase(issue.suggestion)
                Button(exists ? String(localized: "✓ 入れた") : String(localized: "＋ 表現集へ")) {
                    if model.addFromIssue(issue) { added = true }
                }
                .buttonStyle(.bordered).controlSize(.small).tint(exists ? Theme.good : Theme.accent).disabled(exists)
                // もっと知りたいときに、この直しについてだけ追加で聞く（添削とは別の回数）
                if let sessionId { ExplainButton(sessionId: sessionId, topic: ExplainTopic(issue: issue)) }
            }
        }
    }

    private var typeLabel: String { ["phrasing": String(localized: "言い回し"), "vocabulary": String(localized: "語彙"), "grammar": String(localized: "文法")][issue.type] ?? String(localized: "言い回し") }
    private var typeColor: Color {
        switch issue.type { case "vocabulary": return Theme.info; case "grammar": return Theme.warn; default: return Theme.muted }
    }
}

struct CopyButton: View {
    let text: String
    var label = String(localized: "📋 コピー")
    @State private var done = false
    var body: some View {
        Button(done ? String(localized: "✓ コピーしました") : label) {
            Platform.copy(text); done = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { done = false }
        }
        .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// マイクから音が来ていないときの知らせ。無音のまま最後まで話してしまうのを防ぐ
struct MicSilentWarning: View {
    let inputName: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("マイクから音が入っていません").font(.headline).foregroundStyle(Theme.warn)
            Text(inputName.isEmpty ? String(localized: "このままだと無音の録音になります。マイクを確かめてください。")
                                   : String(localized: "今のマイクは「\(inputName)」です。このままだと無音の録音になります。"))
                .font(.subheadline).foregroundStyle(Theme.text)
            if Platform.canChooseInput {
                Text("いったん止めて、「設定」タブの「録音に使うマイク」で選び直してから録り直してください。").font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warnBg, in: RoundedRectangle(cornerRadius: 10))
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
            if recorder.micSilent {
                MicSilentWarning(inputName: recorder.inputName + (recorder.inputDetail.isEmpty ? "" : "・\(recorder.inputDetail)"))
            } else if !recorder.inputName.isEmpty {
                Note(text: String(localized: "マイク: \(recorder.inputName)") + (recorder.inputDetail.isEmpty ? "" : "（\(recorder.inputDetail)）"))
            }
            if !recorder.engineNote.isEmpty {
                Text(recorder.engineNote).font(.caption).foregroundStyle(Theme.warn)
            }
            let live = recorder.transcript + recorder.interim
            if live.isEmpty {
                Note(text: recorder.captionsAvailable ? String(localized: "聞き取り中…（字幕は参考です。添削は音声そのものから行います）") : String(localized: "録音中。字幕は出ませんが、音声はそのまま添削に使います"))
            } else {
                Text(live).font(.body).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}
