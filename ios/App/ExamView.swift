import SwiftUI

/// 話す画面の「試験の練習」の入口。英語を話す設定（説明は日本語）のときだけ出す（英検は日本の試験なので）
struct ExamCard: View {
    @EnvironmentObject var model: AppModel
    @State private var open = false

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "graduationcap.fill").font(.title2).foregroundStyle(Theme.info)
                    .frame(width: 44, height: 44).background(Theme.info.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("英検 1 級 2 次の練習").font(.callout.weight(.bold)).foregroundStyle(Theme.text)
                    Text("1 分で考えて 2 分のスピーチ。面接官の質問に答えて、4 つの観点で採点")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 4)
                Button("練習") { open = true }.buttonStyle(.borderedProminent).tint(Theme.info)
                    .disabled(model.phase == .recording || model.phase == .reviewing)
            }
        }
        .sheet(isPresented: $open) { ExamSheet(exam: ExamModel(app: model)).environmentObject(model) }
        .onAppear { if DevHooks.openExam { open = true } }
    }
}

/// 試験の練習の進み具合。シートを開いている間だけ生きる（終わったら AppModel の記録に入る）
@MainActor
final class ExamModel: ObservableObject {

    enum Phase: Equatable {
        case choose      // トピックを選ぶ
        case prep        // 1 分で考える
        case speaking    // 2 分のスピーチを録っている
        case sending     // スピーチを聞いてもらっている
        case listening   // 面接官の質問に答える番（マイクを押すのを待っている）
        case answering   // 答えを録っている
        case thinking    // 答えを聞いてもらっている
        case scoring     // 採点を待っている
        case stalled     // スピーチか採点が送れなかった（もう一度送るを待つ）
        case ended
    }

    @Published private(set) var phase: Phase = .choose
    @Published private(set) var topics: [String] = []
    @Published private(set) var topic = ""
    /// 準備・スピーチの残り秒
    @Published private(set) var remaining = 0
    @Published private(set) var lines: [TalkLine] = []
    @Published private(set) var result: ExamResult?
    @Published private(set) var saved: Session?
    @Published var error: String?
    /// 送れなかった音声（もう一度送るボタンで使う）
    @Published private(set) var retryable = false

    private var pron: ExamScore?
    private var notes: [String] = []
    private var questions = 0
    private var interactionStart = Date()
    private var startedAt = Date()
    private var timer: Task<Void, Never>?
    private var failed: (request: Exam.Request, audio: Data?)?

    private unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
        topics = ExamTopics.draw(avoiding: Self.recent)
    }

    var recorder: Recorder { app.recorder }
    var busy: Bool { phase == .sending || phase == .thinking || phase == .scoring }
    var active: Bool { phase != .choose && phase != .ended }
    var lastQuestion: String { lines.last(where: { $0.who == "native" })?.text ?? "" }
    var questionCount: Int { questions }
    var speechSeconds = 0

    // MARK: - トピック

    /// 最近選んだトピック（同じものが続かないように）
    private static var recent: [String] {
        get { UserDefaults.standard.stringArray(forKey: "examRecentTopics") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(20)), forKey: "examRecentTopics") }
    }

    func redraw() { topics = ExamTopics.draw(avoiding: Self.recent + topics) }

    func choose(_ t: String) {
        topic = t
        Self.recent = Self.recent.filter { $0 != t } + [t]
        startPrep()
    }

    /// 同じトピックでもう一回（同じ話を繰り返すと流暢さが伸びる）
    func again() { startPrep() }

    func newTopics() {
        stopTimer()
        redraw()
        phase = .choose
    }

    // MARK: - 準備とスピーチ

    private func startPrep() {
        stopTimer()
        lines = []; result = nil; saved = nil; error = nil; retryable = false
        pron = nil; notes = []; questions = 0; speechSeconds = 0
        startedAt = Date()
        phase = .prep
        countdown(Exam.prepSeconds) { [weak self] in await self?.startSpeech() }
    }

    /// 準備を終えて話し始める（1 分たつと自動で始まる。本番と同じ）
    func startSpeech() async {
        guard phase == .prep else { return }
        stopTimer()
        Speaker.shared.stop()
        guard await record() else { phase = .prep; return }
        phase = .speaking
        countdown(Exam.speechSeconds) { [weak self] in await self?.finishSpeech() }
    }

    /// 話し終えた（2 分たつと自動で止まる。本番も 2 分で切られる）
    func finishSpeech() async {
        guard phase == .speaking else { return }
        stopTimer()
        guard let r = await stopRecording() else { return }
        speechSeconds = r.seconds
        guard r.seconds >= 10 else {
            error = String(localized: "短すぎました（\(r.seconds) 秒）。もう一度、準備から始めます")
            startPrep()
            return
        }
        phase = .sending
        await send(.speech(topic: topic), audio: r.audio)
    }

    // MARK: - 質疑応答

    func startAnswer() async {
        guard phase == .listening else { return }
        Speaker.shared.stop()
        guard await record() else { return }
        phase = .answering
    }

    func finishAnswer() async {
        guard phase == .answering else { return }
        guard let r = await stopRecording() else { return }
        guard r.seconds >= 1 else {
            phase = .listening
            error = String(localized: "短すぎました。もう少し話してから止めてください")
            return
        }
        let last = questions >= Exam.maxQuestions || Date().timeIntervalSince(interactionStart) >= Double(Exam.interactionSeconds)
        phase = .thinking
        await send(.answer(topic: topic, last: last), audio: r.audio)
    }

    /// 質疑応答を切り上げて採点へ
    func finish() async {
        guard phase == .listening || phase == .answering else { return }
        if phase == .answering { _ = await recorder.stop() }
        Speaker.shared.stop()
        await score()
    }

    /// 質問をもう一度聞く（本番でも "Could you repeat the question?" は言ってよい）
    func repeatQuestion() {
        guard phase == .listening, !lastQuestion.isEmpty else { return }
        say(lastQuestion)
    }

    /// 送れなかった分をもう一度送る
    func retry() async {
        guard let f = failed else { return }
        retryable = false
        phase = { if case .score = f.request { return .scoring }; if case .speech = f.request { return .sending }; return .thinking }()
        await send(f.request, audio: f.audio)
    }

    private func send(_ r: Exam.Request, audio: Data?) async {
        error = nil
        failed = nil
        guard let raw = await request(r, audio: audio) else { markFailed(r, audio); return }
        switch r {
        case .speech:
            guard let t = Exam.parseTurn(raw), !t.heard.isEmpty else { fail(r, audio, String(localized: "スピーチが聞き取れませんでした。マイクを確かめて、準備からやり直してください")); return }
            lines.append(TalkLine(who: "me", text: t.heard, tag: "exam_speech"))
            pron = t.pronunciation
            if !t.note.isEmpty { notes.append("スピーチ: \(t.note)") }
            interactionStart = Date()
            ask(t.question)
        case .answer(_, let last):
            guard let t = Exam.parseTurn(raw) else { fail(r, audio, String(localized: "答えを読み取れませんでした")); return }
            if !t.heard.isEmpty { lines.append(TalkLine(who: "me", text: t.heard, tag: "exam_answer")) }
            if !t.note.isEmpty { notes.append("答え \(questions): \(t.note)") }
            if last || t.question.isEmpty { await score() } else { ask(t.question) }
        case .score:
            guard let res = Exam.parseResult(raw, pronunciation: pron) else { fail(r, audio, String(localized: "採点を読み取れませんでした")); return }
            result = res
            // 直しはスピーチの行に付けておく（記録の「直すべし」に集まる）
            if let i = lines.firstIndex(where: { $0.tag == "exam_speech" }) { lines[i].fixes = res.fixes }
            var record = [TalkLine(who: "native", text: "Topic: \(topic)", tag: "exam_topic")] + lines
            if !res.model.isEmpty { record.append(TalkLine(who: "tora", text: res.model, asks: res.phrases, tag: "exam_model")) }
            saved = app.finishTalk(lines: record, good: Exam.recordGood(res), startedAt: startedAt)
            phase = .ended
        }
    }

    private func fail(_ r: Exam.Request, _ audio: Data?, _ message: String) {
        error = message
        markFailed(r, audio)
    }

    /// 送れなかった・読めなかった。答えは録り直せるように答える番に戻し、スピーチと採点は「もう一度送る」を待つ
    private func markFailed(_ r: Exam.Request, _ audio: Data?) {
        failed = (r, audio)
        retryable = true
        if case .answer = r { phase = .listening } else { phase = .stalled }
    }

    private func ask(_ q: String) {
        guard !q.isEmpty else { Task { await score() }; return }
        questions += 1
        lines.append(TalkLine(who: "native", text: q))
        say(q)
        phase = .listening
    }

    private func score() async {
        phase = .scoring
        await send(.score(topic: topic), audio: nil)
    }

    // MARK: - 録音・時計・声

    private func record() async -> Bool {
        error = nil
        #if DEBUG
        if DevHooks.fakeTalk { return true }
        #endif
        do {
            try await recorder.start(captions: app.captionsOn, language: app.language, micUID: app.micUID)
            return true
        } catch Recorder.Failure.micDenied {
            error = String(localized: "マイクの使用が許可されていません。設定で「独り言」のマイクをオンにしてください。")
        } catch {
            self.error = String(localized: "録音を始められませんでした: \(error.localizedDescription)")
        }
        return false
    }

    private func stopRecording() async -> (audio: Data, seconds: Int)? {
        #if DEBUG
        if DevHooks.fakeTalk { return (Data([0]), phase == .speaking ? Exam.speechSeconds - remaining : 20) }
        #endif
        guard let r = await recorder.stop(), !r.audio.isEmpty else {
            error = String(localized: "録音が取れませんでした。もう一度試してください")
            phase = phase == .speaking ? .prep : .listening
            return nil
        }
        return (r.audio, r.seconds)
    }

    private func countdown(_ seconds: Int, then done: @escaping () async -> Void) {
        remaining = seconds
        timer = Task { [weak self] in
            while let self, self.remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self.remaining -= 1
            }
            if Task.isCancelled { return }
            await done()
        }
    }

    private func stopTimer() { timer?.cancel(); timer = nil }

    /// 面接官の声は落ち着いた試験官の話し方（相手役の声を借りる）。取れなければ端末の声
    static let examinerStyle = "A calm, polite and neutral English proficiency test interviewer. Clear standard pronunciation, moderate pace, friendly but formal, no chit-chat."

    /// 吹き出しの「ゆっくりもう一回」。答える番のときだけ（録音中に鳴らさない）
    func sayClearly(_ text: String) {
        guard phase == .listening else { return }
        say(text, slow: true)
    }

    private func say(_ text: String, slow: Bool = false) {
        let epoch = Speaker.shared.begin()
        var client = app.naturalVoice ? app.talkClient : nil
        #if DEBUG
        if DevHooks.fakeTalk { client = nil }
        #endif
        let rate: Float = slow ? 0.36 : 0.46
        guard let client else { Speaker.shared.speakInOrder([(text, nil)], rate: rate, epoch: epoch); return }
        let part = VoicePart(speaker: Voice.native, text: text, style: Self.examinerStyle + (slow ? " Speak noticeably slower than usual, articulating every word, with short pauses between phrases." : ""))
        let voices = Voice.voices(partner: app.partner, tora: app.toraVoice)
        Task {
            if let wav = try? await client.speech([part], voices: voices), Speaker.shared.play(wav, epoch: epoch) { return }
            guard Speaker.shared.epoch == epoch else { return }
            Speaker.shared.speakInOrder([(text, nil)], rate: rate, epoch: epoch)
        }
    }

    /// 閉じるとき（途中でも）。録音中なら止める。記録はしない
    func abandon() async {
        stopTimer()
        if phase == .speaking || phase == .answering { _ = await recorder.stop() }
        Speaker.shared.stop()
    }

    // MARK: - Gemini

    private func request(_ r: Exam.Request, audio: Data?) async -> String? {
        #if DEBUG
        if DevHooks.fakeTalk { return await Self.fake(r) }
        #endif
        guard let client = app.talkClient else {
            error = app.talkBlocker ?? String(localized: "練習には、「設定」で「おまかせ（キー不要）」を選ぶか、Gemini の API キーを登録してください。")
            return nil
        }
        let message = Exam.userMessage(r, history: lines, notes: notes)
        do {
            let raw = try await client.exam(audio: audio, mimeType: Recorder.mimeType, message: message, system: Exam.system(variant: app.targetLanguage))
            if app.usesRelay { await app.refreshTalkQuota() }
            return raw
        } catch let f as GeminiClient.Failure {
            if app.usesRelay { await app.refreshTalkQuota() }
            if case .quota(_, let limit) = f {
                error = String(localized: "今日の会話の回数（\(limit) ターン）を使い切りました。日付が変わると戻ります。自分の Gemini キーを登録すると回数の制限なく使えます。")
            } else {
                error = AppModel.message(for: f, mic: recorder.inputName)
            }
            return nil
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    #if DEBUG
    /// -HGFakeTalk 1: Gemini に送らず見本の返事を返す（画面の確かめ用）
    private static func fake(_ r: Exam.Request) async -> String {
        try? await Task.sleep(nanoseconds: 700_000_000)
        switch r {
        case .speech:
            return #"{"heard":"I agree that the development of AI should be strictly regulated. Uh, I have two reasons. First, AI can be used to make fake videos, and it is hard to know what is true. Second, many people may lose their jobs, so government should prepare rules. In conclusion, I think regulation is necessary.","pronunciation":{"score":6,"comment":"regulated の強勢が前に来てたな。re-gu-LA-ted じゃなくて RE-gu-la-ted だ。間はあるが、止まらずに言い切れてる。"},"note":"立場は明確。理由が抽象的で具体例が少ない。1 分 10 秒ほどで終わり短い。","question":"You mentioned fake videos. Don't you think regulation might slow down useful innovation?"}"#
        case .answer(_, let last):
            return last ? #"{"heard":"Yes, maybe. But I think safety is more important than speed.","note":"短いが立場は保てた。","question":""}"#
                : #"{"heard":"Yes, it may slow down, but I think safety is more important. For example, medical AI must be safe.","note":"反論に答えられた。例が一つ。","question":"Who should be responsible for making these rules: governments or the companies themselves?"}"#
        case .score:
            return #"{"scores":{"speech":{"score":6,"comment":"立場ははっきりしてる。理由に具体例が足りなくて、2 分の半分で終わっちまったな。"},"interaction":{"score":7,"comment":"突っ込まれても立場を崩さず返せてた。例をもう一つ足せれば上だ。"},"grammar":{"score":6,"comment":"government の前の the が抜けてる。語彙は 1 級にしては平易だな。"}},"summary":"For example, medical AI must be safe. と自分で例を出せたのは買ってやる。次はスピーチを 2 分使い切るのが先だ。理由ごとに例を一つずつ足せ。","fixes":[{"type":"grammar","original":"government should prepare rules","suggestion":"the government should establish clear rules","reason":"the が要る。prepare より establish が硬い場に合う"},{"type":"vocabulary","original":"make fake videos","suggestion":"create convincing deepfakes","reason":"1 級ならこの語を使いたいな"}],"model":"I firmly believe that the development of artificial intelligence should be strictly regulated, for two main reasons. First, ... In conclusion, ...","phrases":[{"said":"〜を野放しにする","ways":["leave ... unchecked"]},{"said":"技術革新を妨げる","ways":["stifle innovation"]},{"said":"〜に説明責任を負わせる","ways":["hold ... accountable"]}]}"#
        }
    }
    #endif
}

/// 試験の練習のシート。トピックを選ぶ → 1 分の準備 → 2 分のスピーチ → 質疑応答 → 採点
struct ExamSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject var exam: ExamModel
    @State private var confirmClose = false
    @State private var showModel = false

    var body: some View {
        NavigationStack {
            Group {
                switch exam.phase {
                case .choose: chooseBody
                case .prep, .speaking: timedBody
                case .ended: resultBody
                default: interactionBody
                }
            }
            .background(Theme.bg)
            .navigationTitle("英検 1 級 2 次の練習").compactNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(exam.active ? String(localized: "やめる") : String(localized: "閉じる")) {
                        if exam.active && exam.phase != .prep { confirmClose = true }
                        else { Task { await exam.abandon(); dismiss() } }
                    }
                }
            }
            .confirmationDialog("練習をやめますか？ 採点はされず、記録にも残りません。", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("やめる", role: .destructive) { Task { await exam.abandon(); dismiss() } }
                Button("続ける", role: .cancel) {}
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 600, idealHeight: 800)
        #endif
        .interactiveDismissDisabled(exam.active)
        .task { await model.refreshTalkQuota() }
        .onDisappear { Task { await exam.abandon() } }
    }

    private var errorCard: some View {
        Group {
            if let e = exam.error {
                Card {
                    Text(e).font(.callout).foregroundStyle(Theme.bad)
                    if exam.retryable {
                        Button("もう一度送る") { Task { await exam.retry() } }.buttonStyle(.bordered).tint(Theme.accent)
                    }
                }
            }
        }
    }

    // MARK: - トピックを選ぶ

    private var chooseBody: some View {
        ScrollView {
            VStack(spacing: 12) {
                errorCard
                Card {
                    Text("本番と同じ流れです").font(.callout.weight(.bold)).foregroundStyle(Theme.text)
                    step("1", "5 つのトピックから 1 つ選ぶ")
                    step("2", "1 分で考える（メモは取れません）。時間が来ると録音が始まります")
                    step("3", "2 分のスピーチ。2 分で止まります")
                    step("4", "面接官の質問に答える（\(Exam.maxQuestions) 問まで・約 4 分）")
                    step("5", "スピーチ・質疑応答・文法と語彙・発音の 4 つを各 10 点で採点")
                    Text("採点は AI の目安です。英検の公式の点数ではありません。").font(.caption).foregroundStyle(Theme.muted)
                }
                Card(title: String(localized: "トピックを選んでください")) {
                    ForEach(exam.topics, id: \.self) { t in
                        Button { exam.choose(t) } label: {
                            Text(t).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.talkBlocker != nil)
                    }
                    Button { exam.redraw() } label: { Label("別の 5 つ", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.bordered).tint(Theme.muted)
                }
                if let why = model.talkBlocker {
                    Card { Text(why).font(.callout).foregroundStyle(Theme.text) }
                } else if let q = model.talkQuota {
                    Note(text: String(localized: "今日はあと \(q.remaining) ターン（三人で話すと共通）。1 回の練習で 6 ターンほど使います。"))
                }
            }
            .padding(12)
        }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n).font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Theme.info, in: Circle())
            Text(text).font(.callout).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 準備とスピーチ

    private var timedBody: some View {
        let speaking = exam.phase == .speaking
        let total = speaking ? Exam.speechSeconds : Exam.prepSeconds
        return ScrollView {
            VStack(spacing: 16) {
                errorCard
                Card(title: String(localized: "トピック")) {
                    Text(exam.topic).font(.title3.weight(.bold)).foregroundStyle(Theme.text).textSelection(.enabled)
                }
                VStack(spacing: 6) {
                    Text(speaking ? String(localized: "スピーチ中") : String(localized: "準備（考える時間）"))
                        .font(.callout.weight(.bold)).foregroundStyle(speaking ? Theme.bad : Theme.info)
                    Text(clock(exam.remaining))
                        .font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(exam.remaining <= 15 ? Theme.warn : Theme.text)
                    ProgressView(value: Double(total - exam.remaining), total: Double(total))
                        .tint(speaking ? Theme.bad : Theme.info)
                    if speaking {
                        Text(exam.remaining > 60 ? String(localized: "まだ半分以上あります。理由に具体例を") : (exam.remaining > 20 ? String(localized: "2 つ目の理由へ") : String(localized: "結論でまとめましょう")))
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.vertical, 8)
                if speaking {
                    RecordingStrip(recorder: exam.recorder)
                    Button { Task { await exam.finishSpeech() } } label: {
                        Label("話し終えた", systemImage: "stop.fill").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.bad).controlSize(.large)
                } else {
                    Card(title: String(localized: "組み立ての型")) {
                        step("1", "立場をはっきり言う（I strongly believe that ...）")
                        step("2", "理由 1 ＋ 具体例")
                        step("3", "理由 2 ＋ 具体例")
                        step("4", "結論で立場をもう一度（For these reasons, ...）")
                    }
                    Button { Task { await exam.startSpeech() } } label: {
                        Label("準備を終えて話す", systemImage: "mic.fill").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                    Note(text: String(localized: "1 分たつと自動で録音が始まります。"))
                }
            }
            .padding(12)
        }
    }

    private func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    // MARK: - 質疑応答

    private var interactionBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        Card(title: String(localized: "トピック")) {
                            Text(exam.topic).font(.callout.weight(.bold)).foregroundStyle(Theme.text)
                        }
                        ForEach(Array(exam.lines.enumerated()), id: \.offset) { i, l in
                            Group {
                                if l.who == "native" {
                                    NativeBubble(line: l, name: String(localized: "面接官")) { exam.sayClearly(l.text) }
                                } else {
                                    VStack(alignment: .trailing, spacing: 4) {
                                        if l.tag == "exam_speech" {
                                            Tag(text: String(localized: "スピーチ（\(exam.speechSeconds / 60):\(String(format: "%02d", exam.speechSeconds % 60))）"), fg: Theme.accent, bg: Theme.accentBg)
                                        }
                                        MeBubble(line: l)
                                    }
                                }
                            }
                            .id("line-\(i)")
                        }
                        if exam.busy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(busyText).font(.caption).foregroundStyle(Theme.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                            .id("busy")
                        }
                        errorCard
                    }
                    .padding(12)
                    .textSelection(.enabled)
                }
                .onChange(of: exam.lines.count) { _, n in withAnimation { proxy.scrollTo("line-\(max(0, n - 1))", anchor: .bottom) } }
                .onChange(of: exam.busy) { _, b in if b { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } } }
            }
            if exam.phase == .listening || exam.phase == .answering { answerBar }
        }
    }

    private var busyText: String {
        switch exam.phase {
        case .sending: return String(localized: "面接官がスピーチを聞いています…")
        case .scoring: return String(localized: "採点しています…")
        default: return String(localized: "面接官が聞いています…")
        }
    }

    private var answerBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.line)
            VStack(spacing: 8) {
                Text(String(localized: "質問 \(exam.questionCount) / \(Exam.maxQuestions)")).font(.caption2).foregroundStyle(Theme.faint)
                if exam.phase == .answering { RecordingStrip(recorder: exam.recorder) }
                HStack(spacing: 10) {
                    Button { exam.repeatQuestion() } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "arrow.counterclockwise").font(.title3)
                            Text("質問をもう一度").font(.caption2.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(Theme.muted)
                    .disabled(exam.phase != .listening)
                    Button {
                        Task { if exam.phase == .answering { await exam.finishAnswer() } else { await exam.startAnswer() } }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: exam.phase == .answering ? "stop.fill" : "mic.fill").font(.title2)
                            Text(exam.phase == .answering ? String(localized: "答え終えた") : String(localized: "答える")).font(.caption.weight(.bold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent).tint(exam.phase == .answering ? Theme.bad : Theme.accent)
                    Button { Task { await exam.finish() } } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "checkmark.seal").font(.title3)
                            Text("終えて採点").font(.caption2.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(Theme.info)
                }
            }
            .padding(12)
        }
        .background(Theme.bg)
    }

    // MARK: - 採点

    private var resultBody: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let r = exam.result {
                    Card {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(r.total)").font(.system(size: 48, weight: .bold, design: .rounded)).foregroundStyle(r.likelyPass ? Theme.good : Theme.warn)
                            Text("/ \(ExamResult.max)").font(.title3.weight(.semibold)).foregroundStyle(Theme.muted)
                            Spacer()
                            Tag(text: r.likelyPass ? String(localized: "合格の目安に届いています") : String(localized: "合格の目安（7 割）まであと \(max(0, (ExamResult.max * 7 + 9) / 10 - r.total)) 点"),
                                fg: r.likelyPass ? Theme.good : Theme.warn, bg: r.likelyPass ? Theme.goodBg : Theme.warnBg)
                        }
                        Text(exam.topic).font(.caption).foregroundStyle(Theme.muted)
                        ForEach(r.scores, id: \.key) { s in scoreRow(s) }
                        Text("AI による目安です。英検の公式の点数ではありません。").font(.caption2).foregroundStyle(Theme.faint)
                    }
                    if !r.summary.isEmpty {
                        Card(title: String(localized: "トラさんの総評")) { Text(r.summary).font(.callout).foregroundStyle(Theme.text) }
                    }
                    if !r.fixes.isEmpty, let s = exam.saved {
                        Card(title: String(localized: "直すべし")) {
                            ForEach(Array(r.fixes.enumerated()), id: \.offset) { i, it in
                                if i > 0 { Divider().overlay(Theme.line) }
                                IssueRow(issue: it, sessionId: s.id)
                            }
                        }
                    }
                    if !r.model.isEmpty {
                        Card(title: String(localized: "あなたの主張で組み直したスピーチ")) {
                            HStack {
                                Text("約 2 分で話せる長さです。声に出して読むと、型が体に入ります。").font(.caption).foregroundStyle(Theme.muted)
                                Spacer()
                                SpeakButton(text: r.model)
                            }
                            Text(r.model).font(.callout).foregroundStyle(Theme.text).textSelection(.enabled)
                                .lineLimit(showModel ? nil : 6)
                            Button(showModel ? String(localized: "たたむ") : String(localized: "全部見る")) { showModel.toggle() }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                    if !r.phrases.isEmpty {
                        Card(title: String(localized: "次に使える言い回し")) {
                            ForEach(Array(r.phrases.enumerated()), id: \.offset) { i, a in
                                if i > 0 { Divider().overlay(Theme.line) }
                                AskRow(ask: a, sessionId: exam.saved?.id)
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button { exam.again() } label: {
                        Label("同じトピックでもう一回", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    Button { exam.newTopics() } label: {
                        Label("別のトピック", systemImage: "list.bullet").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(Theme.info)
                }
                Note(text: String(localized: "同じトピックを続けて話すと、2 回目は言葉が出やすくなります。記録は履歴に残ります。"))
            }
            .padding(12)
        }
    }

    private func scoreRow(_ s: ExamScore) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Exam.label(s.key)).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text("\(s.score) / 10").font(.callout.weight(.bold)).monospacedDigit()
                    .foregroundStyle(s.score >= 7 ? Theme.good : (s.score >= 5 ? Theme.warn : Theme.bad))
            }
            ProgressView(value: Double(s.score), total: 10)
                .tint(s.score >= 7 ? Theme.good : (s.score >= 5 ? Theme.warn : Theme.bad))
            if !s.comment.isEmpty { Text(s.comment).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, 2)
    }
}
