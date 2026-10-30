import XCTest
@testable import HitorigotoCore

final class ExamTests: XCTestCase {

    func testDrawAvoidsRecent() {
        let recent = Array(ExamTopics.all.prefix(10))
        let five = ExamTopics.draw(5, avoiding: recent)
        XCTAssertEqual(five.count, 5)
        XCTAssertEqual(Set(five).count, 5)
        XCTAssertTrue(five.allSatisfy { !recent.contains($0) })
        // 全部避けても 5 つは出る
        XCTAssertEqual(ExamTopics.draw(5, avoiding: ExamTopics.all).count, 5)
    }

    func testParseSpeechTurn() {
        let raw = #"{"heard":"I agree.","pronunciation":{"score":12,"comment":"よし"},"note":"短い","question":"Why?"}"#
        let t = Exam.parseTurn(raw)
        XCTAssertEqual(t?.heard, "I agree.")
        XCTAssertEqual(t?.question, "Why?")
        XCTAssertEqual(t?.pronunciation?.score, 10)   // 10 点で頭打ち
        XCTAssertNil(Exam.parseTurn("not json"))
    }

    func testParseResult() {
        let raw = #"""
        ```json
        {"scores":{"speech":{"score":6,"comment":"a"},"interaction":{"score":"7","comment":"b"},"grammar":{"score":5.6,"comment":"c"}},
         "summary":"総評","fixes":[{"type":"grammar","original":"government should","suggestion":"the government should","reason":"the"},{"type":"x","original":"same","suggestion":"same"}],
         "model":"I firmly believe...","phrases":[{"said":"妨げる","ways":["stifle"]},{"said":"空","ways":[]}]}
        ```
        """#
        let r = Exam.parseResult(raw, pronunciation: ExamScore(key: "pronunciation", score: 8, comment: "d"))
        XCTAssertEqual(r?.scores.map(\.key), ["speech", "interaction", "grammar", "pronunciation"])
        XCTAssertEqual(r?.scores.map(\.score), [6, 7, 6, 8])
        XCTAssertEqual(r?.total, 27)
        XCTAssertEqual(r?.likelyPass, false)   // 28 点から
        XCTAssertEqual(r?.fixes.count, 1)      // 同じものへの直しは外す
        XCTAssertEqual(r?.phrases.count, 1)
        XCTAssertTrue(Exam.recordGood(r!).hasPrefix("英検 1 級 2 次の練習 27/40"))
    }

    func testMessageHasHistoryAndNoQuestionOnLast() {
        let h = [TalkLine(who: "me", text: "speech", tag: "exam_speech"), TalkLine(who: "native", text: "Why?")]
        let m = Exam.userMessage(.answer(topic: "T", last: true), history: h)
        XCTAssertTrue(m.contains("学習者のスピーチ: speech"))
        XCTAssertTrue(m.contains("面接官: Why?"))
        XCTAssertTrue(m.contains("\"question\" は空"))
    }
}
