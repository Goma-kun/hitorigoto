import Foundation

// 「スクショから表現を入れる」: 教材アプリや記事の画面のスクショを Gemini に読ませ、表現集の候補にする。
// 本人の使い方（2026-10-25）: Distinction の例文を見ていて「これを取り入れたい」と思ったら、スクショ → 共有 → 独り言。
// 添削の指示文（Prompts.swift・JS から機械生成）とは別物。アプリ版だけの機能なので、ここが正本。
// 中継サーバーでは添削・詳しく聞くとは別の回数で数える（/v1/scan）

/// スクショから読み取った候補 1 件
public struct ScanCandidate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var phrase: String
    public var meaning: String
    /// 例文。英文と訳を改行でつなぐ（例文が複数なら空行で区切る）
    public var example: String
    public var kind: String   // phrase | word

    public init(id: String = UUID().uuidString, phrase: String, meaning: String = "", example: String = "", kind: String = "phrase") {
        self.id = id; self.phrase = phrase; self.meaning = meaning; self.example = example; self.kind = kind
    }
}

public enum Scan {

    /// 1 枚から取り出す候補の上限（教材の 1 画面に載る表現はふつう 1〜3 個）
    public static let maxItems = 6

    /// システム指示。読むのは画面の文字だけ。教材の訳がある画面ではそれを活かし、作り直さない
    public static func system(language: TargetLanguage, explanation: TargetLanguage.Explanation = TargetLanguage.explanation) -> String {
        let lang = language.promptName
        let meaningLang = explanation == .en ? "英語" : "日本語"
        return """
あなたは「独り言」アプリの表現集を手伝うアシスタントです。学習者は\(lang)を学んでいます。
渡される画像は、学習者が\(lang)の教材アプリ・記事・SNS などを見ていて「この言い方を覚えたい」と思った画面のスクリーンショットです。
画面から、学習者が表現集に入れたい\(lang)の表現を取り出してください。

## 取り出し方
- 画面の主役になっている表現（見出しのフレーズ・単語、太字や色付きの部分）を優先する
- 主役の表現が無く、文章や会話だけの画面なら、学習者が日常の独り言で使えそうな言い回しを 1〜3 個選ぶ。文をまるごと 1 件にせず、使い回せる単位（句・決まり文句）に切る
- 表現は画面に書かれている形のまま写す。綴りを直さない。ただし文頭の大文字・文末の句点は外してよい（文として覚える決まり文句は残す）
- ボタン名・時刻・電池・通知・アプリの案内文など、学習の中身でない文字は無視する
- 同じ表現は 1 回だけ。最大 \(maxItems) 件

## 各欄
- phrase: \(lang)の表現
- meaning: 表現の意味を\(meaningLang)で。**画面に\(meaningLang)の意味・訳・説明があれば、それを優先して使う**（言葉を大きく変えない。長ければ要点を残して縮める）。無いときだけ、自然な\(meaningLang)の意味を短く作る
- example: 画面にその表現を使った例文があれば「例文\\n訳」の形で写す（訳が画面に無ければ\(meaningLang)で付ける）。例文が 2 つ以上あれば 2 つまで、空行（\\n\\n）で区切る。画面に例文が無ければ空文字にする（作らない）
- kind: 1 語なら "word"、それ以外は "phrase"

## 出力
次の JSON だけを返す。前後に説明や ``` を付けない。
{"items": [{"phrase": "...", "meaning": "...", "example": "...", "kind": "phrase"}]}
学習用の表現が見つからない画像なら {"items": []} を返す。
"""
    }

    public static let userMessage = "このスクリーンショットから、表現集に入れる候補を取り出してください。"

    /// 応答を読む。JSON で返らなければ空（スクショは作り直しが効くので、無理に拾わない）
    public static func parse(_ raw: String) -> [ScanCandidate] {
        guard let json = Logic.extractJsonObject(raw), let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let items = (obj["items"] as? [Any]) ?? []
        var seen = Set<String>()
        var out: [ScanCandidate] = []
        for e in items {
            guard let d = e as? [String: Any] else { continue }
            let phrase = Logic.collapseSpaces(Logic.asText(d["phrase"]))
            let key = PhraseLogic.phraseKey(phrase)
            if phrase.isEmpty || key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            let kind = Logic.asText(d["kind"]) == "word" ? "word" : "phrase"
            out.append(ScanCandidate(phrase: phrase,
                                     meaning: Logic.asText(d["meaning"]).trimmingCharacters(in: .whitespacesAndNewlines),
                                     example: Logic.asText(d["example"]).trimmingCharacters(in: .whitespacesAndNewlines),
                                     kind: kind))
            if out.count >= maxItems { break }
        }
        return out
    }
}
