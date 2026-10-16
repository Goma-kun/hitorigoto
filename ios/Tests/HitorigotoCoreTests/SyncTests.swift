import XCTest
@testable import HitorigotoCore

/// iCloud 同期の混ぜ方。**どちらの端末で混ぜても同じ記録になる**ことがいちばん大事
final class SyncTests: XCTestCase {

    /// A の全部を B に、B の全部を A に混ぜる（2 台が互いの記録を受け取ったときと同じ）
    private func exchange(_ a: Snapshot, _ b: Snapshot) -> (Snapshot, Snapshot) {
        var a2 = a, b2 = b
        for it in Sync.items(b).values.sorted(by: { $0.name < $1.name }) { a2 = Sync.merge(a2, it) }
        for it in Sync.items(a).values.sorted(by: { $0.name < $1.name }) { b2 = Sync.merge(b2, it) }
        return (a2, b2)
    }

    /// 2 台が落ち着くまでやり取りする（送る → 混ぜる → 混ぜた結果が違えば送り返す）。3 往復以内に収まること
    private func converge(_ a: Snapshot, _ b: Snapshot, file: StaticString = #filePath, line: UInt = #line) -> (Snapshot, Snapshot) {
        var (x, y) = (a, b)
        for _ in 0..<3 {
            (x, y) = exchange(x, y)
            if Sync.items(x).mapValues(\.hash) == Sync.items(y).mapValues(\.hash) { return (x, y) }
        }
        XCTFail("3 往復で揃わなかった", file: file, line: line)
        return (x, y)
    }

    private func card(_ id: String, _ phrase: String, _ history: [PhraseHistory], added: String = "2026-10-01") -> PhraseCard {
        PhraseLogic.rebuild(PhraseCard(id: id, phrase: phrase, added: added, due: added, history: history))
    }

    private var mac: Snapshot {
        Snapshot(
            sessions: [Session(id: "2026-10-15T10:00:00.000Z", transcript: "mac"), Session(id: "2026-10-10T10:00:00.000Z", transcript: "both")],
            recurring: [Recurring(text: "go → went", count: 3, lastSeen: "2026-10-15"), Recurring(text: "a → the", count: 1, lastSeen: "2026-10-01")],
            phrases: [card("2026-10-01-aaaaaa", "on the mend", [PhraseHistory(d: "2026-10-02", r: "hit")]),
                      card("2026-10-03-macmac", "Only mac", [])],
            today: Today(date: "2026-10-16", ids: ["2026-10-01-aaaaaa"], results: ["2026-10-01-aaaaaa": TodayResult(r: "hit", judge: "ai")]),
            candidates: ["x": CandidateState(until: "2026-10-20", snoozes: 1)])
    }

    private var iphone: Snapshot {
        Snapshot(
            sessions: [Session(id: "2026-10-12T10:00:00.000Z", transcript: "iphone"), Session(id: "2026-10-10T10:00:00.000Z", transcript: "both")],
            recurring: [Recurring(text: "Go → went", count: 5, lastSeen: "2026-10-12")],
            // 同じ表現を iPhone でも別に足していた（id が違う）。文言の大文字小文字も違う
            phrases: [card("2026-10-02-zzzzzz", "On the mend", [PhraseHistory(d: "2026-10-05", r: "partial")])],
            today: Today(date: "2026-10-16", ids: ["2026-10-02-zzzzzz"], results: ["2026-10-02-zzzzzz": TodayResult(r: "miss", judge: "manual")]),
            candidates: ["x": CandidateState(until: "2026-10-18", snoozes: 2, dismissed: true)])
    }

    func testBothDevicesEndUpTheSame() {
        let (a, b) = converge(mac, iphone)
        XCTAssertEqual(a.sessions.map(\.id), ["2026-10-15T10:00:00.000Z", "2026-10-12T10:00:00.000Z", "2026-10-10T10:00:00.000Z"])
        XCTAssertEqual(Set(a.phrases.map(\.phrase)), Set(b.phrases.map(\.phrase)))
        XCTAssertEqual(a.phrases.count, 2, "同じ表現は 1 枚にまとまる")
        XCTAssertEqual(Sync.items(a).mapValues(\.hash), Sync.items(b).mapValues(\.hash), "2 台の中身が一字一句同じ")
    }

    func testMergingAgainChangesNothing() {
        let (a, b) = converge(mac, iphone)
        let (a2, b2) = exchange(a, b)
        XCTAssertEqual(Sync.items(a2).mapValues(\.hash), Sync.items(a).mapValues(\.hash))
        XCTAssertEqual(Sync.items(b2).mapValues(\.hash), Sync.items(b).mapValues(\.hash))
    }

    func testPhraseHistoriesAreCombined() {
        let (a, _) = converge(mac, iphone)
        let c = a.phrases.first { PhraseLogic.phraseKey($0.phrase) == "on the mend" }!
        XCTAssertEqual(c.id, "2026-10-01-aaaaaa", "id は小さい方に揃う")
        XCTAssertEqual(c.history.map(\.r), ["hit", "partial"], "2 台の練習の記録が両方残る")
        XCTAssertEqual(a.today?.ids.first, "2026-10-01-aaaaaa", "今日の表現も揃えた id を指す")
        XCTAssertEqual(a.today?.results["2026-10-01-aaaaaa"]?.judge, "manual", "手で直した判定が勝つ")
        XCTAssertEqual(PhraseLogic.pickToday(a.phrases, today: "2026-10-16", fixedIds: a.today?.ids ?? []).filter { $0.id.hasPrefix("2026-10-0") && PhraseLogic.phraseKey($0.phrase) == "on the mend" }.count, 1,
                       "古い id が残っていても、今日の表現に同じカードが 2 回出ない")
    }

    func testRecurringAndCandidates() {
        let (a, _) = converge(mac, iphone)
        let go = a.recurring.first { Merge.normKey($0.text) == "go → went" }!
        XCTAssertEqual(go.count, 5)
        XCTAssertEqual(go.lastSeen, "2026-10-15")
        XCTAssertEqual(a.recurring.count, 2)
        XCTAssertEqual(a.candidates["x"], CandidateState(until: "2026-10-20", snoozes: 2, dismissed: true))
    }

    /// 片方で「トラさんに詳しく聞く」を続けた分が消えない（読み込みの Merge では落ちていた）
    func testExplainsAreKept() {
        var s1 = Session(id: "s", transcript: "t")
        s1.explains = [ExplainThread(key: "k1", turns: [ExplainTurn(q: "q", a: "a")])]
        var s2 = Session(id: "s", transcript: "t")
        s2.explains = [ExplainThread(key: "k1", turns: [ExplainTurn(q: "q", a: "a"), ExplainTurn(q: "q2", a: "a2")]),
                       ExplainThread(key: "k2", turns: [ExplainTurn(q: "z", a: "z")])]
        let m = Sync.mergeSession(s1, s2)
        XCTAssertEqual(m.explains?.map(\.key), ["k1", "k2"])
        XCTAssertEqual(m.explains?.first?.turns.count, 2)
        XCTAssertEqual(Sync.encode(m), Sync.encode(Sync.mergeSession(s2, s1)))
    }

    func testFoldedWins() {
        let full = Session(id: "s", transcript: "long text", issues: [Issue(type: "grammar", original: "a", suggestion: "b")])
        let folded = Logic.foldSessions([full], keepFull: 0)[0]
        XCTAssertEqual(Sync.mergeSession(full, folded).folded, true)
        XCTAssertEqual(Sync.mergeSession(folded, full).folded, true)
    }

    func testOlderTodayLoses() {
        let old = Today(date: "2026-10-15", ids: ["a"])
        let new = Today(date: "2026-10-16", ids: ["b"])
        XCTAssertEqual(Sync.mergeToday(old, new).ids, ["b"])
        XCTAssertEqual(Sync.mergeToday(new, old).ids, ["b"])
    }

    func testRemove() {
        var s = mac
        s = Sync.remove(s, name: Sync.name(session: "2026-10-15T10:00:00.000Z"))
        s = Sync.remove(s, name: Sync.name(phrase: "ON THE MEND"))
        XCTAssertEqual(s.sessions.count, 1)
        XCTAssertEqual(s.phrases.map(\.phrase), ["Only mac"])
        XCTAssertEqual(s.today?.ids, [])
    }

    func testRecordNamesAreStable() {
        XCTAssertEqual(Sync.name(phrase: "On  the mend"), Sync.name(phrase: "on the mend"))
        XCTAssertEqual(Sync.name(phrase: "it’s fine"), Sync.name(phrase: "it's fine"))
        XCTAssertEqual(Sync.name(phrase: "x").count, 34)
    }

    /// 本人の実データ（HG_SYNC_A / HG_SYNC_B に snapshot.json のパス）で、2 台が同じ記録に収まるか
    func testRealSnapshotsIfGiven() throws {
        let env = ProcessInfo.processInfo.environment
        guard let pa = env["HG_SYNC_A"], let pb = env["HG_SYNC_B"] else { throw XCTSkip("実データなし") }
        let a = try SnapshotStore(url: URL(fileURLWithPath: pa)).load()
        let b = try SnapshotStore(url: URL(fileURLWithPath: pb)).load()
        let (a2, _) = converge(a, b)
        XCTAssertGreaterThanOrEqual(a2.sessions.count, max(a.sessions.count, b.sessions.count))
        print("real:", a.sessions.count, b.sessions.count, "→", a2.sessions.count, "phrases", a2.phrases.count, "items", Sync.items(a2).count)
    }
}
