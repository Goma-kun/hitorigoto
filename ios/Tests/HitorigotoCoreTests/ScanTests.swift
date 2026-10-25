import XCTest
@testable import HitorigotoCore

/// スクショから表現を入れる（Scan）と、例文・画像の欄の同期
final class ScanTests: XCTestCase {

    func testParseItems() {
        let raw = """
        {"items": [
          {"phrase": "  for a  split second ", "meaning": "ほんの一瞬", "example": "I lost focus for a split second.\\n一瞬気がそれた。", "kind": "phrase"},
          {"phrase": "For a split second", "meaning": "重複", "example": "", "kind": "phrase"},
          {"phrase": "nuance", "meaning": "ニュアンス", "kind": "word"},
          {"phrase": "", "meaning": "空は捨てる"}
        ]}
        """
        let c = Scan.parse(raw)
        XCTAssertEqual(c.map(\.phrase), ["for a split second", "nuance"], "空白を詰め、同じ表現は 1 回")
        XCTAssertEqual(c[0].example, "I lost focus for a split second.\n一瞬気がそれた。")
        XCTAssertEqual(c[1].kind, "word")
        XCTAssertEqual(c[1].example, "")
    }

    func testParseCodeFenceAndEmpty() {
        XCTAssertEqual(Scan.parse("```json\n{\"items\": [{\"phrase\": \"hang in there\"}]}\n```").map(\.phrase), ["hang in there"])
        XCTAssertTrue(Scan.parse("{\"items\": []}").isEmpty)
        XCTAssertTrue(Scan.parse("読めませんでした").isEmpty)
    }

    func testParseCapsItems() {
        let items = (0..<10).map { "{\"phrase\": \"phrase \($0)\"}" }.joined(separator: ",")
        XCTAssertEqual(Scan.parse("{\"items\": [\(items)]}").count, Scan.maxItems)
    }

    func testSystemMentionsLanguage() {
        XCTAssertTrue(Scan.system(language: .enUS, explanation: .ja).contains("英語"))
        XCTAssertTrue(Scan.system(language: .enUS, explanation: .ja).contains("日本語の意味"))
        XCTAssertTrue(Scan.system(language: .esES, explanation: .en).contains("スペイン語"))
    }

    func testExampleAndImageSurviveCodingAndMerge() throws {
        let a = PhraseCard(id: "p1", phrase: "for a split second", meaning: "ほんの一瞬", added: "2026-10-25", due: "2026-10-25",
                           example: "I froze for a split second.\n一瞬固まった。", image: "img-abc.jpg")
        let data = try JSONEncoder().encode(a)
        let back = try JSONDecoder().decode(PhraseCard.self, from: data)
        XCTAssertEqual(back.example, a.example)
        XCTAssertEqual(back.image, "img-abc.jpg")

        // 片方の端末にしか無い欄は残る。どちらから混ぜても同じ
        let b = PhraseCard(id: "p2", phrase: "for a split second", meaning: "ほんの一瞬", added: "2026-10-25", due: "2026-10-25")
        let ab = Sync.mergePhrase(a, b), ba = Sync.mergePhrase(b, a)
        XCTAssertEqual(ab, ba)
        XCTAssertEqual(ab.image, "img-abc.jpg")
        XCTAssertEqual(ab.example, a.example)
    }

    func testOldCardsHaveNoNewKeys() throws {
        // 拡張・Android と同じ形のまま（新しい欄は無いときに書き出さない）
        let c = PhraseCard(id: "p1", phrase: "hang in there", added: "2026-10-25", due: "2026-10-25")
        let json = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
        XCTAssertFalse(json.contains("example"))
        XCTAssertFalse(json.contains("image"))
    }
}
