import Foundation
import SwiftUI

/// 「三人で話す」の進み具合。シートを開いている間だけ生きる（会話の中身は終わったら AppModel の記録に入る）
@MainActor
final class TalkModel: ObservableObject {

    enum Phase: Equatable {
        case setup              // まだ始めていない（話題を決める画面）
        case opening            // ネイティブ役の最初の一言を待っている
        case listening          // 学習者の番（マイクを押すのを待っている）
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
    /// 会話の開始時刻（記録の id になる）
    private(set) var startedAt = Date()

    private unowned let app: AppModel

    init(app: AppModel) { self.app = app }

    var recorder: Recorder { app.recorder }
    var language: TargetLanguage { app.targetLanguage }
    var nativeName: String { Talk.nativeName(language) }
    /// 母語が日本語で、話す言語が日本語でないとき、発言に日本語が混ざっていたら「助けてもらった分」に数える
    private var countsJapanese: Bool { TargetLanguage.explanation == .ja && language != .jaJP }
    var tally: (alone: Int, helped: Int) { Talk.tally(lines, nativeLanguageIsJapanese: countsJapanese) }
    /// 会話中にためている直しの数（終わるとまとめて見せる）
    var pendingFixes: Int { lines.filter { $0.who == "me" }.reduce(0) { $0 + $1.fixes.count } }
    var turns: Int { lines.filter { $0.who == "me" && !$0.text.isEmpty }.count }
    var busy: Bool { phase == .opening || phase == .thinking || phase == .closing }
    var active: Bool { phase != .setup && phase != .ended }

    // MARK: - 進め方

    /// はじめる: ネイティブ役が話題を切り出す
    func start() async {
        guard phase == .setup else { return }
        error = nil
        startedAt = Date()
        lines = []
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .opening
        guard let turn = await request(.open(topic: t.isEmpty ? (Talk.topics.randomElement() ?? "今日あったこと") : t), audio: nil) else {
            phase = .setup; return
        }
        if !turn.reply.isEmpty {
            lines.append(TalkLine(who: "native", text: turn.reply, sub: turn.replySub))
            Speaker.shared.speak(turn.reply)
        }
        phase = .listening
    }

    func startRecording() async {
        guard phase == .listening else { return }
        error = nil
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
        let result = await recorder.stop()
        guard let result, result.seconds >= 1, !result.audio.isEmpty else {
            phase = .listening
            error = String(localized: "短すぎました。もう少し話してから止めてください")
            return
        }
        phase = .thinking
        guard let turn = await request(.speak, audio: result.audio) else { phase = .listening; return }
        apply(turn)
    }

    /// 学習者の発言への返事を会話に足す（学習者 → トラさん → ネイティブ役の順）
    private func apply(_ turn: TalkTurn) {
        // 聞き取れなかったときは学習者の行を足さず、ネイティブ役の聞き返しだけ出す
        if !turn.heard.isEmpty {
            let same = PhraseLogic.phraseKey(turn.corrected) == PhraseLogic.phraseKey(turn.heard)
            lines.append(TalkLine(who: "me", text: turn.heard, sub: same ? "" : turn.corrected, fixes: turn.fixes))
        }
        if !turn.help.isEmpty || !turn.asks.isEmpty {
            lines.append(TalkLine(who: "tora", text: turn.help, asks: turn.asks))
        }
        if !turn.reply.isEmpty {
            lines.append(TalkLine(who: "native", text: turn.reply, sub: turn.replySub))
            Speaker.shared.speak(turn.reply)
        }
        phase = .listening
    }

    /// なんて言えばいい？: トラさんが言えそうなことを 2 つ出す（音声なし）
    func hint() async {
        guard phase == .listening else { return }
        error = nil
        phase = .thinking
        guard let turn = await request(.hint, audio: nil) else { phase = .listening; return }
        if !turn.asks.isEmpty || !turn.help.isEmpty {
            lines.append(TalkLine(who: "tora", text: turn.help, sub: "hint", asks: turn.asks))
        }
        phase = .listening
    }

    /// 終わる: 別れの一言と締めをもらって、記録に残す。通信に失敗しても記録は残す
    func end() async {
        guard phase == .listening || phase == .recording else { return }
        if phase == .recording { _ = await recorder.stop() }
        Speaker.shared.stop()
        error = nil
        if turns == 0 {
            // 何も話していなければ記録せずに終わる
            phase = .ended
            return
        }
        phase = .closing
        if let turn = await request(.close, audio: nil) {
            if !turn.reply.isEmpty { lines.append(TalkLine(who: "native", text: turn.reply, sub: turn.replySub)) }
            good = turn.good
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
        let message = Talk.userMessage(request: r, history: lines, language: language, targets: targets)
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
    /// -HGTalkDemo <talk|end>: 見本の返事で会話を自動で進める（スクショ用）。talk＝2 往復＋ヒントまで、end＝締めまで
    func demo(_ stage: String) async {
        await start()
        for _ in 0..<2 {
            guard phase == .listening else { return }
            phase = .thinking
            if let turn = await request(.speak, audio: nil) { apply(turn) }
            phase = .listening
        }
        await hint()
        if stage == "end" { await end() }
    }

    /// -HGFakeTalk 1: Gemini に送らず、見本の返事を返す（画面の確かめ用）
    private static func fake(_ r: Talk.Request, lines: [TalkLine], language: TargetLanguage) async -> TalkTurn {
        try? await Task.sleep(nanoseconds: 700_000_000)
        switch r {
        case .open:
            return TalkTurn(reply: "Hey! Nice to finally meet you. So, what's been the best thing you ate this week?", replySub: "やあ、やっと会えたね。今週いちばんおいしかったものって何？")
        case .speak:
            let n = lines.filter { $0.who == "me" }.count
            if n == 0 {
                return TalkTurn(heard: "I ate... えっと、焼き芋 at the station. It was very sweet.", corrected: "I had a baked sweet potato at the station. It was really sweet.",
                                reply: "A baked sweet potato! Those are amazing in the cold. Do you usually grab one on your way home?", replySub: "焼き芋か！寒い日には最高だよね。帰り道によく買うの？",
                                help: "焼き芋はこう言うんでえ。", asks: [Ask(said: "焼き芋", ways: ["a baked sweet potato", "a roasted sweet potato"], ipa: ["/ə ˈbeɪkt swiːt pəˈteɪtoʊ/", "/ə ˈroʊstɪd swiːt pəˈteɪtoʊ/"], note: "屋台のは baked で通じらあ。")],
                                fixes: [Issue(type: "vocabulary", original: "I ate 焼き芋", suggestion: "I had a baked sweet potato", reason: "食べたは had でも言えるぞ。軽い言い方だ")])
            }
            return TalkTurn(heard: "Yes, almost every day in winter. My cat also likes the smell.", corrected: "Yes, almost every day in winter. My cat likes the smell too.",
                            reply: "Your cat has good taste! What's your cat's name?", replySub: "猫ちゃん、センスいいね！名前は？")
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
