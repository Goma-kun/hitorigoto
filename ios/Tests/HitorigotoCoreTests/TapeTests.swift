import XCTest
@testable import HitorigotoCore

/// 会話の音声を 1 本にためる（Tape）。声は高さの違う合成音で代用し、順番を高さで見分ける
final class TapeTests: XCTestCase {

    private func tone(_ hz: Double, seconds: Double, amp: Double = 0.5) -> [Int16] {
        (0..<Int(seconds * Double(Tape.sampleRate))).map { Int16(sin(2 * .pi * hz * Double($0) / Double(Tape.sampleRate)) * amp * 32767) }
    }
    private func silence(_ seconds: Double) -> [Int16] { [Int16](repeating: 0, count: Int(seconds * Double(Tape.sampleRate))) }

    /// その区間の音の高さ（ゼロ交差の数から）
    private func pitch(_ pcm: [Int16], from: Double, to: Double) -> Double {
        let a = Int(from * Double(Tape.sampleRate)), b = min(pcm.count, Int(to * Double(Tape.sampleRate)))
        guard b > a + 1 else { return 0 }
        var crossings = 0
        for i in (a + 1)..<b where (pcm[i - 1] < 0) != (pcm[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(b - a) / Double(Tape.sampleRate))
    }

    func testPlayedKeepsOnlyWhatWasHeard() {
        let voice = tone(440, seconds: 3)
        let full = Tape.played(voice, ranges: [(0, 3)])
        XCTAssertEqual(full.pcm.count, voice.count)
        XCTAssertFalse(full.cut)
        // 1.2 秒で止められた（被り）
        let cut = Tape.played(voice, ranges: [(0, 1.2)])
        XCTAssertEqual(Double(cut.pcm.count) / 24000, 1.2, accuracy: 0.001)
        XCTAssertTrue(cut.cut)
        XCTAssertEqual(cut.pcm.last, 0, "切り口は小さくして終える")
        // 前半を 0.5 秒で飛ばして、2 秒目から最後まで（トラさんを飛ばす）
        let skipped = Tape.played(voice, ranges: [(0, 0.5), (2, 3)])
        XCTAssertEqual(Double(skipped.pcm.count) / 24000, 1.5, accuracy: 0.001)
        XCTAssertFalse(skipped.cut, "最後まで鳴ったので、止められた扱いにしない")
        // おかしな区間は捨てる
        XCTAssertTrue(Tape.played(voice, ranges: [(2, 1), (5, 9)]).pcm.isEmpty)
        XCTAssertTrue(Tape.played([], ranges: [(0, 1)]).pcm.isEmpty)
    }

    func testTrimAndLevel() {
        let said = silence(1.5) + tone(300, seconds: 2, amp: 0.1) + silence(2)
        let t = Tape.trimSilence(said)
        XCTAssertEqual(Double(t.count) / 24000, 2.5, accuracy: 0.02, "前後 0.25 秒ずつ残す")
        XCTAssertEqual(Tape.trimSilence(silence(1)).count, 24000, "全部が静かなら触らない")
        let loud = Tape.level(t)
        XCTAssertEqual(Double(loud.map { abs(Int($0)) }.max() ?? 0) / 32767, 0.4, accuracy: 0.01, "上げるのは 4 倍まで")
        let already = tone(300, seconds: 0.2, amp: 0.8)
        XCTAssertEqual(Tape.level(already), already, "十分大きい声は触らない")
    }

    func testFileNameAndEstimate() {
        XCTAssertEqual(Tape.fileName(for: "2026-11-19T00:00:00.000Z"), "talk_2026-11-19T00-00-00.000Z.m4a")
        XCTAssertEqual(Tape.megabytes(seconds: 600), 4.8, accuracy: 0.01)
    }

    /// 3 ターンの会話（相手役の切り出し → 自分 → 二人の返事を途中で遮る → 自分 → 返事 → 自分 → 締め）が、
    /// 話した順に、鳴った分だけの長さで 1 本になる
    func testThreeTurnsBecomeOneFileInOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tape-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = try XCTUnwrap(TapeWriter(url: dir.appendingPathComponent("t.pcm")))
        let ai = { (s: Double) in self.tone(880, seconds: s) }
        let me = { (s: Double) in self.silence(1) + self.tone(220, seconds: s, amp: 0.4) + self.silence(1.2) }

        w.appendSpoken(ai(2), ranges: [(0, 2)])            // 切り出し
        w.appendMine(me(1.5))                               // 1 ターン目
        w.appendSpoken(ai(4), ranges: [(0, 1.0)])          // 返事の途中で話し始めた（被り）: 1 秒しか鳴っていない
        w.appendMine(me(2))                                 // 2 ターン目
        w.appendSpoken(ai(3), ranges: [(0, 0.6), (1.5, 3)]) // トラさんを飛ばして相手役から
        w.appendMine(me(1))                                 // 3 ターン目
        w.appendSpoken([], ranges: [])                      // 鳴らなかった声は足さない
        w.appendSpoken(ai(1.5), ranges: [(0, 1.5)])        // 締め
        w.close()

        XCTAssertEqual(w.marks.map(\.who), ["ai", "me", "ai", "me", "ai", "me", "ai"])
        let lengths = [2.0, 2.0, 1.0, 2.5, 2.1, 1.5, 1.5]   // 自分の分は前後 0.25 秒ずつ残る
        for (m, want) in zip(w.marks, lengths) { XCTAssertEqual(m.seconds, want, accuracy: 0.02) }
        // 間は 0.35 秒。遮った声のあとだけ 0.12 秒
        let gaps = [0.35, 0.35, 0.12, 0.35, 0.35, 0.35]
        let total = lengths.reduce(0, +) + gaps.reduce(0, +)
        XCTAssertEqual(w.seconds, total, accuracy: 0.05)
        XCTAssertEqual(w.marks[3].start - (w.marks[2].start + w.marks[2].seconds), 0.12, accuracy: 0.001)

        #if canImport(AVFoundation)
        let out = dir.appendingPathComponent(Tape.fileName(for: "t"))
        try Tape.writeM4A(pcmFile: w.url, to: out)
        let back = try Tape.readPCM(out)
        XCTAssertEqual(Double(back.count) / 24000, total, accuracy: 0.15, "m4a の長さが、鳴った分の合計と合う")
        // 各発言の真ん中の音の高さで、順番どおりに入っていることを見る（AI=880Hz・自分=220Hz）
        for m in w.marks {
            let hz = pitch(back, from: m.start + m.seconds * 0.35, to: m.start + m.seconds * 0.65)
            XCTAssertEqual(hz, m.who == "ai" ? 880 : 220, accuracy: 40, "\(m.who) @\(m.start)")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        XCTAssertLessThan(Double(size) / 1_000_000, Tape.megabytes(seconds: total) * 1.5 + 0.02, "見積もりから大きく外れない")
        #endif

        w.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.url.path))
    }
}
