import XCTest
@testable import HitorigotoCore

final class AuditTests: XCTestCase {

    // 修正版では多くの箇所を直したのに、説明が少なく more_fixes が空だった回の型（2026-11-17 に実際に起きた形を、作り物の文で再現）
    static let said = """
Yes, so it's about my weekend. Actually, I went to hiking with my friend on Saturday without any tiredness. I'm not sure, but you know, I've been running every morning, but I think that it's not enough for my body. I get sleepy easily recently, and my friend explained to me that there is a possibility coffee had bad influence on my sleep, so I quit drinking coffee since last week. And strictly, I reduced my coffee cups.
To be exact, I reduce a month of coffee. So I don't quit at all, but, you know, I have a latte about 200 kcal every morning, but there is a famous drink called Mugicha. It's not a coffee, it's barley tea, and that calorie is about zero. So I'm going to have to put up with it for a while.
Last night as I said, I couldn't find it. But today I stopped by another supermarket. By the way, this morning I cleaned my room, and it's a part of preparing for the trip, like taking my bag and checking, organizing clothes. I think without sleepiness, I can get up early and I have plenty of time to do something that I have to do. Anyway, it's about time to make breakfast. So see you again.
"""
    static let corrected = """
So, it's about my weekend. I went hiking with my friend on Saturday without feeling tired at all. I used to run every morning, but I didn't think it was enough for my body. I've been getting sleepy easily lately, and my friend explained to me that coffee might have had a bad influence on my sleep, so I quit drinking coffee last week. More precisely, I cut back on coffee.
To be exact, I reduced the amount of coffee I drink. I didn't quit completely, but I used to have a latte that was about 200 calories every morning. There's a famous drink called Mugicha—it's barley tea, and it has almost zero calories. So I'm going to stick with that for a while.
Last night, as I said, I couldn't find it, but today I stopped by another supermarket. By the way, I feel good this me, and I cleaned my room, which is part of preparing for the trip—like packing my bag and checking and organizing clothes. Without that sleepiness, I can get up early and have plenty of time to do what I need to do. Anyway, it's about time for me to make breakfast, so I'll see you later!
"""
    static var feedback: Feedback {
        Feedback(correctedText: corrected, issues: [
            Issue(type: "vocabulary", original: "tiredness", suggestion: "feeling tired", reason: ""),
            Issue(type: "vocabulary", original: "a month of coffee", suggestion: "the amount of coffee", reason: ""),
            Issue(type: "phrasing", original: "put up with it", suggestion: "stick with that", reason: ""),
            Issue(type: "vocabulary", original: "taking my bag", suggestion: "packing my bag", reason: ""),
        ], asks: [
            Ask(said: "麦茶", ways: ["It's barley tea.", "It's roasted barley tea."], ipa: [], note: ""),
        ])
    }

    func testRealSessionNeedsAudit() {
        let un = Audit.uncovered(said: Self.said, feedback: Self.feedback)
        let added = un.map { $0.added.joined(separator: " ") }
        XCTAssertGreaterThanOrEqual(un.count, 8)
        XCTAssertTrue(added.contains { $0.contains("completely") })     // I don't quit at all → I didn't quit completely
        XCTAssertTrue(added.contains { $0.contains("calories") })       // kcal → calories
        XCTAssertTrue(added.contains { $0.contains("lately") })         // recently → lately
        XCTAssertFalse(added.contains { $0.contains("amount") })        // 直すべしで説明済み
        XCTAssertFalse(added.contains { $0 == "packing" })           // 「英語ならこう」で説明済み
        XCTAssertTrue(Audit.needed(said: Self.said, feedback: Self.feedback, language: .enUS))
        XCTAssertFalse(Audit.needed(said: Self.said, feedback: Self.feedback, language: .jaJP))
    }

    func testNoAuditWhenEverythingIsExplained() {
        let said = String(repeating: "I go to the park every day and I enjoy it a lot. ", count: 4) + "Yesterday I go to a shop, uh, you know, and buy a news paper."
        let corrected = String(repeating: "I go to the park every day and I enjoy it a lot. ", count: 4) + "Yesterday I went to a shop and bought a newspaper."
        let fb = Feedback(correctedText: corrected,
                          issues: [Issue(type: "grammar", original: "I go to a shop", suggestion: "I went to a shop", reason: "")],
                          moreFixes: [Fix(original: "buy a news paper", suggestion: "bought a newspaper", note: "n")])
        XCTAssertEqual(Audit.uncovered(said: said, feedback: fb).count, 0)   // 言いよどみを消しただけの所は数えない
        XCTAssertFalse(Audit.needed(said: said, feedback: fb, language: .enUS))
    }

    func testParseAndMerge() {
        let raw = """
        {"corrected_patches": [
           {"from": "I feel good this me, and", "to": "I feel good this morning, and"},
           {"from": "coffee", "to": "tea"},
           {"from": "not in the text", "to": "x"},
           {"from": "I cleaned my room, which is part of preparing for the trip", "to": "I cleaned."}],
         "answers": [
           {"n": 1, "skip": false, "original": "I don't quit at all", "suggestion": "I didn't quit completely", "note": "意味が逆だ"},
           {"n": 2, "skip": true, "original": "you know", "suggestion": "well"}],
         "more_fixes": [
           {"original": "a month of coffee", "suggestion": "the amount of coffee", "note": "重なり"},
           {"original": "same", "suggestion": "same", "note": ""}]}
        """
        let r = Audit.parse(raw)!
        XCTAssertEqual(r.fixes.count, 2)
        XCTAssertEqual(r.patches.count, 4)
        let out = Audit.merge(Self.feedback, r)
        XCTAssertEqual(out.moreFixes.map(\.original), ["I don't quit at all"])   // 直すべしと同じ直しは足さない
        XCTAssertTrue(out.correctedText.contains("I feel good this morning, and"))
        XCTAssertFalse(out.correctedText.contains("tea,  "))
        XCTAssertTrue(out.correctedText.contains("I quit drinking coffee last week"))                      // 何回も出てくる from は当てない
        XCTAssertTrue(out.correctedText.contains("part of preparing for the trip"))  // 大きく削る差し替えは当てない
        XCTAssertEqual(out.issues, Self.feedback.issues)
        XCTAssertNil(Audit.parse("not json"))
    }

    func testSystemPromptBorrowsPersona() {
        let s = Audit.system(language: .enUS, explanation: .ja)
        XCTAssertTrue(s.contains("## あなたの人物像と口調"))
        XCTAssertTrue(s.contains("〜べし"))
        XCTAssertFalse(s.contains("## 口調より優先される絶対のルール"))
        XCTAssertTrue(s.contains("\"more_fixes\""))
        XCTAssertTrue(s.contains("\"corrected_patches\""))
        let um = Audit.userMessage(said: Self.said, feedback: Self.feedback)
        XCTAssertTrue(um.contains("## 機械で見つけた、説明の無い書き換え"))
        XCTAssertTrue(um.contains("lately"))
        XCTAssertTrue(um.contains("\n1. "))
        XCTAssertTrue(Audit.system(language: .esMX, explanation: .ja).contains("スペイン語学習者"))
    }
}
