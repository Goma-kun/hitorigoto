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
        let p = Voice.parts(for: lines, partner: Partners.list(.enUS)[0])
        XCTAssertEqual(p.map(\.speaker), [Voice.tora, Voice.native])
        XCTAssertEqual(p[0].text, "焼き芋はこう言うんでえ。 a baked sweet potato")
        XCTAssertFalse(p[0].style.isEmpty)
        // 一言の中に言い方が入っていれば重ねない
        let q = Voice.parts(for: [TalkLine(who: "tora", text: "a baked sweet potato って言いな", asks: [Ask(said: "焼き芋", ways: ["a baked sweet potato"])])], partner: Partners.list(.enUS)[0])
        XCTAssertEqual(q.first?.text, "a baked sweet potato って言いな")
        // 同じ人が続いたら 1 片に
        let r = Voice.parts(for: [TalkLine(who: "native", text: "A."), TalkLine(who: "native", text: "B?")], partner: Partners.list(.enUS)[0])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.text, "A. B?")
        XCTAssertEqual(Voice.voices(partner: Partners.list(.enUS)[0])[Voice.tora], Voice.defaultToraVoice)
        XCTAssertEqual(Voice.voices(partner: Partners.find("jim", language: .enUS), tora: "Algenib")[Voice.native], "en-us-olin")
        XCTAssertEqual(Voice.voices(partner: Partners.list(.enUS)[0], tora: "nonsense")[Voice.tora], Voice.defaultToraVoice)
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

    // 被り: 遮った発言とどこまで聞いたかが指示文に入る。見本のターンは banter を読む（who の揺れも吸収）
    func testOverlap() {
        let m = Talk.userMessage(request: .speak, history: [], language: .enUS, hasAudio: true,
                                 cutIn: CutIn(line: "Do you usually grab one on your way home?", heard: 0.3, first: true))
        XCTAssertTrue(m.contains("被り")); XCTAssertTrue(m.contains("30%")); XCTAssertTrue(m.contains("初めての被り"))
        XCTAssertTrue(Talk.userMessage(request: .speak, history: [], language: .enUS, hasAudio: true, cutIn: CutIn(line: "x", heard: 0.5, first: false)).contains("2 回目以降"))
        XCTAssertTrue(Talk.userMessage(request: .speak, history: [], language: .enUS, hasAudio: true, overlapDemo: true).contains("譲り合いの見本"))
        XCTAssertFalse(Talk.userMessage(request: .speak, history: [], language: .enUS, hasAudio: true).contains("被り"))
        let t = Talk.parse(#"{"heard":"Yes","reply":"Okay.","banter":[{"who":"Sam","text":"Oh—sorry, Tora, go ahead.","sub":"どうぞ"},{"who":"tora","text":"いやいや Sam が先だ","sub":"x"},{"who":"native","text":""}]}"#)
        XCTAssertEqual(t?.banter.map(\.who), ["native", "tora"])
        XCTAssertEqual(t?.banter.first?.sub, "どうぞ")
        XCTAssertEqual(t?.banter.last?.sub, "")
        XCTAssertEqual(t?.banter.first?.tag, "banter")
        // 被りの行は普通の発言として数える・声は banter の順で読む
        XCTAssertEqual(Talk.tally([TalkLine(who: "me", text: "Sorry, go ahead.", tag: "cut_in")], nativeLanguageIsJapanese: true).alone, 1)
        let parts = Voice.parts(for: (t?.banter ?? []) + [TalkLine(who: "native", text: "So anyway?")], partner: Partners.list(.enUS)[0])
        XCTAssertEqual(parts.map(\.speaker), [Voice.native, Voice.tora, Voice.native])
        XCTAssertTrue(Talk.system(language: .enUS).contains("## 被り"))
    }

    // 相手役: id で引ける・無ければ既定・人物像が指示文に入る
    func testPartners() {
        XCTAssertEqual(Partners.list(.enUS).count, 6)
        XCTAssertEqual(Partners.find("taylor", language: .enUS).name, "Taylor")
        XCTAssertEqual(Partners.find("", language: .enUS).name, "Sam")
        XCTAssertEqual(Talk.nativeName(.esES), "Lucía")
        let sys = Talk.system(language: .enUS, partner: Partners.find("elizabeth", language: .enUS))
        XCTAssertTrue(sys.contains("Elizabeth, a 38-year-old woman from the Northwest"))
        XCTAssertTrue(Talk.userMessage(request: .open(topic: "x"), history: [], language: .enUS, partner: Partners.find("nick", language: .enUS)).contains("Nick が挨拶"))
    }

    // 同時に話し出す見本: cut の行は collide になり、通常の読み上げから外れて別に作る。WAV の重ね・つなぎ
    func testCollide() {
        let t = Talk.parse(#"{"heard":"Yes","reply":"Okay.","banter":[{"who":"native","text":"Oh, I was gonna—","cut":true},{"who":"tora","text":"そういやよ—","cut":true},{"who":"native","text":"Sorry, go ahead."}]}"#)
        XCTAssertEqual(t?.banter.map(\.tag), ["collide", "collide", "banter"])
        let p = Partners.list(.enUS)[0]
        XCTAssertEqual(Voice.collideParts(for: t!.banter, partner: p).map(\.speaker), [Voice.native, Voice.tora])
        XCTAssertEqual(Voice.parts(for: t!.banter, partner: p).map(\.text), ["Sorry, go ahead."])
        // 2 秒の音と 2 秒の音を 0.35 秒ずらして 1.3 秒ずつで切る → 1.65 秒
        let tone = [Int16](repeating: 1000, count: Voice.sampleRate * 2)
        let w = Voice.wav(pcm: tone.withUnsafeBufferPointer { Data(buffer: $0) }, sampleRate: Voice.sampleRate)
        XCTAssertEqual(Voice.pcm(w).count, Voice.sampleRate * 2)
        let c = Voice.collide(w, w)
        XCTAssertEqual(Voice.pcm(c).count, Int(1.65 * Double(Voice.sampleRate)))
        XCTAssertEqual(Voice.pcm(c)[Int(0.5 * Double(Voice.sampleRate))], 1700)   // 重なった所は 0.85 倍ずつの和
        XCTAssertEqual(Voice.pcm(Voice.join([w, w], gap: 0.5)).count, Voice.sampleRate * 4 + Voice.sampleRate / 2)
    }
    // トラさんは学習者に合わせて話す言語でも返す: help_sub が訳として残り、端末の声は字で言語を決める
    func testToraLanguage() {
        let t = Talk.parse(#"{"heard":"How about you, Tora?","reply":"Oh nice!","help":"Me? I'm right here in Tokyo with you, kid.","help_sub":"わしか？おめえと同じ東京にいるぜ。"}"#)
        XCTAssertEqual(t?.helpSub, "わしか？おめえと同じ東京にいるぜ。")
        let line = TalkLine(who: "tora", text: t!.help, note: t!.helpSub)
        let back = try! JSONDecoder().decode(TalkLine.self, from: try! JSONEncoder().encode(line))
        XCTAssertEqual(back.note, line.note)
        XCTAssertEqual(Voice.fallbackLanguage(for: "わしか？東京だ。"), "ja-JP")
        XCTAssertNil(Voice.fallbackLanguage(for: "Me? Tokyo, kid."))
        let sys = Talk.system(language: .enUS)
        XCTAssertTrue(sys.contains("トラさん自身が答える"))
        XCTAssertTrue(sys.contains("help_sub"))
    }
    // 復習の音声: 台本の指示文に記録の中身が入る・読み取り・片の区切り・ファイル名
    func testRecap() {
        let p = Partners.find("taylor", language: .enUS)
        let lines = [TalkLine(who: "native", text: "Hey! Did you just wake up?"),
                     TalkLine(who: "me", text: "Yes, I drink coffee.", sub: "Yes, I'm drinking coffee.", fixes: [Issue(type: "grammar", original: "I drink", suggestion: "I'm drinking", reason: "今やってる最中だ")]),
                     TalkLine(who: "tora", text: "こう言ってみな", asks: [Ask(said: "眠い", ways: ["I'm sleepy."])])]
        let session = Talk.makeSession(id: "2026-10-29T00:00:00.000Z", lines: lines, good: "よく言えた", engine: "probe")
        let msg = Recap.userMessage(session: session, partner: p, language: .enUS)
        XCTAssertTrue(msg.contains("Taylor: Hey!"))
        XCTAssertTrue(msg.contains("「眠い」 → I'm sleepy."))
        XCTAssertTrue(msg.contains("I drink → I'm drinking"))
        XCTAssertTrue(msg.contains("よく言えた"))
        XCTAssertTrue(Recap.system(language: .enUS, partner: p).contains("2 回"))
        let script = Recap.parse(#"{"lines":[{"who":"tora","text":"復習だ"},{"who":"native","text":"I'm sleepy."},{"who":"native","text":"I'm sleepy."},{"who":"tora","text":"眠いときはこれだ"}]}"#)
        XCTAssertEqual(script.map(\.who), ["tora", "native", "native", "tora"])
        let chunks = Recap.chunks(script, partner: p)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].map(\.speaker), [Voice.tora, Voice.native, Voice.tora])   // 同じ人の連続はまとまる
        XCTAssertEqual(chunks[0][1].text, "I'm sleepy. I'm sleepy.")
        XCTAssertEqual(Recap.chunks(script, partner: p, maxChars: 10).count, 4)
        XCTAssertEqual(Recap.fileName(for: session.id), "recap_2026-10-29T00-00-00.000Z.m4a")
        XCTAssertTrue(Recap.parse("x").isEmpty)
    }
    // 自分や友人の声: 組み込みの後ろに並ぶ・id で引ける・消えたら既定に戻る・人物像は年齢や出身を作らない・複製の声の見分け・同意の文
    func testCustomVoices() {
        let mine = Voice.customPartner(id: "abc", name: "ヒロ", female: false, blurb: "大学の友人", voice: "voicekey_xyz")
        XCTAssertEqual(mine.id, "custom:abc")
        XCTAssertTrue(mine.isCustom)
        XCTAssertFalse(Partners.find("sam", language: .enUS).isCustom)
        let all = Partners.list(.enUS, custom: [mine])
        XCTAssertEqual(all.last?.id, "custom:abc")
        XCTAssertEqual(all.count, Partners.builtin(.enUS).count + 1)
        XCTAssertEqual(Partners.find("custom:abc", language: .enUS, custom: [mine]).voice, "voicekey_xyz")
        XCTAssertEqual(Partners.find("custom:abc", language: .enUS).id, "sam")     // 消した声を選んだままなら既定
        XCTAssertEqual(mine.persona, "ヒロ, a man who is a friend of the learner. Friendly, relaxed and natural, talks like a close friend.")
        XCTAssertFalse(mine.persona.contains("0-year-old"))
        XCTAssertTrue(Voice.isReplicated("voicekey_abc"))
        XCTAssertTrue(Voice.isReplicated("voice_abc"))
        XCTAssertFalse(Voice.isReplicated("Puck"))
        XCTAssertFalse(Voice.isReplicated("en-us-olin"))
        XCTAssertEqual(Voice.voices(partner: mine)[Voice.native], "voicekey_xyz")
        // 同意の文は Google の指定どおり（一字も変えない）
        XCTAssertEqual(Voice.consentStatement("ja-JP"), "私はこの音声の所有者であり、Googleがこの音声を使用して音声合成モデルを作成することを承認します。")
        XCTAssertEqual(Voice.consentStatement("en-US"), "I am the owner of this voice and I consent to Google using this voice to create a synthetic voice model.")
        XCTAssertEqual(Voice.consentStatement("fr-FR"), Voice.consentStatement("en-US"))
        // 鍵は返りのどこにあっても拾う
        XCTAssertEqual(GeminiClient.findVoiceKey(in: ["replicated_voice": ["key": "voicekey_q1", "model": "x"]]), "voicekey_q1")
        XCTAssertEqual(GeminiClient.findVoiceKey(in: ["replicatedVoice": ["id": "voice_77"]]), "voice_77")
        XCTAssertNil(GeminiClient.findVoiceKey(in: ["name": "Puck"]))
    }
}
