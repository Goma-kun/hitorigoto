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
        XCTAssertTrue(Talk.userMessage(request: .hint, history: history, language: .enUS).contains("2 つ"))
        XCTAssertTrue(Talk.userMessage(request: .close, history: history, language: .enUS).contains("\"good\""))
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
            TalkLine(who: "native", text: "Bye!"),
        ]
        let s = Talk.makeSession(id: "2026-10-28T10:00:00.000Z", lines: lines, good: "上等だ", engine: "talk-gemini")
        XCTAssertEqual(s.transcript, "I ate 焼き芋.\nYes, very sweet.\nMy cat likes it too.", "記録の本文は学習者の発言だけ")
        XCTAssertEqual(s.correctedText, "I had a baked sweet potato.\nYes, very sweet.\nMy cat likes it too.")
        XCTAssertEqual(s.issues.count, 1, "同じ直しは 1 回")
        XCTAssertEqual(s.asks?.map(\.said), ["焼き芋", "猫も好き"])
        XCTAssertEqual(s.good, "上等だ")
        XCTAssertEqual(s.talk?.count, 8)

        let t = Talk.tally(lines, nativeLanguageIsJapanese: true)
        XCTAssertEqual(t.alone, 1, "英語だけで言えたのは Yes, very sweet. の 1 回")
        XCTAssertEqual(t.helped, 2, "日本語が混ざった 1 回と、ヒントのあとの 1 回")
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
}
