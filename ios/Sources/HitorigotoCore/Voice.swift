import Foundation

// 「三人で話す」の声。端末の読み上げは明らかに機械の声で、トラさんは黙ったまま文字だけだった（本人指摘・2026-10-28）。
// Gemini の TTS で、そのターンに話す二人（トラさん → ネイティブ役）の声を 1 回でまとめて作る。
// 声が取れないとき（通信・回数切れ・設定で切ったとき）は端末の声に落とす（App 側の Speaker）

/// 読み上げる 1 片。speaker は "Tora" か "Native"
public struct VoicePart: Equatable, Sendable {
    public var speaker: String
    public var text: String
    /// 言い方の指示（英語で書く方が効く）
    public var style: String
    public init(speaker: String, text: String, style: String = "") { self.speaker = speaker; self.text = text; self.style = style }
}

public enum Voice {
    public static let tora = "Tora"
    public static let native = "Native"

    /// 声の割り当て（Gemini の既定の声から）。トラさんは低く渋い声、ネイティブ役は明るい声
    public static func voices(_ language: TargetLanguage) -> [String: String] {
        switch language {
        case .enUS, .enGB: return [tora: "Charon", native: "Puck"]
        case .esES, .esMX: return [tora: "Charon", native: "Kore"]
        case .jaJP: return [tora: "Charon", native: "Aoede"]
        }
    }

    static func nativeStyle(_ language: TargetLanguage) -> String {
        let who: String
        switch language {
        case .enUS: who = "a friendly, relaxed American in their 30s"
        case .enGB: who = "a friendly, relaxed Londoner in their 30s"
        case .esES: who = "a warm, cheerful woman from Madrid"
        case .esMX: who = "a warm, cheerful woman from Mexico City"
        case .jaJP: who = "a warm, cheerful Japanese woman from Tokyo"
        }
        return "\(who), chatting casually with a new friend who is learning the language. Natural and lively, a little slower and clearer than usual."
    }

    static let toraStyle = "a gruff but warm old Tokyo boxing-gym trainer, a quick low-voiced aside to his friend. Relaxed, kind, not shouting."

    /// このターンで新しく出た行から、読み上げる片を作る（トラさん → ネイティブ役の順。学習者の行は読まない）。
    /// トラさんは一言（help）に加えて、言い方そのもの（ways の 1 つ目）も声に出す。一言の中に既に入っていれば重ねない
    public static func parts(for lines: [TalkLine], language: TargetLanguage) -> [VoicePart] {
        var out: [VoicePart] = []
        for l in lines {
            switch l.who {
            case "tora":
                var t = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
                for a in l.asks {
                    guard let w = a.ways.first, !t.lowercased().contains(w.lowercased()) else { continue }
                    t += (t.isEmpty ? "" : " ") + w
                }
                if !t.isEmpty { out.append(VoicePart(speaker: tora, text: t, style: toraStyle)) }
            case "native":
                if !l.text.isEmpty { out.append(VoicePart(speaker: native, text: l.text, style: nativeStyle(language))) }
            default: break
            }
        }
        // 同じ人が続いたら 1 片にまとめる（話者の切り替えを減らすと自然に聞こえる）
        var merged: [VoicePart] = []
        for p in out {
            if let last = merged.last, last.speaker == p.speaker { merged[merged.count - 1].text += " " + p.text }
            else { merged.append(p) }
        }
        return merged
    }

    /// 頭なしの PCM（16bit・モノラル）に WAV の頭を付ける
    public static func wav(pcm: Data, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}
