import Foundation

// 「三人で話す」の声。端末の読み上げは明らかに機械の声で、トラさんは黙ったまま文字だけだった（本人指摘・2026-10-28）。
// Gemini の TTS で、そのターンに話す二人（トラさん → ネイティブ役）の声を 1 回でまとめて作る。
// 声が取れないとき（通信・回数切れ・設定で切ったとき）は端末の声に落とす（App 側の Speaker）
// 相手役は名前つきで選べる（本人の要望・2026-10-28「他のアプリでよくあるように、Sam・Jim・Nick・Elizabeth…」）

/// 読み上げる 1 片。speaker は "Tora" か "Native"
public struct VoicePart: Equatable, Sendable {
    public var speaker: String
    public var text: String
    /// 言い方の指示（英語で書く方が効く）
    public var style: String
    public init(speaker: String, text: String, style: String = "") { self.speaker = speaker; self.text = text; self.style = style }
}

/// ネイティブ役（相手）。名前・声・人物像の組。人物像は指示文（口調）と声の指示の両方に使う
public struct Partner: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Gemini TTS の声の名前（既定の 30 声か、拡張ライブラリの id）
    public var voice: String
    public var female: Bool
    public var age: Int
    /// 出身（英語・指示文にそのまま）
    public var from: String
    /// 人柄（英語・声の指示と人物像に）
    public var vibe: String
    /// 画面に出す一言（日本語）
    public var blurb: String

    public init(id: String, name: String, voice: String, female: Bool, age: Int, from: String, vibe: String, blurb: String) {
        self.id = id; self.name = name; self.voice = voice; self.female = female; self.age = age; self.from = from; self.vibe = vibe; self.blurb = blurb
    }

    /// 人物像（英語・1 文）。指示文の「1 人目」と声の指示に使う。
    /// 自分や友人の声（出身なし）は、年齢・出身を作らず「学習者の友人」とだけ言う
    public var persona: String {
        if from.isEmpty { return "\(name), a \(female ? "woman" : "man") who is a friend of the learner. \(vibe)." }
        return "\(name), a \(age)-year-old \(female ? "woman" : "man") from \(from). \(vibe)."
    }
    /// 自分や友人の声（Gemini の声の複製）で話す相手役か
    public var isCustom: Bool { id.hasPrefix(Voice.customPrefix) }
}

/// トラさんの声の候補（本人が選ぶ）。2026-10-28 に 12 本＋6 本を合成して AI に採点させたもの
public struct ToraVoice: Identifiable, Equatable, Sendable {
    public var id: String       // Gemini の声の名前
    public var label: String    // 画面の短い名前
    public init(id: String, label: String) { self.id = id; self.label = label }
}

public enum Partners {
    /// 言語ごとの相手役。先頭が既定。custom は自分や友人の声で作った相手役（App 側が持つ・最後に並ぶ）
    public static func list(_ language: TargetLanguage, custom: [Partner] = []) -> [Partner] {
        builtin(language) + custom
    }

    /// 組み込みの相手役
    public static func builtin(_ language: TargetLanguage) -> [Partner] {
        switch language {
        case .enUS, .enGB:
            return [
                Partner(id: "sam", name: "Sam", voice: "Puck", female: false, age: 32, from: "the West Coast", vibe: "Friendly, relaxed and curious, laughs easily", blurb: "32 歳・西海岸・気さく"),
                Partner(id: "jim", name: "Jim", voice: "en-us-olin", female: false, age: 44, from: "the South", vibe: "Warm, easygoing and a little slow-talking, like a good neighbor", blurb: "44 歳・南部・おっとり"),
                Partner(id: "nick", name: "Nick", voice: "en-us-rami", female: false, age: 29, from: "the East Coast", vibe: "Upbeat, chatty and quick, asks lots of questions", blurb: "29 歳・東海岸・テンポ速め"),
                Partner(id: "elizabeth", name: "Elizabeth", voice: "en-us-jori", female: true, age: 38, from: "the Northwest", vibe: "Calm, warm and a good listener, speaks clearly", blurb: "38 歳・北西部・落ち着き"),
                Partner(id: "catherine", name: "Catherine", voice: "en-us-tari", female: true, age: 35, from: "the Midwest", vibe: "Kind, cheerful and encouraging", blurb: "35 歳・中西部・明るい"),
                Partner(id: "taylor", name: "Taylor", voice: "en-us-sola", female: true, age: 31, from: "the West Coast", vibe: "Laid-back, playful and easy to talk to", blurb: "31 歳・西海岸・ゆるい"),
            ]
        case .esES, .esMX:
            return [
                Partner(id: "lucia", name: "Lucía", voice: "Kore", female: true, age: 30, from: language == .esES ? "Madrid" : "Mexico City", vibe: "Warm, cheerful and patient", blurb: "30 歳・明るい"),
                Partner(id: "mateo", name: "Mateo", voice: "Charon", female: false, age: 36, from: language == .esES ? "Sevilla" : "Guadalajara", vibe: "Easygoing, friendly and relaxed", blurb: "36 歳・おだやか"),
            ]
        case .jaJP:
            return [
                Partner(id: "yuki", name: "ゆき", voice: "Aoede", female: true, age: 28, from: "Tokyo", vibe: "Warm, cheerful and patient", blurb: "28 歳・東京・明るい"),
                Partner(id: "kenta", name: "けんた", voice: "Charon", female: false, age: 34, from: "Osaka", vibe: "Easygoing, friendly and relaxed", blurb: "34 歳・大阪・おだやか"),
            ]
        }
    }

    /// id で探す。無ければ先頭（既定）。消した自分の声を選んだままでも既定に戻る
    public static func find(_ id: String, language: TargetLanguage, custom: [Partner] = []) -> Partner {
        let l = list(language, custom: custom)
        return l.first(where: { $0.id == id }) ?? l[0]
    }
}

public enum Voice {
    public static let tora = "Tora"
    public static let native = "Native"

    // MARK: - 自分や友人の声（Gemini の声の複製・2026-10-29 本人の要望「自分や友人の声をアップロードして相手役に」）
    //
    // Gemini の Voices API は、10〜30 秒の話し声と「同意の文を読んだ声」の 2 本から声を複製する（店の声と同じ TTS モデルで話せる）。
    // 同意の文は Google が定めたもので一字も変えてはいけない（違うと "Consent flow failed" で弾かれる・2026-10-29 実測）。
    // 鍵（voicekey_…）は端末だけが持ち、Google 側には残さない（store=false）。鍵は 7 日で切れるので、録った声から作り直す（App 側）

    /// 自分や友人の声で作った相手役の id の頭
    public static let customPrefix = "custom:"
    /// その声の名前が複製の声（鍵）か。複製の声は 1 回の合成で 1 人しか話せないので、呼ぶ側が分ける
    public static func isReplicated(_ voice: String) -> Bool { voice.hasPrefix("voicekey_") || voice.hasPrefix("voice_") }

    /// 自分や友人の声の相手役を作る。vibe が空なら気さくな友人
    public static func customPartner(id: String, name: String, female: Bool, blurb: String, voice: String, vibe: String = "") -> Partner {
        Partner(id: customPrefix + id, name: name, voice: voice, female: female, age: 0, from: "",
                vibe: vibe.isEmpty ? "Friendly, relaxed and natural, talks like a close friend" : vibe, blurb: blurb)
    }

    /// 声の複製に要る同意の文（Google の指定・一字も変えない）。ja / en / es 以外は英語
    public static func consentStatement(_ locale: String) -> String {
        if locale.hasPrefix("ja") { return "私はこの音声の所有者であり、Googleがこの音声を使用して音声合成モデルを作成することを承認します。" }
        if locale.hasPrefix("es") { return "Soy el propietario de esta voz y doy mi consentimiento para que Google la utilice para crear un modelo de voz sintética." }
        return "I am the owner of this voice and I consent to Google using this voice to create a synthetic voice model."
    }

    /// 録る声の長さ（秒）。話し声は 10〜30 秒（Google の指定）、同意の文は読み終わるまで（長くても 20 秒）
    public static let sampleMinSeconds = 10
    public static let sampleMaxSeconds = 30
    public static let consentMaxSeconds = 20

    /// トラさんの声の候補。先頭が既定（本人「じいさんっぽい人がいい」・2026-10-28 に候補を聞いてもらって決める）
    public static let toraVoices: [ToraVoice] = [
        ToraVoice(id: "ja-jp-advisor-9", label: "枯れた声"),
        ToraVoice(id: "Algenib", label: "渋い低音"),
        ToraVoice(id: "Enceladus", label: "かすれ声"),
        ToraVoice(id: "ja-jp-podcaster-7", label: "張りのある声"),
        ToraVoice(id: "ja-jp-training-4", label: "落ち着いた声"),
    ]
    public static let defaultToraVoice = toraVoices[0].id

    /// 声の割り当て（話者名 → Gemini の声）
    public static func voices(partner: Partner, tora: String = defaultToraVoice) -> [String: String] {
        [Self.tora: toraVoices.contains(where: { $0.id == tora }) ? tora : defaultToraVoice, native: partner.voice]
    }

    /// ネイティブ役の話し方。本人が「Gemini Notebook の音声解説は分かりやすかった。Taylor は本当にネイティブが話している感じ」（2026-10-29）
    /// → 聞き取りやすさを選べるようにした。clear は番組の司会のようにはっきり・ゆっくり、natural はネイティブ同士のまま
    public enum Clarity: String, CaseIterable, Sendable {
        case clear, natural
        public var label: String { self == .clear ? "はっきり" : "ふつう" }
        public var blurb: String { self == .clear ? "ゆっくり・一語ずつ明瞭に（音声解説の司会のように）" : "ネイティブ同士の速さと崩し方のまま" }
    }

    public static func nativeStyle(_ partner: Partner, clarity: Clarity = .natural) -> String {
        switch clarity {
        case .natural:
            return "\(partner.persona) Chatting casually with a new friend who is learning the language. Natural and lively, a little slower and clearer than usual."
        case .clear:
            return "\(partner.persona) Chatting warmly with a friend who is still learning the language, like a friendly podcast host: noticeably slower than normal conversation, every word articulated clearly, short pauses between phrases, no mumbling or swallowed syllables, but still natural intonation and warmth, not robotic."
        }
    }

    /// トラさんの話し方。本人の要望（2026-10-29）: アニメの声優のようなハキハキ・大げさな演技は嫌。普段の会話で本当に話しているような、力の抜けた自然な声に
    static let toraStyle = "an old man in his 70s, a retired boxing-gym trainer from downtown Tokyo, chatting casually at a kitchen table. Natural, understated, everyday conversational speech: relaxed, low-key, a little hoarse, normal speaking pace with natural pauses. NOT theatrical, NOT anime-like, no exaggerated acting, no over-articulation, no projecting the voice. Sounds like a real person talking, not a performer. Warm and amused underneath. When the line is in English, speak fluent, relaxed English in the same voice, with a faint Japanese accent."

    /// 端末の声で読むときの言語。トラさんは学習者に合わせて母語でも話す言語でも話すので、文字を見て決める。
    /// 日本語の字があれば ja-JP、無ければ nil（＝設定の「話す言語」の声）。説明が英語の設定で話す言語が英語でないときは en-US
    public static func fallbackLanguage(for text: String) -> String? {
        if text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }) { return "ja-JP" }
        if TargetLanguage.explanation == .en, !TargetLanguage.default.locale.hasPrefix("en") { return "en-US" }
        return nil
    }

    /// 試聴用の一言
    public static func sampleLine(_ partner: Partner, language: TargetLanguage) -> String {
        switch language {
        case .enUS, .enGB: return "Hey! I'm \(partner.name). Nice to meet you. So, what's been the best thing you ate this week?"
        case .esES, .esMX: return "¡Hola! Soy \(partner.name). Mucho gusto. ¿Qué es lo mejor que has comido esta semana?"
        case .jaJP: return "こんにちは、\(partner.name)です。よろしくね。今週いちばんおいしかったものは何？"
        }
    }
    public static let toraSampleLine = "おう、わしが寅吉だ。焼き芋はこう言うんだ。a baked sweet potato。遠慮せずに言ってみな。"

    /// このターンで新しく出た行から、読み上げる片を作る（行の順のまま。学習者の行は読まない）。
    /// トラさんは一言（help）に加えて、言い方そのもの（ways の 1 つ目）も声に出す。一言の中に既に入っていれば重ねない。
    /// 「同時に話し出した」言いかけ（tag collide）はここには入れない（別に作って重ねる・collideParts）
    public static func parts(for lines: [TalkLine], partner: Partner, clarity: Clarity = .natural) -> [VoicePart] {
        var out: [VoicePart] = []
        for l in lines where l.tag != "collide" {
            switch l.who {
            case "tora":
                var t = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
                for a in l.asks {
                    guard let w = a.ways.first, !t.lowercased().contains(w.lowercased()) else { continue }
                    t += (t.isEmpty ? "" : " ") + w
                }
                if !t.isEmpty { out.append(VoicePart(speaker: tora, text: t, style: toraStyle)) }
            case "native":
                if !l.text.isEmpty { out.append(VoicePart(speaker: native, text: l.text, style: nativeStyle(partner, clarity: clarity))) }
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

    /// 同時に話し出した言いかけ（tag collide）。それぞれ別に合成して、端末で重ねて鳴らす
    public static func collideParts(for lines: [TalkLine], partner: Partner, clarity: Clarity = .natural) -> [VoicePart] {
        lines.filter { $0.tag == "collide" && !$0.text.isEmpty }.map {
            $0.who == "tora" ? VoicePart(speaker: tora, text: $0.text, style: toraStyle + " Starts a sentence, then stops mid-word, cut off.")
                             : VoicePart(speaker: native, text: $0.text, style: nativeStyle(partner, clarity: clarity) + " Starts a sentence, then stops mid-word, cut off.")
        }
    }

    // MARK: - WAV の加工（24kHz・16bit・モノラル前提。Gemini の TTS はこの形で返す）

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

    /// WAV から PCM（16bit の標本列）を取り出す。"data" チャンクを探す（頭が 44 バイトでなくてもよい）
    public static func pcm(_ wav: Data) -> [Int16] {
        guard wav.count > 12, let dataTag = "data".data(using: .ascii), let r = wav.range(of: dataTag, in: 12..<wav.count) else { return [] }
        let start = r.upperBound + 4
        guard start < wav.count else { return [] }
        let body = wav.subdata(in: start..<wav.count)
        let n = body.count / 2
        return body.withUnsafeBytes { raw -> [Int16] in
            let p = raw.bindMemory(to: Int16.self)
            return (0..<n).map { Int16(littleEndian: p[$0]) }
        }
    }

    public static let sampleRate = 24000

    /// 二人が同時に話し出して、途中でぷつっと止まる音。a が先に始まり、offset 秒遅れて b が重なる。
    /// それぞれ自分の開始から cut 秒で切る（最後の 0.12 秒は小さくしていく）。重ねたところは音が割れないように少し下げる
    public static func collide(_ a: Data, _ b: Data, offset: Double = 0.35, cut: Double = 1.3) -> Data {
        let pa = pcm(a), pb = pcm(b)
        let off = Int(offset * Double(sampleRate)), len = Int(cut * Double(sampleRate)), fade = Int(0.12 * Double(sampleRate))
        let la = min(pa.count, len), lb = min(pb.count, len)
        let total = max(la, off + lb)
        guard total > 0 else { return a }
        var out = [Int32](repeating: 0, count: total)
        func gain(_ i: Int, _ l: Int) -> Double { i >= l - fade ? Double(l - i) / Double(fade) : 1 }
        for i in 0..<la { out[i] += Int32(Double(pa[i]) * gain(i, la) * 0.85) }
        for i in 0..<lb { out[off + i] += Int32(Double(pb[i]) * gain(i, lb) * 0.85) }
        let pcm16 = out.map { Int16(clamping: $0) }
        return wav(pcm: pcm16.withUnsafeBufferPointer { Data(buffer: $0) }, sampleRate: sampleRate)
    }

    /// WAV の長さ（秒）
    public static func duration(_ wav: Data) -> Double { Double(pcm(wav).count) / Double(sampleRate) }

    /// 複数の WAV を、間（秒）を挟んでつなぐ
    public static func join(_ wavs: [Data], gap: Double = 0.4) -> Data {
        let silence = [Int16](repeating: 0, count: Int(gap * Double(sampleRate)))
        var all: [Int16] = []
        for (i, w) in wavs.enumerated() {
            if i > 0 { all += silence }
            all += pcm(w)
        }
        return wav(pcm: all.withUnsafeBufferPointer { Data(buffer: $0) }, sampleRate: sampleRate)
    }
}
