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
}
