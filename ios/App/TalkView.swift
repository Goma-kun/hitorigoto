import SwiftUI

/// 話す画面に置く「三人で話す」の入口
struct TalkCard: View {
    @EnvironmentObject var model: AppModel
    @State private var open = false

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill").font(.title2).foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44).background(Theme.accentBg, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("三人で話す").font(.callout.weight(.bold)).foregroundStyle(Theme.text)
                    Text(String(localized: "\(model.partner.name) とトラさんと気楽におしゃべり。詰まったら日本語で OK"))
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 4)
                Button("話す") { open = true }.buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(model.phase == .recording || model.phase == .reviewing)
            }
        }
        .sheet(isPresented: $open) { TalkSheet(talk: TalkModel(app: model)).environmentObject(model) }
        .onAppear { if DevHooks.openTalk { open = true } }
    }
}

/// 三者会話のシート。はじめる前（話題）→ 会話（吹き出し＋マイク）→ まとめ
struct TalkSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject var talk: TalkModel
    @State private var confirmClose = false

    var body: some View {
        NavigationStack {
            Group {
                switch talk.phase {
                case .setup: setupBody
                default: conversationBody
                }
            }
            .background(Theme.bg)
            .navigationTitle("三人で話す").compactNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(talk.phase == .ended || talk.phase == .setup ? String(localized: "閉じる") : String(localized: "やめる")) {
                        if talk.active && talk.turns > 0 { confirmClose = true }
                        else { Task { await talk.abandon(); dismiss() } }
                    }
                }
            }
            .confirmationDialog("会話を終えますか？", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("終えて記録に残す") { Task { await talk.end() } }
                Button("記録せずに閉じる", role: .destructive) { Task { await talk.abandon(); dismiss() } }
                Button("続ける", role: .cancel) {}
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 600, idealHeight: 780)
        #endif
        .interactiveDismissDisabled(talk.active)
        .task {
            await model.refreshTalkQuota()
            #if DEBUG
            if let stage = UserDefaults.standard.string(forKey: "HGTalkDemo") { await talk.demo(stage) }
            #endif
        }
        .onDisappear { Task { await talk.abandon() } }
    }

    // MARK: - はじめる前

    private var setupBody: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let e = talk.error { Card { Text(e).font(.callout).foregroundStyle(Theme.bad) } }
                Card {
                    // 誰がいる場なのかを顔で見せる
                    HStack(alignment: .top, spacing: 0) {
                        member(name: talk.nativeName, role: String(localized: "ネイティブ"), symbol: "person.fill", color: Theme.info)
                        member(name: String(localized: "トラさん"), role: String(localized: "通訳役"), image: "Tange", color: Theme.warn)
                        member(name: String(localized: "あなた"), role: model.targetLanguage.name, symbol: "mic.fill", color: Theme.accent)
                    }
                    Text(String(localized: "\(talk.nativeName) が話を振ります。\(model.targetLanguage.name)で返してください。言葉が出てこなければ日本語で言えば、トラさんが\(model.targetLanguage.name)にしてくれます。"))
                        .font(.callout).foregroundStyle(Theme.text)
                    Text("直しは会話の邪魔をしないよう、終わってからまとめて出ます。")
                        .font(.caption).foregroundStyle(Theme.muted)
                    if let r = talk.review, !r.phrases.isEmpty {
                        // 翌日の Sam は前回の話を覚えている。昨日の言い方が自然に出る場を作る（復習を会話に溶かす）
                        Divider().overlay(Theme.line)
                        Text(String(localized: "\(talk.nativeName) は\(r.when)の話を覚えています。前回助けてもらった言い方（\(r.phrases.prefix(3).joined(separator: " / "))）が出せる話を振ってきます。"))
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                Card(title: String(localized: "話したいこと（空なら \(talk.nativeName) が決めます）")) {
                    TextField(String(localized: "例: 今日の仕事、週末のこと、うちの猫"), text: $talk.topic)
                        .textFieldStyle(.roundedBorder)
                }
                Card(title: String(localized: "相手")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Partners.list(model.targetLanguage)) { p in
                                VoiceChip(name: p.name, blurb: p.blurb, selected: model.partnerId == p.id || (model.partnerId.isEmpty && p.id == Partners.list(model.targetLanguage)[0].id),
                                          previewing: talk.previewing == p.id, color: Theme.info) {
                                    model.partnerId = p.id
                                } preview: { Task { await talk.preview(partner: p) } }
                            }
                        }
                    }
                }
                Card(title: String(localized: "\(talk.nativeName) の話し方")) {
                    HStack(spacing: 8) {
                        ForEach(Voice.Clarity.allCases, id: \.rawValue) { c in
                            Button {
                                model.clarity = c
                                Task { await talk.preview(partner: talk.partner) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.label).font(.callout.weight(.semibold))
                                    Text(c.blurb).font(.caption2).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(model.clarity == c ? Theme.accent.opacity(0.15) : Theme.card, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.clarity == c ? Theme.accent : Theme.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Card(title: String(localized: "トラさんの声")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Voice.toraVoices) { v in
                                VoiceChip(name: v.label, blurb: "", selected: model.toraVoice == v.id, previewing: talk.previewing == v.id, color: Theme.warn) {
                                    model.toraVoice = v.id
                                } preview: { Task { await talk.preview(tora: v.id) } }
                            }
                        }
                    }
                }
                Card {
                    Toggle(isOn: $model.naturalVoice) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自然な声で話す").font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                            Text("\(talk.nativeName) とトラさんが AI の声で話します。切ると端末の声（通信なし・機械的）になります。")
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    .tint(Theme.accent)
                }
                if let why = model.talkBlocker {
                    Card { Text(why).font(.callout).foregroundStyle(Theme.text) }
                } else if let q = model.talkQuota {
                    Note(text: String(localized: "今日はあと \(q.remaining) ターン（\(q.limit) ターンまで・添削の回数とは別）。1 回話すごとに 1 ターン使います。"))
                }
                Button {
                    Task { await talk.start() }
                } label: {
                    Label(String(localized: "はじめる"), systemImage: "bubble.left.and.bubble.right.fill").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                .disabled(model.talkBlocker != nil)
            }
            .padding(12)
        }
    }

    private func member(name: String, role: String, symbol: String? = nil, image: String? = nil, color: Color) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(color.opacity(0.15)).frame(width: 56, height: 56)
                if let image {
                    Image(image).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(Circle())
                } else if let symbol {
                    Image(systemName: symbol).font(.title2).foregroundStyle(color)
                }
            }
            .overlay(Circle().stroke(color.opacity(0.5), lineWidth: 2))
            Text(name).font(.caption.weight(.bold)).foregroundStyle(Theme.text)
            Text(role).font(.caption2).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 会話

    private var conversationBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(talk.lines.enumerated()), id: \.offset) { i, l in
                            bubble(l).id("line-\(i)")
                        }
                        if talk.busy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(busyText).font(.caption).foregroundStyle(Theme.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                            .id("busy")
                        }
                        if let e = talk.error { Card { Text(e).font(.callout).foregroundStyle(Theme.bad) } }
                        if talk.phase == .ended { summary.id("summary") }
                    }
                    .padding(12)
                    .textSelection(.enabled)
                }
                .onChange(of: talk.lines.count) { _, n in withAnimation { proxy.scrollTo("line-\(max(0, n - 1))", anchor: .bottom) } }
                .onChange(of: talk.busy) { _, b in if b { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } } }
                .onChange(of: talk.phase) { _, p in if p == .ended { withAnimation { proxy.scrollTo("summary", anchor: .top) } } }
            }
            if talk.phase != .ended { actionBar }
        }
    }

    private var busyText: String {
        switch talk.phase {
        case .opening: return String(localized: "\(talk.nativeName) が話を考え中…")
        case .closing: return String(localized: "二人が締めの一言を考え中…")
        case .thinking where talk.inConsult: return String(localized: "トラさんが考え中…")
        default: return String(localized: "二人が聞いています…")
        }
    }

    @ViewBuilder
    private func bubble(_ l: TalkLine) -> some View {
        switch l.who {
        case "native": NativeBubble(line: l, name: talk.nativeName, slowing: talk.slowing == l.text) { Task { await talk.sayClearly(l.text) } }
        case "tora": ToraBubble(line: l)
        default: MeBubble(line: l)
        }
    }

    // MARK: - 下のボタン

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.line)
            VStack(spacing: 6) {
                if talk.turns > 0 {
                    let t = talk.tally
                    Text(String(localized: "\(model.targetLanguage.name)だけで言えた \(t.alone)・助けてもらった \(t.helped)・直し \(talk.pendingFixes)（終わると見られます）")
                         + (t.repeated > 0 ? String(localized: "・言い直せた \(t.repeated)") : ""))
                        .font(.caption2).foregroundStyle(Theme.faint)
                }
                if talk.voiceLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("声を用意しています…").font(.caption2).foregroundStyle(Theme.faint)
                    }
                }
                if talk.phase == .consulting || talk.inConsult { consultPanel }
                if talk.phase == .recording { RecordingStrip(recorder: talk.recorder) }
                HStack(alignment: .center, spacing: 10) {
                    if talk.inConsult {
                        Button {
                            talk.cancelConsult()
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "chevron.backward").font(.title3)
                                Text("戻る").font(.caption2.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(Theme.muted)
                        .disabled(talk.phase != .consulting)
                        .help("相談をやめて会話に戻ります")
                    } else if talk.phase == .repeating {
                        // 言ってみるのを飛ばす。責めない（押さなくても会話は続く）
                        Button {
                            talk.skipRepeat()
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "forward.end").font(.title3)
                                Text("今はいい").font(.caption2.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(Theme.muted)
                        .help("言い直さずに会話を続けます")
                    } else {
                        Button {
                            talk.openConsult()
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "questionmark.bubble").font(.title3)
                                Text("トラさんに相談").font(.caption2.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(Theme.warn)
                        .disabled(talk.phase != .listening)
                        .help("言いたいことや事情をトラさんに伝えて、言い方を教えてもらいます（\(talk.nativeName) には聞こえません）")
                    }

                    Button {
                        Task {
                            switch talk.phase {
                            case .listening, .repeating, .consulting: await talk.startRecording()
                            case .recording: await talk.stopAndSend()
                            default: break
                            }
                        }
                    } label: {
                        ZStack {
                            Circle().fill(micColor).frame(width: 84, height: 84)
                                .shadow(color: micColor.opacity(talk.phase == .recording ? 0.5 : 0.3), radius: 10, y: 3)
                            VStack(spacing: 1) {
                                Image(systemName: talk.phase == .recording ? "stop.fill" : (talk.phase == .repeating ? "repeat" : (talk.phase == .consulting ? "ear" : "mic.fill"))).font(.system(size: 28, weight: .semibold))
                                Text(micLabel).font(.system(size: 13, weight: .bold))
                            }
                            .foregroundStyle(.white)
                        }
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(talk.busy)
                    .animation(.easeInOut(duration: 0.2), value: talk.phase)

                    if talk.inConsult {
                        Button {
                            Task { await talk.hint() }
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "sparkles").font(.title3)
                                Text("おまかせで 2 つ").font(.caption2.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(Theme.warn)
                        .disabled(talk.phase != .consulting)
                        .help("トラさんが、次に言えそうなことを 2 つ出します")
                    } else {
                        Button {
                            Task { await talk.end() }
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "flag.checkered").font(.title3)
                                Text("終わる").font(.caption2.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(Theme.muted)
                        .disabled(talk.busy)
                        .help("別れの一言と締めをもらって、記録に残します")
                    }
                }
                Text(micHint).font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 10)
        }
        .background(Theme.bg)
    }

    private var micColor: Color {
        switch talk.phase {
        case .recording: return Theme.rec
        case .listening: return Theme.accent
        case .repeating: return Theme.good
        case .consulting: return Theme.warn
        default: return Theme.faint
        }
    }

    private var micLabel: String {
        switch talk.phase {
        case .recording: return String(localized: "送る")
        case .repeating: return String(localized: "言ってみる")
        case .consulting: return String(localized: "声で相談")
        default: return String(localized: "話す")
        }
    }

    private var micHint: String {
        switch talk.phase {
        case .recording where talk.inConsult: return String(localized: "トラさんに話し終えたら、もう一度押してください（\(talk.nativeName) には聞こえません）")
        case .recording: return String(localized: "言い終えたら、もう一度押してください")
        case .consulting: return String(localized: "書くか、真ん中を押して日本語で話してください。トラさんが言い方を考えてくれます")
        case .listening: return String(localized: "押して、\(model.targetLanguage.name)で返す（日本語が混ざっても OK）")
        // もらった言い方を見て終わりにしない。その場で一回、口に出す（これがいちばん定着に効く）
        case .repeating: return String(localized: "トラさんの言い方を、そのまま口に出してみてください（\(talk.nativeName) は待っています）")
        default: return " "
        }
    }

    /// トラさんへの相談。言いたいこと・事情・聞きたいことを日本語で書く（声でも OK）
    private var consultPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image("Tange").resizable().scaledToFill().frame(width: 22, height: 22).clipShape(Circle())
                Text("トラさんにこっそり相談（\(talk.nativeName) には聞こえません）").font(.caption.weight(.bold)).foregroundStyle(Theme.text)
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField(String(localized: "例: 同僚は何人かいるけど、その人に聞くしかなくて困ってる、と言いたい"), text: $talk.wish, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(talk.phase != .consulting)
                    .onSubmit { Task { await talk.consult() } }
                Button {
                    Task { await talk.consult() }
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent).tint(Theme.warn)
                .disabled(talk.phase != .consulting || talk.wish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("トラさんに送ります")
            }
        }
        .padding(10)
        .background(Theme.warnBg.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - まとめ

    @ViewBuilder
    private var summary: some View {
        let t = talk.tally
        Card(title: talk.rerunOf.isEmpty ? String(localized: "今日の会話") : String(localized: "もう一回の結果")) {
            HStack(spacing: 14) {
                stat(String(localized: "往復"), talk.turns, Theme.accent)
                stat(String(localized: "\(model.targetLanguage.name)だけで"), t.alone, Theme.good)
                stat(String(localized: "助けてもらった"), t.helped, Theme.warn)
                if t.repeated > 0 { stat(String(localized: "言い直せた"), t.repeated, Theme.info) }
            }
            if let p = talk.previousTally {
                // さっきと比べて、助けてもらった数が減ったのが目で分かるように
                Text(String(localized: "さっきは \(model.targetLanguage.name)だけで \(p.alone)・助けてもらった \(p.helped) でした。"))
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            if let s = talk.saved, let targets = s.targets, !targets.isEmpty {
                Text(String(localized: "今日の表現が会話に出ました: ") + targets.map { "\(Mark.symbol($0.r)) \($0.phrase)" }.joined(separator: "　"))
                    .font(.caption).foregroundStyle(Theme.text)
            }
            Note(text: talk.saved == nil ? String(localized: "記録には残していません（何も話していないため）。") : String(localized: "記録に残しました。「履歴」からいつでも読み返せます。"))
        }
        if !talk.good.isEmpty {
            Card(title: String(localized: "わしが買ってやる点")) { Text(talk.good).font(.callout).foregroundStyle(Theme.good) }
        }
        if let s = talk.saved {
            Card(title: String(localized: "直すべし（会話中は黙っていた分）")) {
                if s.issues.isEmpty {
                    Note(text: String(localized: "今日は言うことがねえ。指摘なし"))
                } else {
                    ForEach(Array(s.issues.enumerated()), id: \.offset) { i, it in
                        if i > 0 { Divider().overlay(Theme.line) }
                        IssueRow(issue: it, sessionId: s.id)
                    }
                }
            }
            if let asks = s.asks, !asks.isEmpty {
                Card(title: String(localized: "日本語で言った分、英語ならこう")) {
                    ForEach(Array(asks.enumerated()), id: \.offset) { i, a in
                        if i > 0 { Divider().overlay(Theme.line) }
                        AskRow(ask: a, sessionId: s.id)
                    }
                    Note(text: String(localized: "トラさんに助けてもらった言い方です。次は自分の口から出るよう、表現集に入れておくと明日また出ます。"))
                }
            }
        }
        if talk.turns > 0 {
            // 同じ話をもう一回。同じ会話を繰り返すと流暢さが伸びる（研究の裏づけがいちばん強い型）
            Button {
                Task { await talk.rerun() }
            } label: {
                Label(String(localized: "同じ話をもう一回（今度は助けなしで）"), systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(Theme.accent).controlSize(.large)
            Note(text: String(localized: "さっきと同じ質問を \(talk.nativeName) がもう一度振ります。2〜3 往復で十分です。同じ話を繰り返すと、言葉が出てくる速さが上がります。"))
        }
        Button("閉じる") { dismiss() }
            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
            .frame(maxWidth: .infinity)
    }

    private func stat(_ label: String, _ n: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

/// ネイティブ役の吹き出し（左）。訳は押したときだけ
struct NativeBubble: View {
    let line: TalkLine
    let name: String
    /// 「ゆっくりもう一回」で鳴らしている最中か・押したときの動き
    var slowing = false
    var slowly: () -> Void = {}
    @State private var showSub = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().fill(Theme.info.opacity(0.15)).frame(width: 34, height: 34)
                Image(systemName: "person.fill").font(.callout).foregroundStyle(Theme.info)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.caption2.weight(.bold)).foregroundStyle(Theme.faint)
                Text(line.text).font(.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                if showSub, !line.sub.isEmpty {
                    Text(line.sub).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    SpeakButton(text: line.text)
                    // ゆっくりもう一回: 会話はふつうの速さのまま、この一言だけ「はっきり」の声で聞き直す
                    Button(action: slowly) {
                        Label(String(localized: "ゆっくりもう一回"), systemImage: slowing ? "tortoise.fill" : "tortoise")
                            .font(.caption).labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered).controlSize(.mini).tint(slowing ? Theme.accent : Theme.muted)
                    .help("この一言を、ゆっくりはっきりした声でもう一回")
                    if !line.sub.isEmpty {
                        Button(showSub ? String(localized: "訳を隠す") : String(localized: "訳")) { showSub.toggle() }
                            .buttonStyle(.bordered).controlSize(.mini).tint(Theme.muted)
                    }
                }
            }
            .padding(10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
            Spacer(minLength: 24)
        }
    }
}

/// トラさんの吹き出し（左・顔つき）。「英語ならこう」は言い方ごとに読み上げと表現集へ
struct ToraBubble: View {
    @EnvironmentObject var model: AppModel
    let line: TalkLine
    @State private var added: Set<String> = []

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image("Tange").resizable().scaledToFill().frame(width: 34, height: 34).clipShape(Circle())
                .overlay(Circle().stroke(Theme.warn.opacity(0.5), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 6) {
                Text("トラさん").font(.caption2.weight(.bold)).foregroundStyle(Theme.faint)
                if !line.text.isEmpty {
                    Text(line.text).font(.callout).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    // 話す言語で返したときは、その訳を小さく添える
                    if !line.note.isEmpty {
                        Text(line.note).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(Array(line.asks.enumerated()), id: \.offset) { i, a in
                    if i > 0 || !line.text.isEmpty { Divider().overlay(Theme.line) }
                    VStack(alignment: .leading, spacing: 4) {
                        if !a.said.isEmpty { Text(a.said).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted) }
                        ForEach(Array(a.ways.enumerated()), id: \.offset) { j, w in
                            HStack(alignment: .top, spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(w).font(.callout.weight(j == 0 ? .bold : .regular)).foregroundStyle(Theme.good)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if j < a.ipa.count, !a.ipa[j].isEmpty {
                                        Text(a.ipa[j]).font(.caption2.monospaced()).foregroundStyle(Theme.faint)
                                    }
                                }
                                Spacer(minLength: 0)
                                SpeakButton(text: w)
                                let exists = added.contains(w) || model.hasPhrase(w)
                                Button(exists ? "✓" : "＋") { if model.addFromAsk(a, way: w) { added.insert(w) } }
                                    .buttonStyle(.bordered).controlSize(.mini).tint(exists ? Theme.good : Theme.accent).disabled(exists)
                                    .help(exists ? String(localized: "表現集に入っています") : String(localized: "表現集へ入れる"))
                            }
                        }
                        if !a.note.isEmpty { Text(a.note).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            .padding(10)
            .background(Theme.warnBg.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.warn.opacity(0.35), lineWidth: 1))
            Spacer(minLength: 24)
        }
    }
}

/// 学習者の吹き出し（右）。自然な形があれば、小さく下に添える（叱らない）
struct MeBubble: View {
    let line: TalkLine

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                if line.tag == "repeat_ok" {
                    Tag(text: String(localized: "✓ 言い直せた"), fg: Theme.good, bg: Theme.goodBg)
                } else if line.tag == "repeat_ng" {
                    Tag(text: String(localized: "言い直し（もう一回でも OK）"), fg: Theme.warn, bg: Theme.warnBg)
                } else if line.tag == "consult" {
                    Tag(text: String(localized: "トラさんにこっそり"), fg: Theme.warn, bg: Theme.warnBg)
                } else if line.tag == "stuck" {
                    Tag(text: String(localized: "言い淀み → トラさんが補った"), fg: Theme.warn, bg: Theme.warnBg)
                } else if line.tag == "cut_in" {
                    Tag(text: String(localized: "話の途中で話し始めた（被り）"), fg: Theme.info, bg: Theme.infoBg)
                }
                Text(line.text).font(.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if !line.sub.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        Text("→").font(.caption).foregroundStyle(Theme.faint)
                        Text(line.sub).font(.caption).foregroundStyle(Theme.good).fixedSize(horizontal: false, vertical: true)
                        SpeakButton(text: line.sub)
                    }
                }
            }
            .padding(10)
            .background(Theme.accentBg, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// 声を選ぶチップ（名前＋一言＋試聴）
struct VoiceChip: View {
    let name: String
    let blurb: String
    let selected: Bool
    let previewing: Bool
    let color: Color
    let select: () -> Void
    let preview: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.callout.weight(selected ? .bold : .semibold)).foregroundStyle(selected ? color : Theme.text)
                    if !blurb.isEmpty { Text(blurb).font(.caption2).foregroundStyle(Theme.muted) }
                }
            }
            .buttonStyle(.plain)
            Button(action: preview) {
                Image(systemName: previewing ? "speaker.wave.2.fill" : "play.circle").font(.title3).foregroundStyle(previewing ? color : Theme.muted)
            }
            .buttonStyle(.plain)
            .help("試聴します")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? color.opacity(0.12) : Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? color.opacity(0.6) : Theme.line, lineWidth: selected ? 1.5 : 1))
    }
}

/// 録音中の小さな帯（時間・音量・字幕）
struct RecordingStrip: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(Theme.rec).frame(width: 8, height: 8)
                Text(String(format: "%d:%02d", recorder.seconds / 60, recorder.seconds % 60))
                    .font(.caption.monospacedDigit().weight(.bold)).foregroundStyle(Theme.text)
                LevelBar(level: recorder.level)
            }
            if recorder.micSilent {
                Text(String(localized: "マイクから音が入っていません（\(recorder.inputName)）")).font(.caption2.weight(.bold)).foregroundStyle(Theme.warn)
            }
            let live = recorder.transcript + recorder.interim
            if !live.isEmpty {
                Text(live).font(.caption).foregroundStyle(Theme.muted).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
