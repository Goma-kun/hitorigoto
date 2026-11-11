import XCTest
@testable import HitorigotoCore

final class AssessTests: XCTestCase {

    func testCEFRScaleAndCSE() {
        XCTAssertEqual(CEFRScale.value("b2+"), 4.5)
        XCTAssertEqual(CEFRScale.label(4.4), "B2+")
        XCTAssertEqual(CEFRScale.cse(5.0), 613)   // C1 の入口（英検公式）
        XCTAssertEqual(CEFRScale.cse(4.0), 519)
        XCTAssertEqual(CEFRScale.cse(4.5), 566)   // B2 と C1 の中間
        XCTAssertEqual(CEFRScale.cse(0.5), 362)   // 下は A1 で止める
        XCTAssertLessThan(CEFRScale.cse(4.9), AssessGoal.g1.passCSE + 20)
    }

    func testMetrics() {
        let text = "Um, I think that, uh, the government should do more. " + String(repeating: "people need support and time ", count: 20)
        let m = Assess.metrics(transcript: text, seconds: 60, fixes: 3)
        XCTAssertEqual(m.fillers, 2)
        XCTAssertEqual(m.words, 8 + 100)
        XCTAssertEqual(m.wpm!, 108, accuracy: 0.5)
        XCTAssertEqual(m.fixesPer100, 2.8, accuracy: 0.05)
        XCTAssertGreaterThan(m.mattr, 0)
        XCTAssertLessThan(m.mattr, 0.3)   // 同じ語の繰り返しなので低い
        XCTAssertFalse(Assess.measurable(words: 99, seconds: 120))
        XCTAssertFalse(Assess.measurable(words: 150, seconds: 59))
        XCTAssertTrue(Assess.measurable(words: 150, seconds: 60))
    }

    func testParseDropsAxesWithoutEvidenceAndAudioOnlyAxesForText() {
        let raw = """
        {"axes":[{"key":"range","level":"B2+","evidence":"a pressing issue"},
                 {"key":"accuracy","level":"C1","evidence":""},
                 {"key":"fluency","level":"B2","evidence":"so, um, basically"},
                 {"key":"coherence","level":"b1+","evidence":"first of all"},
                 {"key":"pronunciation","level":"Z9","evidence":"x"},
                 {"key":"range","level":"C2","evidence":"dup"}]}
        """
        let a = Assess.parse(raw, audio: true)!
        XCTAssertEqual(a.map(\.key), ["range", "fluency", "coherence"])
        XCTAssertEqual(a[2].level, "B1+")
        let t = Assess.parse(raw, audio: false)!
        XCTAssertEqual(t.map(\.key), ["range", "coherence"])
        XCTAssertNil(Assess.parse("not json", audio: true))
    }

    private func axes(_ levels: [String: String]) -> [AssessAxis] {
        Assess.axisKeys.compactMap { k in levels[k].map { AssessAxis(key: k, level: $0, evidence: "e") } }
    }

    func testCheckFlagsDisagreementWithCounts() {
        let m = AssessMetrics(words: 300, seconds: 120, fixesPer100: 12, mattr: 0.7, fillers: 3)
        // 100 語に 12 か所直したのに正確さ C1 → 食い違い
        XCTAssertNotNil(Assess.check(axes: axes(["accuracy": "C1"]), metrics: m))
        XCTAssertNil(Assess.check(axes: axes(["accuracy": "B1"]), metrics: m))
        // 1 分 150 語なのに流暢さ C1 は問題なし、1 分 60 語で C1 は食い違い
        let slow = AssessMetrics(words: 120, seconds: 120, fixesPer100: 2, mattr: 0.7, fillers: 3)
        XCTAssertNotNil(Assess.check(axes: axes(["fluency": "C1"]), metrics: slow))
    }

    private func session(_ id: String, _ overall: String, unstable: String? = nil, mode: String = "audio") -> Session {
        var s = Session(id: id)
        var a = Assessment(axes: axes(["range": overall, "accuracy": overall, "coherence": overall]),
                           metrics: AssessMetrics(words: 200, seconds: 100, fixesPer100: 3, mattr: 0.7, fillers: 0), mode: mode)
        a.unstable = unstable
        s.assessment = a
        return s
    }

    func testSummaryNeedsThreeAndTrimsExtremes() {
        let now = ISO8601DateFormatter().date(from: "2026-11-12T00:00:00Z")!
        var ss = [session("2026-11-11T00:00:00.000Z", "B2"), session("2026-11-10T00:00:00.000Z", "B2+")]
        XCTAssertNil(Assess.summary(ss, now: now))
        XCTAssertEqual(Assess.usableCount(ss, now: now), 2)
        ss.append(session("2026-11-09T00:00:00.000Z", "C1", unstable: "x"))   // 外す
        XCTAssertNil(Assess.summary(ss, now: now))
        ss.append(session("2026-11-08T00:00:00.000Z", "B1"))
        ss.append(session("2026-11-07T00:00:00.000Z", "C1"))
        ss.append(session("2026-11-06T00:00:00.000Z", "B2"))
        ss.append(session("2026-11-05T00:00:00.000Z", "A2"))   // 6 件目（5 件を超えるので使わない）
        ss.append(session("2026-09-01T00:00:00.000Z", "C2"))   // 30 日より前
        let sum = Assess.summary(ss, now: now)!
        XCTAssertEqual(sum.count, 5)
        XCTAssertEqual(sum.center, 4.0)            // B1 B2 B2 B2+ C1 の中央
        XCTAssertEqual(sum.low, 4.0); XCTAssertEqual(sum.high, 4.5)   // 両端を外した幅
        XCTAssertTrue(sum.hasAudio)
        XCTAssertEqual(sum.cseRange(cap: 850).low, 519)
        XCTAssertEqual(sum.cseRange(cap: 540).high, 540)   // 級の満点より上は出さない
    }

    func testFoldKeepsAssessment() {
        var ss: [Session] = (0..<3).map { session("2026-11-1\($0)T00:00:00.000Z", "B2") }
        ss[2].transcript = "long text"
        let folded = Logic.foldSessions(ss, keepFull: 1, keepTotal: 10)
        XCTAssertEqual(folded[2].folded, true)
        XCTAssertNil(folded[2].transcript)
        XCTAssertNotNil(folded[2].assessment)
    }

    func testMergeKeepsAssessmentFromEitherSide() {
        var a = Session(id: "2026-11-12T00:00:00.000Z", transcript: "hello", issues: [Issue(type: "grammar", suggestion: "x")])
        let b = a
        a.assessment = session(a.id, "B2").assessment
        XCTAssertNotNil(Sync.mergeSession(a, b).assessment)
        XCTAssertNotNil(Sync.mergeSession(b, a).assessment)
        XCTAssertEqual(Sync.mergeSession(a, b), Sync.mergeSession(b, a))
        // 畳んだ側が勝っても、推定は残る
        var f = Session(id: a.id, folded: true)
        f.assessment = nil
        XCTAssertNotNil(Sync.mergeSession(f, a).assessment)
    }

    func testSessionDecodesWithoutAssessmentAndRoundTrips() throws {
        let old = #"{"id":"2026-10-01T00:00:00.000Z","issues":[]}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(Session.self, from: old).assessment)
        let s = session("2026-11-12T00:00:00.000Z", "C1")
        let back = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}
