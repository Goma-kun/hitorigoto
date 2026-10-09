import Foundation

/// 話す言語（学ぶ対象）。説明は今のところ日本語のまま（2026-10-09・本人の方針「まず話す言語から」）。
/// Prompts.swift は JS から機械生成なので触らず、ここで文面を差し替えて使う
public enum TargetLanguage: String, CaseIterable, Sendable, Identifiable {
    case enUS = "en-US"
    case enGB = "en-GB"
    case esES = "es-ES"
    case esMX = "es-MX"
    case jaJP = "ja-JP"

    public var id: String { rawValue }
    public static let `default`: TargetLanguage = .enUS

    /// 設定に出す名前
    public var label: String {
        switch self {
        case .enUS: return String(localized: "英語（アメリカ）")
        case .enGB: return String(localized: "英語（イギリス）")
        case .esES: return String(localized: "スペイン語（スペイン）")
        case .esMX: return String(localized: "スペイン語（中南米）")
        case .jaJP: return String(localized: "日本語")
        }
    }
    /// 文中で使う短い名前（「英語で話すだけ」など）
    public var name: String {
        switch self {
        case .enUS, .enGB: return String(localized: "英語")
        case .esES, .esMX: return String(localized: "スペイン語")
        case .jaJP: return String(localized: "日本語")
        }
    }
    /// 指示文の中で使う言語名（指示文は日本語で書かれている）
    var promptName: String {
        switch self {
        case .enUS, .enGB: return "英語"
        case .esES, .esMX: return "スペイン語"
        case .jaJP: return "日本語"
        }
    }
    /// 字幕や黙った直しの突き合わせで、語の区切りに空白が無い言語
    public var hasNoWordSpaces: Bool { self == .jaJP }
    /// 音声認識・読み上げに渡すロケール
    public var locale: String { rawValue }

    /// コーチへの指示に足す、地域の注意
    var variantNote: String {
        switch self {
        case .enUS: return "学習者が目指すのはアメリカ英語です。綴り（color, center）と言い回しはアメリカ式に揃えてください。"
        case .enGB: return "学習者が目指すのはイギリス英語です。綴り（colour, centre）と言い回し（flat, holiday, queue など）はイギリス式に揃え、アメリカ式の綴りは直してください。"
        case .esES: return "学習者が目指すのはスペインのスペイン語です。二人称複数は vosotros を使い、語彙もスペインで自然なもの（coche, ordenador など）に揃えてください。"
        case .esMX: return "学習者が目指すのは中南米（メキシコを中心とした）スペイン語です。二人称複数は ustedes を使い、vosotros は使いません。語彙も中南米で自然なもの（carro, computadora など）に揃えてください。"
        case .jaJP: return "学習者は日本語を学んでいる非母語話者で、母語は日本語ではありません。学習者が話すのは日本語で、あなたはその日本語を添削します。自然な話し言葉の日本語に整え、敬体と常体の混在・助詞・活用の誤りを見てください。"
        }
    }

    /// 説明（reason・good・note）をどの言語で書くか。アプリの表示言語に合わせる
    public enum Explanation: String, Sendable { case ja, en }
    public static var explanation: Explanation {
        (Bundle.main.preferredLocalizations.first ?? "ja").hasPrefix("ja") ? .ja : .en
    }

    /// 説明を英語にするときに末尾へ足す上書き指示。指示文そのものは日本語のまま（Gemini は最後の指示を優先する）
    static let englishOverride = """

## 出力言語の上書き（最優先）
- "reason"・"recurring"・"good"・"note"・"recognition_doubt" は**日本語ではなく英語**で書いてください。読む学習者は日本語が読めません。
- 老トレーナーの口調は英語で出してください（a gruff old boxing-gym trainer: blunt, short, boxing metaphors, but the grammar explanation itself must be accurate and clear）。
- "corrected_text"・"suggestion"・"transcript" は学習者が話している言語のまま。
"""

    /// 指示文を、この言語向けに直す。「英語」を言語名に置き換え、冒頭に地域の注意を足す。
    /// 例文の中の英文はそのまま（言語の例として残して支障がない）
    public func localize(_ prompt: String, explanation: Explanation = TargetLanguage.explanation) -> String {
        var s = prompt
        if self != .enUS && self != .enGB {
            s = s.replacingOccurrences(of: "英語", with: promptName)
            if self == .jaJP {
                // 「日本語話者の日本語」のような言い回しは意味が通らないので、話者の説明を言い換える
                s = s.replacingOccurrences(of: "日本語話者の日本語", with: "非母語話者の日本語")
            }
        }
        // 1 行目（人物像の一文）の直後に地域の注意を入れる
        if let r = s.range(of: "\n") {
            s.insert(contentsOf: "\n" + variantNote, at: r.lowerBound)
        }
        if explanation == .en { s += Self.englishOverride }
        return s
    }

    public var systemPrompt: String { localize(Prompts.system) }
    public var audioPrompt: String { localize(Prompts.audio) }
}
