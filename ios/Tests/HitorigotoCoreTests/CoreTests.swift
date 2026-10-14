import XCTest
@testable import HitorigotoCore

/// 移植そのものの突き合わせは ../test/parity_swift_test.mjs（JS 版と実際に比べる）が担う。
/// ここには「Swift 側だけで壊れうるところ」を置く
final class CoreTests: XCTestCase {

    func testDayArithmetic() {
        XCTAssertEqual(PhraseLogic.addDays("2026-09-27", 7), "2026-10-04")
        XCTAssertEqual(PhraseLogic.addDays("2026-12-31", 1), "2027-01-01")
        XCTAssertEqual(PhraseLogic.addDays("2028-02-28", 1), "2028-02-29", "うるう年")
        XCTAssertEqual(PhraseLogic.daysBetween("2026-09-27", "2026-10-04"), 7)
        XCTAssertEqual(PhraseLogic.daysBetween("2026-10-04", "2026-09-27"), -7)
    }

    func testPromptsDerived() {
        XCTAssertTrue(Prompts.system.contains("音声は届いていません"))
        XCTAssertTrue(Prompts.audio.contains("## 重要な前提（音声モード）"))
        XCTAssertFalse(Prompts.audio.contains("音声は届いていません"))
        XCTAssertTrue(Prompts.audio.contains("\"transcript\""))
        XCTAssertTrue(Prompts.audio.contains("\"targets\""))
        XCTAssertEqual(Prompts.audio.components(separatedBy: "## 出力").count - 1, 1)
        XCTAssertEqual(Prompts.audio.components(separatedBy: "## 重要な前提").count - 1, 1)
    }

    /// 拡張機能の書き出しファイル（実物と同じ形）が読める
    func testImportExtensionExport() throws {
        let json = """
        {"format":"hitorigoto-english-v1","exported_at":"2026-09-27T00:00:00.000Z",
         "sessions":[{"id":"2026-09-26T12:00:00.000Z","transcript":"I go to park.","corrected_text":"I went to the park.",
                      "issues":[{"type":"grammar","original":"I go to park","suggestion":"I went to the park","reason":"r"}],
                      "good":"g","asr_transcript":"I go to bark.","pronunciation":[{"said":"park","heard_as":"bark","note":"n"}]},
                     {"id":"2026-08-01T00:00:00.000Z","folded":true,"issues":[{"type":"grammar","suggestion":"went"}]}],
         "recurring":[{"text":"a → b","count":2,"last_seen":"2026-09-01"}],
         "phrases":[{"id":"p1","phrase":"under the hood","meaning":"裏側","kind":"phrase","source":"manual","added":"2026-09-12",
                     "due":"2026-09-13","hits":0,"status":"active","history":[{"d":"2026-09-12","r":"miss"}]}]}
        """
        let r = try Merge.importJson(Data(json.utf8), into: Snapshot())
        XCTAssertEqual(r.addedSessions, 2)
        XCTAssertEqual(r.snapshot.sessions.first?.pronunciation?.first?.heardAs, "bark")
        XCTAssertEqual(r.snapshot.sessions.last?.folded, true)
        XCTAssertEqual(r.snapshot.phrases.first?.due, "2026-09-13")
        // 同じファイルをもう一度読んでも増えない
        let again = try Merge.importJson(Data(json.utf8), into: r.snapshot)
        XCTAssertEqual(again.addedSessions, 0)
        XCTAssertEqual(again.snapshot.phrases.count, 1)
        // 書き出して読み直せる（キー名が JS と同じ）
        let out = try JSONEncoder().encode(ExportFile(snapshot: r.snapshot))
        let s = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(s.contains("\"corrected_text\"") && s.contains("\"heard_as\"") && s.contains("\"last_seen\""))
        XCTAssertThrowsError(try Merge.importJson(Data("{\"format\":\"x\"}".utf8), into: Snapshot()))
    }

    func testSnapshotStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hg-test-\(UUID().uuidString).json")
        let store = SnapshotStore(url: url)
        var snap = Snapshot()
        snap.phrases = [PhraseLogic.makePhrase(phrase: "tweak", meaning: "少し直す", today: "2026-09-27")!]
        snap.today = Today(date: "2026-09-27", ids: [snap.phrases[0].id], results: [snap.phrases[0].id: TodayResult(r: "hit", judge: "ai")])
        try store.save(snap)
        let back = try store.load()
        XCTAssertEqual(back.phrases.first?.phrase, "tweak")
        XCTAssertEqual(back.today?.results.values.first?.r, "hit")
        try? FileManager.default.removeItem(at: url)
    }

    func testDetectRealExamples() {
        XCTAssertEqual(PhraseLogic.detect("hog someone's food", in: "the kitten was hogging his food").exact, true)
        XCTAssertEqual(PhraseLogic.detect("he's on the mend", in: "he is on the mat now").used, false)
        let d = PhraseLogic.detect("connect the dots", in: "and then it connected it's a dot")
        XCTAssertEqual([d.used, d.exact], [true, false])
    }

    // MARK: - 前に言えなかった表現の候補

    private func sess(_ id: String, _ issues: [Issue], asks: [Ask]? = nil) -> Session {
        Session(id: id, issues: issues, asks: asks)
    }

    func testCandidatesCollectAndPick() {
        let sessions = [
            sess("2026-10-15T00:30:00.000Z", [Issue(type: "grammar", original: "I drink a night", suggestion: "I drink at night")]),
            sess("2026-10-08T01:00:00.000Z", [Issue(type: "phrasing", original: "provide him that information", suggestion: "provided him with that information", reason: "r1"),
                                              Issue(type: "grammar", original: "him", suggestion: "him")]),
            sess("2026-10-12T01:00:00.000Z", [Issue(type: "vocabulary", original: "function", suggestion: "feature")],
                 asks: [Ask(said: "その気力がなかった", ways: ["I didn't have it in me", "x"])]),
            sess("2026-10-10T01:00:00.000Z", [Issue(type: "vocabulary", original: "function", suggestion: "feature.")]),
            sess("2026-09-01T01:00:00.000Z", [Issue(type: "grammar", suggestion: "went")]),   // original の無い古い記録
        ]
        let phrases = [PhraseCard(id: "p", phrase: "I drink at night", added: "2026-10-15", due: "2026-10-15")]
        let items = Candidates.collect(sessions, phrases: phrases)
        let keys = Set(items.map(\.key))
        XCTAssertFalse(keys.contains("i drink at night"), "表現集にあるものは出さない")
        XCTAssertFalse(keys.contains("him"), "直す前と同じものは出さない")
        XCTAssertFalse(keys.contains("went"), "original の無い記録は出さない")
        XCTAssertEqual(items.first { $0.key == "feature" }?.count, 2, "末尾の句点を無視してまとめる")
        XCTAssertEqual(items.first { $0.key == "feature" }?.date, "2026-10-12", "新しい日の文脈を残す")
        XCTAssertEqual(items.first { $0.origin == "ask" }?.said, "その気力がなかった")

        let picked = Candidates.pick(items, today: "2026-10-15", states: [:], limit: 2)
        XCTAssertEqual(picked.map(\.key), ["feature", "i didn't have it in me"],
                       "何度も直されたもの → ちょうど 3・7 日前の話（同点なら新しい順）")

        var states: [String: CandidateState] = [:]
        states["feature"] = Candidates.snooze(nil, today: "2026-10-15")
        XCTAssertEqual(states["feature"]?.until, "2026-10-18")
        XCTAssertEqual(Candidates.snooze(states["feature"], today: "2026-10-18").until, "2026-10-25", "2 回目は 7 日")
        states["provided him with that information"] = Candidates.dismiss(nil)
        let after = Candidates.pick(items, today: "2026-10-15", states: states, limit: 5).map(\.key)
        XCTAssertFalse(after.contains("feature"))
        XCTAssertFalse(after.contains("provided him with that information"))
        XCTAssertTrue(Candidates.pick(items, today: "2026-10-18", states: states, limit: 5).map(\.key).contains("feature"), "寝かせ明けで戻る")
    }

    func testSnapshotWithoutCandidatesDecodes() throws {
        let s = try JSONDecoder().decode(Snapshot.self, from: Data(#"{"sessions":[],"recurring":[],"phrases":[]}"#.utf8))
        XCTAssertTrue(s.candidates.isEmpty)
    }
}
