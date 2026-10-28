import Foundation
import SwiftUI

/// 「三人で話す」の進み具合。シートを開いている間だけ生きる（会話の中身は終わったら AppModel の記録に入る）
@MainActor
final class TalkModel: ObservableObject {

    enum Phase: Equatable {
        case setup              // まだ始めていない（話題を決める画面）
        case opening            // ネイティブ役の最初の一言を待っている
        case listening          // 学習者の番（マイクを押すのを待っている）
        case repeating          // トラさんの言い方を口に出す番（Sam は待っている）
        case consulting         // トラさんにこっそり相談する（文字か声で、言いたいことを伝える）
        case recording
        case thinking           // 二人の返事を待っている
        case closing            // 締めの言葉を待っている
        case ended              // 終わった（まとめを表示中）
    }

    @Published private(set) var phase: Phase = .setup
    @Published private(set) var lines: [TalkLine] = []
    @Published var error: String?
    /// 話したいこと（空ならアプリが話題を 1 つ引く）
    @Published var topic = ""
    /// 締めのトラさんの一言
    @Published private(set) var good = ""
    /// 記録に残したもの（終わったあとに「直すべし」「英語ならこう」を出すのに使う）
    @Published private(set) var saved: Session?
    /// 「同じ話をもう一回」で、さっきの会話。空なら初回
    @Published private(set) var rerunOf: [TalkLine] = []
    /// さっきの会話の数（もう一回のまとめで比べる）
    private(set) var previousTally: Talk.Tally?
    /// 前回の会話の覚え書き（翌日の Sam が振る）。無ければ nil
    private(set) var review: TalkReview?
    /// 会話の開始時刻（記録の id になる）
    private(set) var startedAt = Date()
    /// 言ってみる番のとき、トラさんがくれた言い方
    private var pendingWays: [String] = []
    /// 録音を始めたときに「言ってみる」番だったか
    private var recordingRepeat = false
    /// 録音を始めたときに「相談」中だったか（声で相談）
    private var recordingConsult = false
    /// 相談の文字（言いたいこと・事情）
    @Published var wish = ""
    /// AI の声を用意している間 true（文字は先に出す）
    @Published private(set) var voiceLoading = false
    private var voiceEpoch = 0

    private unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
        self.review = TalkReview.from(sessions: app.snapshot.sessions, today: app.today)
    }

    var recorder: Recorder { app.recorder }
    var language: TargetLanguage { app.targetLanguage }
    var nativeName: String { Talk.nativeName(language) }
    /// 母語が日本語で、話す言語が日本語でないとき、発言に日本語が混ざっていたら「助けてもらった分」に数える
    private var countsJapanese: Bool { TargetLanguage.explanation == .ja && language != .jaJP }
    var tally: Talk.Tally { Talk.tally(lines, nativeLanguageIsJapanese: countsJapanese) }
    /// 会話中にためている直しの数（終わるとまとめて見せる）
    var pendingFixes: Int { lines.filter { $0.who == "me" }.reduce(0) { $0 + $1.fixes.count } }
    var turns: Int { lines.filter { $0.who == "me" && !$0.text.isEmpty && !$0.tag.hasPrefix("repeat") }.count }
    var busy: Bool { phase == .opening || phase == .thinking || phase == .closing }
    var active: Bool { phase != .setup && phase != .ended }
    /// 学習者がマイクを押せる番か
    /// 相談中か（文字を書いている・声で相談を録っている・トラさんの答えを待っている）
    var inConsult: Bool { phase == .consulting || (phase == .recording && recordingConsult) || consultWaiting }
    @Published private var consultWaiting = false
    var myTurn: Bool { phase == .listening || phase == .repeating || phase == .consulting }

    // MARK: - 進め方

    /// はじめる: ネイティブ役が話題を切り出す
    func start() async {
        guard phase == .setup else { return }
        startedAt = Date()
        lines = []; good = ""; saved = nil; rerunOf = []; previousTally = nil
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        await open(.open(topic: t.isEmpty ? (Talk.topics.randomElement() ?? "今日あったこと") : t))
    }

    /// 同じ話をもう一回（今度は助けなしで）。さっきの会話を Sam に渡し、同じ質問を同じ順で振ってもらう
    func rerun() async {
        guard phase == .ended, turns > 0 else { return }
        let previous = lines
        previousTally = tally
        startedAt = Date()
        lines = []; good = ""; saved = nil
        rerunOf = previous
        phase = .setup
        await open(.open(topic: topic, rerun: previous))
    }

    private func open(_ r: Talk.Request) async {
        error = nil
        phase = .opening
        guard let turn = await request(r, audio: nil) else { phase = .setup; return }
        if !turn.reply.isEmpty {
            let l = TalkLine(who: "native", text: turn.reply, sub: turn.replySub)
            lines.append(l)
            say([l])
        }
        phase = .listening
    }

    func startRecording() async {
        guard myTurn else { return }
        error = nil
        recordingRepeat = phase == .repeating
        recordingConsult = phase == .consulting
        Speaker.shared.stop()   // 読み上げ中なら止める。録音に混ざらないように
        do {
            try await recorder.start(captions: app.captionsOn, language: app.language, micUID: app.micUID)
            phase = .recording
        } catch Recorder.Failure.micDenied {
            error = String(localized: "マイクの使用が許可されていません。設定で「独り言」のマイクをオンにしてください。")
        } catch {
            self.error = String(localized: "録音を始められませんでした: \(error.localizedDescription)")
        }
    }

    /// 止めて、二人の返事をもらう
    func stopAndSend() async {
        guard phase == .recording else { return }
        let back: Phase = recordingRepeat ? .repeating : (recordingConsult ? .consulting : .listening)
        let result = await recorder.stop()
        guard let result, result.seconds >= 1, !result.audio.isEmpty else {
            phase = back
            error = String(localized: "短すぎました。もう少し話してから止めてください")
            return
        }
        phase = .thinking
        if recordingConsult {
            await consult(audio: result.audio)
        } else if recordingRepeat {
            guard let turn = await request(.repeat(ways: pendingWays), audio: result.audio) else { phase = back; return }
            applyRepeat(turn)
        } else {
            guard let turn = await request(.speak, audio: result.audio) else { phase = back; return }
            apply(turn)
        }
    }

    /// 学習者の発言への返事を会話に足す（学習者 → トラさん → ネイティブ役の順）。
    /// トラさんが言い方を出したら、次は「言ってみる」番にする（見て終わりにしない）
    private func apply(_ turn: TalkTurn) {
        // 聞き取れなかったときは学習者の行を足さず、ネイティブ役の聞き返しだけ出す
        if !turn.heard.isEmpty {
            let same = PhraseLogic.phraseKey(turn.corrected) == PhraseLogic.phraseKey(turn.heard)
            // 言い淀んでトラさんに補ってもらった発言は「助けてもらった分」に数える
            lines.append(TalkLine(who: "me", text: turn.heard, sub: same ? "" : turn.corrected, fixes: turn.fixes, tag: turn.stuck && !turn.asks.isEmpty ? "stuck" : ""))
        }
        var added: [TalkLine] = []
        if !turn.help.isEmpty || !turn.asks.isEmpty {
            added.append(TalkLine(who: "tora", text: turn.help, sub: turn.stuck ? "stuck" : "", asks: turn.asks))
        }
        if !turn.reply.isEmpty {
            added.append(TalkLine(who: "native", text: turn.reply, sub: turn.replySub))
        }
        lines += added
        say(added)
        enterRepeatIfNeeded(turn.asks)
    }

    private func enterRepeatIfNeeded(_ asks: [Ask]) {
        let ways = asks.flatMap(\.ways)
        if ways.isEmpty { pendingWays = []; phase = .listening }
        else { pendingWays = ways; phase = .repeating }
    }

    /// 言ってみる番の結果。言えたら ✓、違っていたらトラさんの一言。Sam は直前の質問を言い直す
    private func applyRepeat(_ turn: TalkTurn) {
        if !turn.heard.isEmpty {
            lines.append(TalkLine(who: "me", text: turn.heard, tag: turn.saidOk ? "repeat_ok" : "repeat_ng"))
        }
        var added: [TalkLine] = []
        if !turn.saidOk, !turn.help.isEmpty {
            added.append(TalkLine(who: "tora", text: turn.help))
        }
        if !turn.reply.isEmpty {
            added.append(TalkLine(who: "native", text: turn.reply, sub: turn.replySub))
        }
        lines += added
        say(added)
        pendingWays = []
        phase = .listening
    }

    /// 言ってみるのを飛ばす（責めない）
    func skipRepeat() {
        guard phase == .repeating else { return }
        Speaker.shared.stop()
        pendingWays = []
        phase = .listening
    }

    /// トラさんに相談する画面を開く／閉じる（Sam は待っている）
    func openConsult() {
        guard phase == .listening else { return }
        error = nil
        Speaker.shared.stop()
        phase = .consulting
    }

    func cancelConsult() {
        guard phase == .consulting else { return }
        phase = .listening
    }

    /// おまかせ: トラさんが言えそうなことを 2 つ出す（音声なし）。出たら「言ってみる」番
    func hint() async {
        guard phase == .listening || phase == .consulting else { return }
        let back = phase
        error = nil
        phase = .thinking
        guard let turn = await request(.hint(), audio: nil) else { phase = back; return }
        applyHint(turn, asked: nil)
    }

    /// 相談: 言いたいこと（事情）を文字か声で伝え、トラさんがその言い方を出す。出たら「言ってみる」番
    func consult(audio: Data? = nil) async {
        let w = wish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard audio != nil || !w.isEmpty else { return }
        error = nil
        phase = .thinking
        consultWaiting = true
        defer { consultWaiting = false }
        guard let turn = await request(.hint(wish: w), audio: audio) else { phase = .consulting; return }
        wish = ""
        applyHint(turn, asked: audio == nil ? w : (turn.heard.isEmpty ? nil : turn.heard))
    }

    private func applyHint(_ turn: TalkTurn, asked: String?) {
        // 相談の中身も会話に残す（あとで読み返せる・次のターンの文脈になる）。Sam には聞こえていない扱い
        if let asked, !asked.isEmpty { lines.append(TalkLine(who: "me", text: asked, tag: "consult")) }
        var added: [TalkLine] = []
        if !turn.asks.isEmpty || !turn.help.isEmpty {
            added.append(TalkLine(who: "tora", text: turn.help, sub: "hint", asks: turn.asks))
        }
        lines += added
        say(added)
        enterRepeatIfNeeded(turn.asks)
    }

    /// 終わる: 別れの一言と締めをもらって、記録に残す。通信に失敗しても記録は残す
    func end() async {
        guard myTurn || phase == .recording else { return }
        if phase == .recording { _ = await recorder.stop() }
        Speaker.shared.stop()
        error = nil
        pendingWays = []
        if turns == 0 {
            // 何も話していなければ記録せずに終わる
            phase = .ended
            return
        }
        phase = .closing
        if let turn = await request(.close, audio: nil) {
            var spoken: [TalkLine] = []
            if !turn.reply.isEmpty {
                let l = TalkLine(who: "native", text: turn.reply, sub: turn.replySub)
                lines.append(l); spoken.append(l)
            }
            good = turn.good
            // 締めはトラさんも声で（記録の会話には入れない。まとめのカードに出る）
            if !turn.good.isEmpty { spoken.append(TalkLine(who: "tora", text: turn.good)) }
            say(spoken)
        } else {
            error = nil   // 締めが取れなくても、会話は残す
        }
        saved = app.finishTalk(lines: lines, good: good, startedAt: startedAt)
        phase = .ended
    }

    /// 閉じるとき（途中でも）。録音中なら止める。記録はしない
    func abandon() async {
        if phase == .recording { _ = await recorder.stop() }
        Speaker.shared.stop()
    }

    // MARK: - 声

    /// このターンで足した行を声に出す（トラさん → ネイティブ役の順）。文字は先に出ていて、声は後から届く。
    /// 自然な声（Gemini）が取れなければ端末の声で読む。届く前に録音を始めたら鳴らさない（Speaker の epoch）
    private func say(_ added: [TalkLine]) {
        let parts = Voice.parts(for: added, language: language)
        guard !parts.isEmpty else { return }
        let epoch = Speaker.shared.begin()
        let toraLang = TargetLanguage.explanation == .ja ? "ja-JP" : "en-US"
        let fallback: [(text: String, language: String?)] = parts.map { ($0.text, $0.speaker == Voice.tora ? toraLang : nil) }
        var client = app.naturalVoice ? app.talkClient : nil
        #if DEBUG
        if DevHooks.fakeTalk { client = nil }
        #endif
        guard let client else { Speaker.shared.speakInOrder(fallback, epoch: epoch); return }
        voiceLoading = true
        voiceEpoch = epoch
        Task {
            let wav = try? await client.speech(parts, voices: Voice.voices(language))
            if voiceEpoch == epoch { voiceLoading = false }
            if let wav, Speaker.shared.play(wav, epoch: epoch) { return }
            Speaker.shared.speakInOrder(fallback, epoch: epoch)
        }
    }

    // MARK: - Gemini

    private func request(_ r: Talk.Request, audio: Data?) async -> TalkTurn? {
        #if DEBUG
        if DevHooks.fakeTalk { return await Self.fake(r, lines: lines, language: language) }
        #endif
        guard let client = app.talkClient else {
            error = app.talkBlocker ?? String(localized: "会話には、「設定」で「おまかせ（キー不要）」を選ぶか、Gemini の API キーを登録してください。")
            return nil
        }
        let targets = app.todayCards().map(\.phrase)
        // 前回の話を振るのは、はじまりと普通の発言のとき。もう一回のときは「さっきの会話」が主役なので渡さない
        var rev: TalkReview? = nil
        switch r {
        case .open(_, let rerun): rev = rerun.isEmpty ? review : nil
        case .speak: rev = rerunOf.isEmpty ? review : nil
        default: break
        }
        let message = Talk.userMessage(request: r, history: lines, language: language, targets: targets, review: rev, hasAudio: audio != nil)
        do {
            let turn = try await client.talk(audio: audio, mimeType: Recorder.mimeType, message: message, system: Talk.system(language: language))
            if app.usesRelay { await app.refreshTalkQuota() }
            return turn
        } catch let f as GeminiClient.Failure {
            if app.usesRelay { await app.refreshTalkQuota() }
            if case .quota(_, let limit) = f {
                error = String(localized: "今日の「三人で話す」（\(limit) ターン）を使い切りました。日付が変わると戻ります。自分の Gemini キーを登録すると回数の制限なく使えます。")
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
    /// -HGTalkDemo <talk|end|rerun>: 見本の返事で会話を自動で進める（スクショ用）。
    /// talk＝2 往復＋言ってみる＋ヒントまで、end＝締めまで、rerun＝もう一回の途中まで
    func demo(_ stage: String) async {
        await start()
        for _ in 0..<2 {
            guard phase == .listening else { return }
            phase = .thinking
            if let turn = await request(.speak, audio: nil) { apply(turn) }
            if phase == .repeating {
                phase = .thinking
                if let turn = await request(.repeat(ways: pendingWays), audio: nil) { applyRepeat(turn) }
            }
        }
        await hint()
        if stage == "talk" { return }
        if stage == "consult" { skipRepeat(); openConsult(); wish = "同僚は何人かいるけど、その人に聞かないといけない状況で困ってる"; return }
        skipRepeat()
        await end()
        if stage == "rerun" {
            await rerun()
            guard phase == .listening else { return }
            phase = .thinking
            if let turn = await request(.speak, audio: nil) { apply(turn) }
        }
    }

    /// -HGFakeTalk 1: Gemini に送らず、見本の返事を返す（画面の確かめ用）
    private static func fake(_ r: Talk.Request, lines: [TalkLine], language: TargetLanguage) async -> TalkTurn {
        try? await Task.sleep(nanoseconds: 700_000_000)
        switch r {
        case .open(_, let rerun):
            if !rerun.isEmpty {
                return TalkTurn(reply: "Okay, let's run it back! So, what's been the best thing you ate this week?", replySub: "よし、もう一回！今週いちばんおいしかったものって何？")
            }
            return TalkTurn(reply: "Hey! Nice to finally meet you. So, what's been the best thing you ate this week?", replySub: "やあ、やっと会えたね。今週いちばんおいしかったものって何？")
        case .speak:
            let n = lines.filter { $0.who == "me" && !$0.tag.hasPrefix("repeat") }.count
            if n == 0 {
                return TalkTurn(heard: "I ate... えっと、焼き芋 at the station. It was very sweet.", corrected: "I had a baked sweet potato at the station. It was really sweet.",
                                reply: "A baked sweet potato! Those are amazing in the cold. Do you usually grab one on your way home?", replySub: "焼き芋か！寒い日には最高だよね。帰り道によく買うの？",
                                help: "焼き芋はこう言うんでえ。", asks: [Ask(said: "焼き芋", ways: ["a baked sweet potato", "a roasted sweet potato"], ipa: ["/ə ˈbeɪkt swiːt pəˈteɪtoʊ/", "/ə ˈroʊstɪd swiːt pəˈteɪtoʊ/"], note: "屋台のは baked で通じらあ。")],
                                fixes: [Issue(type: "vocabulary", original: "I ate 焼き芋", suggestion: "I had a baked sweet potato", reason: "食べたは had でも言えるぞ。軽い言い方だ")])
            }
            return TalkTurn(heard: "Yes, almost every day in winter. My cat also likes the smell.", corrected: "Yes, almost every day in winter. My cat likes the smell too.",
                            reply: "Your cat has good taste! What's your cat's name?", replySub: "猫ちゃん、センスいいね！名前は？")
        case .repeat:
            return TalkTurn(heard: "I had a baked sweet potato.", reply: "Nice! So, do you usually grab one on your way home?", replySub: "いいね！で、帰り道によく買うの？", saidOk: true)
        case .hint(let wish) where !wish.isEmpty:
            return TalkTurn(help: "そういう事情なら、困ってる気持ちを先に言っちまえ。", asks: [Ask(said: "同僚は何人かいるけど、その人に聞くしかなくて困ってる", ways: ["I have a few coworkers, but he's the only one who knows, so I have to ask him.", "There are other people on my team, but I really need to ask him."], ipa: [])])
        case .hint:
            return TalkTurn(help: "こう言ってみな。", asks: [Ask(said: "名前はごまです。黒い猫です", ways: ["His name is Goma. He's a black cat."], ipa: ["/hɪz neɪm ɪz ˈɡoʊmə hiz ə blæk kæt/"]),
                                                              Ask(said: "もう 15 歳です", ways: ["He's already 15."], ipa: ["/hiz ɔːlˈrɛdi fɪfˈtiːn/"])])
        case .close:
            return TalkTurn(reply: "This was fun. Let's talk again soon!", replySub: "楽しかったよ。また話そう！",
                            good: "焼き芋で詰まっても、It was very sweet まで自分の口で言い切ったな。そこは買ってやる。")
        }
    }
    #endif
}
