import XCTest
@testable import HitorigotoCore

/// 「三人で話す」: 応答の読み取り・記録への変換・数え方
final class TalkTests: XCTestCase {

    func testParseFullTurn() {
        let raw = """
        ```json
        {"heard": "I ate... えっと、焼き芋 at the station.", "corrected": "I had a baked sweet potato at the station.",
         "reply": "A baked sweet potato! Do you get one often?", "reply_sub": "焼き芋か！よく買うの？",
         "help": "焼き芋はこう言うんでえ。",
         "asks": [{"said": "焼き芋", "ways": ["a baked sweet potato", "a roasted sweet potato"], "ipa": ["/a/"], "note": "屋台のは baked だ"}],
         "fixes": [{"type": "vocabulary", "original": "I ate 焼き芋", "suggestion": "I had a baked sweet potato", "reason": "had でいい"},
                   {"type": "weird", "original": "same", "suggestion": "Same", "reason": "同じ形は直しではない"},
                   {"type": "grammar", "original": "a", "suggestion": "b"}, {"type": "grammar", "original": "c", "suggestion": "d"}],
         "good": ""}
        ```
        """
        let t = Talk.parse(raw)
        XCTAssertNotNil(t)
        XCTAssertEqual(t?.heard, "I ate... えっと、焼き芋 at the station.")
        XCTAssertEqual(t?.reply, "A baked sweet potato! Do you get one often?")
        XCTAssertEqual(t?.replySub, "焼き芋か！よく買うの？")
        XCTAssertEqual(t?.asks.count, 1)
        XCTAssertEqual(t?.asks.first?.ways, ["a baked sweet potato", "a roasted sweet potato"])
        XCTAssertEqual(t?.asks.first?.ipa, ["/a/", ""], "ipa は ways と同じ長さに揃える")
        XCTAssertEqual(t?.fixes.count, Talk.maxFixes, "同じ形の直しは捨て、上限で切る")
        XCTAssertEqual(t?.fixes.first?.type, "vocabulary")
        XCTAssertEqual(t?.fixes.map(\.suggestion), ["I had a baked sweet potato", "b"])
    }

    func testParseOpeningAndEmpty() {
        let t = Talk.parse(#"{"heard": "", "reply": "Hi! What did you do today?", "reply_sub": "やあ", "asks": [], "fixes": []}"#)
        XCTAssertEqual(t?.reply, "Hi! What did you do today?")
        XCTAssertEqual(t?.heard, "")
        XCTAssertNil(Talk.parse(#"{"heard": "", "reply": "", "help": "", "asks": [], "fixes": []}"#), "何も入っていない応答は読めなかった扱い")
        let rep = Talk.parse(#"{"heard": "I had a baked sweet potato.", "reply": "Nice! So, do you get one often?", "said_ok": true, "asks": [], "fixes": []}"#)
        XCTAssertEqual(rep?.saidOk, true)
        XCTAssertEqual(Talk.parse(#"{"heard": "I ate potato.", "reply": "Close!", "said_ok": "false"}"#)?.saidOk, true, "文字列の false は JS と同じく真（Gemini は bool で返す約束）")
        XCTAssertNil(Talk.parse("読めません"))
        XCTAssertNil(Talk.parse(nil))
    }

    func testSystemAndUserMessage() {
        let sys = Talk.system(language: .enUS, explanation: .ja)
        XCTAssertTrue(sys.contains("Sam"))
        XCTAssertTrue(sys.contains("英語"))
        XCTAssertTrue(sys.contains("アメリカ英語"))
        XCTAssertTrue(sys.contains("\"reply_sub\""))
        let en = Talk.system(language: .esES, explanation: .en)
        XCTAssertTrue(en.contains("Lucía"))
        XCTAssertTrue(en.contains("出力言語の上書き"))

        let history = [TalkLine(who: "native", text: "Hi there!"), TalkLine(who: "me", text: "Hello. えっと"),
                       TalkLine(who: "tora", text: "こう言え", asks: [Ask(said: "えっと", ways: ["Well"])])]
        let m = Talk.userMessage(request: .speak, history: history, language: .enUS, targets: ["on the mend"], explanation: .ja)
        XCTAssertTrue(m.contains("Sam: Hi there!"))
        XCTAssertTrue(m.contains("学習者: Hello. えっと"))
        XCTAssertTrue(m.contains("トラさん: こう言え（言い方: Well）"))
        XCTAssertTrue(m.contains("- on the mend"))
        XCTAssertTrue(m.contains("添付の音声"))
        XCTAssertTrue(Talk.userMessage(request: .open(topic: "猫"), history: [], language: .enUS).contains("猫"))
        XCTAssertTrue(Talk.userMessage(request: .hint(), history: history, language: .enUS).contains("2 つ"))
        XCTAssertTrue(Talk.userMessage(request: .close, history: history, language: .enUS).contains("\"good\""))
        // 言ってみる・もう一回・前回の話
        let r = Talk.userMessage(request: .repeat(ways: ["a baked sweet potato", "a roasted sweet potato"]), history: history, language: .enUS)
        XCTAssertTrue(r.contains("言ってみる") && r.contains("a baked sweet potato / a roasted sweet potato") && r.contains("said_ok"))
        let again = Talk.userMessage(request: .open(topic: "猫", rerun: history), history: [], language: .enUS)
        XCTAssertTrue(again.contains("もう一度同じ流れ") && again.contains("Sam: Hi there!") && again.contains("言い方: Well"))
        let rv = TalkReview(when: "昨日", summary: "I had a baked sweet potato.", phrases: ["a baked sweet potato"])
        let withReview = Talk.userMessage(request: .open(topic: "猫"), history: [], language: .enUS, review: rv)
        XCTAssertTrue(withReview.contains("前回の会話（昨日）") && withReview.contains("- a baked sweet potato"))
        XCTAssertTrue(Talk.system(language: .enUS, explanation: .ja).contains("言ってみる"))
    }

    func testReviewFromSessions() {
        var s = Talk.makeSession(id: "2026-10-27T10:00:00.000Z", lines: [
            TalkLine(who: "native", text: "Hi"), TalkLine(who: "me", text: "I ate 焼き芋.", sub: "I had a baked sweet potato.",
                                                         fixes: [Issue(type: "vocabulary", original: "I ate", suggestion: "I had", reason: "")]),
            TalkLine(who: "tora", text: "", asks: [Ask(said: "焼き芋", ways: ["a baked sweet potato", "a roasted sweet potato"])]),
        ], good: "", engine: "talk-gemini")
        let plain = Session(id: "2026-10-28T09:00:00.000Z", transcript: "monologue", issues: [])
        // 会話の日付は端末の時刻で数える（id は UTC）
        let localDay = Logic.todayStamp(ISO8601DateFormatter().date(from: "2026-10-27T10:00:00Z")!)
        let r = TalkReview.from(sessions: [plain, s], today: PhraseLogic.addDays(localDay, 1))
        XCTAssertEqual(r?.when, "昨日")
        XCTAssertEqual(r?.phrases, ["a baked sweet potato", "I had"], "言い方は 1 件につき最初の 1 つ・直しは直した形")
        XCTAssertEqual(r?.summary, "I had a baked sweet potato.")
        XCTAssertEqual(TalkReview.from(sessions: [plain, s], today: PhraseLogic.addDays(localDay, 1), maxDays: 0), nil, "古すぎる会話は振らない")
        XCTAssertEqual(TalkReview.from(sessions: [s], today: localDay)?.when, "さっき")
        s.transcript = ""
        XCTAssertNil(TalkReview.from(sessions: [s], today: localDay), "何も話していない会話は飛ばす")
    }

    func testMakeSessionAndTally() throws {
        let lines = [
            TalkLine(who: "native", text: "What did you eat?", sub: "何食べた？"),
            TalkLine(who: "me", text: "I ate 焼き芋.", sub: "I had a baked sweet potato.",
                     fixes: [Issue(type: "vocabulary", original: "I ate 焼き芋", suggestion: "I had a baked sweet potato", reason: "r")]),
            TalkLine(who: "tora", text: "こう言うんでえ", asks: [Ask(said: "焼き芋", ways: ["a baked sweet potato"])]),
            TalkLine(who: "native", text: "Nice! Was it sweet?"),
            TalkLine(who: "me", text: "Yes, very sweet.", fixes: [Issue(type: "vocabulary", original: "I ate 焼き芋", suggestion: "I had a baked sweet potato", reason: "dup")]),
            TalkLine(who: "tora", text: "こう言ってみな", sub: "hint", asks: [Ask(said: "猫も好き", ways: ["My cat likes it too."])]),
            TalkLine(who: "me", text: "My cat likes it too."),
            TalkLine(who: "me", text: "His name is Goma.", tag: "repeat_ok"),
            TalkLine(who: "me", text: "His name Goma.", tag: "repeat_ng"),
            TalkLine(who: "native", text: "Bye!"),
        ]
        let s = Talk.makeSession(id: "2026-10-28T10:00:00.000Z", lines: lines, good: "上等だ", engine: "talk-gemini")
        XCTAssertEqual(s.transcript, "I ate 焼き芋.\nYes, very sweet.\nMy cat likes it too.", "記録の本文は学習者の発言だけ")
        XCTAssertEqual(s.correctedText, "I had a baked sweet potato.\nYes, very sweet.\nMy cat likes it too.")
        XCTAssertEqual(s.issues.count, 1, "同じ直しは 1 回")
        XCTAssertEqual(s.asks?.map(\.said), ["焼き芋", "猫も好き"])
        XCTAssertEqual(s.good, "上等だ")
        XCTAssertEqual(s.talk?.count, 10)
        XCTAssertEqual(s.transcript?.components(separatedBy: "\n").count, 3, "言い直しのターンは本文に入れない")

        let t = Talk.tally(lines, nativeLanguageIsJapanese: true)
        XCTAssertEqual(t.alone, 1, "英語だけで言えたのは Yes, very sweet. の 1 回")
        XCTAssertEqual(t.helped, 2, "日本語が混ざった 1 回と、ヒントのあとの 1 回")
        XCTAssertEqual(t.repeated, 1, "言い直せたのは 1 回（違ったのは数えない）")
        let t2 = Talk.tally(lines, nativeLanguageIsJapanese: false)
        XCTAssertEqual(t2.alone, 2)

        // 記録の出し入れで会話が残る
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(back.talk, lines)
        XCTAssertEqual(back, s)
        // 昔の記録（talk 無し）も読める
        let old = try JSONDecoder().decode(Session.self, from: #"{"id": "x", "issues": []}"#.data(using: .utf8)!)
        XCTAssertNil(old.talk)
        // tag は空なら書かない（印の無い行の JSON を変えない）
        let plainLine = String(data: try JSONEncoder().encode(TalkLine(who: "me", text: "Hi")), encoding: .utf8)!
        XCTAssertFalse(plainLine.contains("\"tag\""))
        XCTAssertTrue(String(data: try JSONEncoder().encode(TalkLine(who: "me", text: "Hi", tag: "repeat_ok")), encoding: .utf8)!.contains("repeat_ok"))
    }

    func testMakeSessionWithoutSpeechHasEmptyBody() {
        let s = Talk.makeSession(id: "x", lines: [TalkLine(who: "native", text: "Hi")], good: "", engine: "talk-cloud")
        XCTAssertEqual(s.transcript, "")
        XCTAssertNil(s.good)
        XCTAssertNil(s.asks)
    }

    func testHasJapanese() {
        XCTAssertTrue(Talk.hasJapanese("I ate 焼き芋"))
        XCTAssertTrue(Talk.hasJapanese("えっと"))
        XCTAssertFalse(Talk.hasJapanese("I had a baked sweet potato."))
    }

    // トラさんも声で話す: 一言＋言い方（一言に入っていなければ足す）→ ネイティブ役の順。学習者の行は読まない
    func testVoicePartsOrderAndWays() {
        let lines = [
            TalkLine(who: "me", text: "I ate 焼き芋"),
            TalkLine(who: "tora", text: "焼き芋はこう言うんでえ。", asks: [Ask(said: "焼き芋", ways: ["a baked sweet potato", "a roasted sweet potato"])]),
            TalkLine(who: "native", text: "Nice! Do you grab one often?"),
        ]
        let p = Voice.parts(for: lines, language: .enUS)
        XCTAssertEqual(p.map(\.speaker), [Voice.tora, Voice.native])
        XCTAssertEqual(p[0].text, "焼き芋はこう言うんでえ。 a baked sweet potato")
        XCTAssertFalse(p[0].style.isEmpty)
        // 一言の中に言い方が入っていれば重ねない
        let q = Voice.parts(for: [TalkLine(who: "tora", text: "a baked sweet potato って言いな", asks: [Ask(said: "焼き芋", ways: ["a baked sweet potato"])])], language: .enUS)
        XCTAssertEqual(q.first?.text, "a baked sweet potato って言いな")
        // 同じ人が続いたら 1 片に
        let r = Voice.parts(for: [TalkLine(who: "native", text: "A."), TalkLine(who: "native", text: "B?")], language: .enUS)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.text, "A. B?")
        XCTAssertEqual(Voice.voices(.enUS)[Voice.tora], "Enceladus")
    }

    func testWavHeader() {
        let w = Voice.wav(pcm: Data(repeating: 0, count: 480), sampleRate: 24000)
        XCTAssertEqual(w.count, 44 + 480)
        XCTAssertEqual(String(data: w.prefix(4), encoding: .ascii), "RIFF")
    }

    // 相談: 中身が指示文に入り、相談の行は会話の発言にも本文にも数えない
    func testConsult() {
        let history = [TalkLine(who: "native", text: "How's work?"), TalkLine(who: "me", text: "前に聞いたこと", tag: "consult")]
        let m = Talk.userMessage(request: .hint(wish: "同僚に聞くしかなくて困ってる"), history: history, language: .enUS)
        XCTAssertTrue(m.contains("こっそり相談"))
        XCTAssertTrue(m.contains("同僚に聞くしかなくて困ってる"))
        XCTAssertTrue(m.contains("Sam には聞こえていない"))
        // 声だけの相談でも相談の指示になる。空の hint は従来の「2 つ」
        XCTAssertTrue(Talk.userMessage(request: .hint(), history: [], language: .enUS, hasAudio: true).contains("添付の音声が相談の中身"))
        XCTAssertTrue(Talk.userMessage(request: .hint(), history: [], language: .enUS).contains("2 つ"))
        let lines = [TalkLine(who: "native", text: "Hi"), TalkLine(who: "me", text: "困ってると言いたい", tag: "consult"),
                     TalkLine(who: "tora", text: "こう言いな", sub: "hint", asks: [Ask(said: "困ってる", ways: ["I'm stuck."])]),
                     TalkLine(who: "me", text: "I'm stuck.")]
        let t = Talk.tally(lines, nativeLanguageIsJapanese: true)
        XCTAssertEqual(t.alone + t.helped, 1)
        XCTAssertEqual(t.helped, 1)
        XCTAssertEqual(Talk.makeSession(id: "x", lines: lines, good: "", engine: "talk-cloud").transcript, "I'm stuck.")
    }

    // 言い淀み: stuck を読み、補ってもらった発言は「助けてもらった」に数える。指示文に (f)(g) がある
    func testStuck() {
        let t = Talk.parse(#"{"heard":"I have to... um... ask, uh","reply":"Oh, you have to ask him?","help":"聞かなきゃならねえって言いたいんだろ？","asks":[{"said":"聞かないといけない","ways":["I have to ask him."]}],"stuck":true}"#)
        XCTAssertEqual(t?.stuck, true)
        XCTAssertEqual(Talk.parse(#"{"heard":"Hi","reply":"Hey"}"#)?.stuck, false)
        let lines = [TalkLine(who: "me", text: "I have to... um", tag: "stuck"), TalkLine(who: "me", text: "It was fun.")]
        let tally = Talk.tally(lines, nativeLanguageIsJapanese: true)
        XCTAssertEqual(tally.helped, 1); XCTAssertEqual(tally.alone, 1)
        let sys = Talk.system(language: .enUS)
        XCTAssertTrue(sys.contains("言い淀み")); XCTAssertTrue(sys.contains("雑談への参加")); XCTAssertTrue(sys.contains("\"stuck\""))
    }
}
