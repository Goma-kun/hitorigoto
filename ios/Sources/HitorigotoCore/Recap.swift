import Foundation

// 復習の音声: 「三人で話す」が終わったあと、その日の会話（話した話題・教わった言い方・直し）を
// トラさんとネイティブ役が振り返る 2〜3 分の台本を Gemini に作ってもらい、二人の声で 1 本の音声にする。
// 本人の要望（2026-10-29）「終わったら Podcast のように復習用の音声を作りたい」。
// Gemini Notebook（旧 NotebookLM）の音声解説の形を、アプリの部品（台本 → 多話者 TTS）でやる。
public enum Recap {

    /// 台本の指示文。トラさんは母語で進行役、ネイティブ役は教わった言い方を**ゆっくり 2 回**言う
    public static func system(language: TargetLanguage, partner: Partner, explanation: TargetLanguage.Explanation = TargetLanguage.explanation) -> String {
        let lang = language.promptName
        let mother = explanation == .ja ? "日本語" : "英語"
        let native = partner.name
        var s = """
あなたは「独り言」アプリの復習用の音声番組の台本を書きます。学習者（\(lang)を学んでいて母語は\(mother)）が、さっき \(native) とトラさんと三人で話した会話を、あとで歩きながら聞いて復習するための 2〜3 分の音声です。
出演は二人。学習者は出ません（聞くだけ）。

## 出演者
- トラさん（寅吉）: \(mother)で進行役。下町のボクシングジムの老トレーナー。一人称「わし」、学習者は「おめえ」、べらんめえ調だが叱らない。耳で聞いて分かる言葉で（長音の崩しは控えめ）。
- \(native): \(lang)のネイティブ。人物像: \(partner.persona) \(mother)は話さない。学習者に向けて、ゆっくりはっきり話す。

## 構成（この順・全体で \(lang)と\(mother)あわせて 350〜450 語くらい）
1. はじまり: トラさんが「今日の会話の復習だ」と一言。\(native) が \(lang)で短く挨拶。
2. 今日の話: \(native) が、今日どんな話をしたかを\(lang)で 3〜4 文で振り返る（学習者が言ったことを拾って。難しい語は使わない）。トラさんが\(mother)で要点を一言。
3. 覚える言い方: 「教わった言い方」を 1 つずつ。トラさんが\(mother)で「〜って言いたかったやつだ」と場面を言い、\(native) がその\(lang)を**そのまま 2 回**言う（1 回目のあとに間を置くため、2 回目は別の行にする）。トラさんが使いどころを一言添える。言い方が 4 つより多ければ、大事そうな 4 つまで。
4. 直し: 「直すべし」があれば 1 つずつ。トラさんが\(mother)で「おめえは〜って言ったが、こう言うんだ」と理由を一言、\(native) が直した形を**2 回**言う。無ければこの段は飛ばす。
5. しめ: トラさんが今日\(lang)で言えていたことを 1 つ引いて短くほめる（「わしが買ってやる点」があればそれを使う）。\(native) が\(lang)で一言、明日に向けて声をかける。

## 書き方
- 文字で読む台本ではなく、声に出して読まれる。行ごとに 1〜2 文・短く。
- \(native) の行は\(lang)だけ。トラさんの行は\(mother)だけ（言い方そのものを言うときだけ\(lang)を混ぜてよい）。
- 言い方は会話で出た形をそのまま使う。新しい言い方を作らない。
- 時間や天気など、会話に出ていないことは言わない。

## 出力
次の JSON だけを返す。前後に説明や ``` を付けない。
{ "lines": [ { "who": "tora または native", "text": "一言" } ] }
"""
        if explanation == .en {
            s += "\n\n## 出力言語の上書き（最優先）\nトラさんの行は日本語ではなく英語で書く（a gruff but kind old boxing-gym trainer: blunt and short）。\n"
        }
        return s
    }

    /// その日の会話の記録を渡す
    public static func userMessage(session: Session, partner: Partner, language: TargetLanguage) -> String {
        var lines: [String] = []
        lines.append("## 今日の会話（古い順）")
        for l in session.talk ?? [] {
            let who = l.who == "native" ? partner.name : (l.who == "tora" ? "トラさん" : "学習者")
            if l.tag == "consult" { continue }
            var t = l.text
            if l.who == "me", !l.sub.isEmpty { t += "（自然な形: \(l.sub)）" }
            if !t.isEmpty { lines.append("\(who): \(t)") }
        }
        if let asks = session.asks, !asks.isEmpty {
            lines.append("")
            lines.append("## 教わった言い方")
            for a in asks {
                lines.append("- 「\(a.said)」 → " + a.ways.joined(separator: " / ") + (a.note.isEmpty ? "" : "（\(a.note)）"))
            }
        }
        if !session.issues.isEmpty {
            lines.append("")
            lines.append("## 直すべし")
            for i in session.issues {
                lines.append("- \(i.original ?? "") → \(i.suggestion)" + ((i.reason?.isEmpty == false) ? "（\(i.reason!)）" : ""))
            }
        }
        if let g = session.good, !g.isEmpty {
            lines.append("")
            lines.append("## わしが買ってやる点")
            lines.append(g)
        }
        lines.append("")
        lines.append("この会話の復習の台本を書いてください。")
        return lines.joined(separator: "\n")
    }

    /// 台本を行にする。who が tora を含めばトラさん、それ以外はネイティブ役
    public static func parse(_ raw: String?) -> [TalkLine] {
        guard let json = Logic.extractJsonObject(raw), let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = obj["lines"] as? [Any] else { return [] }
        return arr.compactMap { x -> TalkLine? in
            guard let d = x as? [String: Any] else { return nil }
            let text = Logic.asText(d["text"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TalkLine(who: Logic.asText(d["who"]).lowercased().contains("tora") ? "tora" : "native", text: text)
        }
    }

    /// 声にする片を、1 回の読み上げに収まる長さ（maxChars）で区切る。区切りは行の境で、同じ人の連続は 1 片にまとめる。
    /// ネイティブ役は「はっきり」の話し方（復習なので聞き取りやすさ優先）
    public static func chunks(_ lines: [TalkLine], partner: Partner, maxChars: Int = 1500) -> [[VoicePart]] {
        var out: [[VoicePart]] = []
        var cur: [VoicePart] = []
        var count = 0
        for l in lines {
            let part = l.who == "tora"
                ? VoicePart(speaker: Voice.tora, text: l.text, style: Voice.toraStyle)
                : VoicePart(speaker: Voice.native, text: l.text, style: Voice.nativeStyle(partner, clarity: .clear))
            if count + l.text.count > maxChars, !cur.isEmpty { out.append(cur); cur = []; count = 0 }
            if let last = cur.last, last.speaker == part.speaker {
                // 同じ人の続く行は段落で区切る（2 回言う言い方の間に、読み上げで間が入るように）
                cur[cur.count - 1] = VoicePart(speaker: last.speaker, text: last.text + "\n\n" + part.text, style: last.style)
            } else {
                cur.append(part)
            }
            count += l.text.count
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// 記録に添える音声ファイルの名前（記録の id から）
    public static func fileName(for sessionId: String) -> String {
        "recap_" + sessionId.replacingOccurrences(of: ":", with: "-") + ".m4a"
    }
}
