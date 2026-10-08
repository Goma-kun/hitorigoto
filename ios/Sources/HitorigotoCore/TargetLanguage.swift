import Foundation

/// 話す言語（学ぶ対象）。説明は今のところ日本語のまま（2026-10-09・本人の方針「まず話す言語から」）。
/// Prompts.swift は JS から機械生成なので触らず、ここで文面を差し替えて使う
public enum TargetLanguage: String, CaseIterable, Sendable, Identifiable {
    case enUS = "en-US"
    case enGB = "en-GB"
    case esES = "es-ES"
    case esMX = "es-MX"

    public var id: String { rawValue }
    public static let `default`: TargetLanguage = .enUS

    /// 設定に出す名前
    public var label: String {
        switch self {
        case .enUS: return "英語（アメリカ）"
        case .enGB: return "英語（イギリス）"
        case .esES: return "スペイン語（スペイン）"
        case .esMX: return "スペイン語（中南米）"
        }
    }
    /// 文中で使う短い名前（「英語で話すだけ」など）
    public var name: String {
        switch self {
        case .enUS, .enGB: return "英語"
        case .esES, .esMX: return "スペイン語"
        }
    }
    /// 音声認識・読み上げに渡すロケール
    public var locale: String { rawValue }

    /// コーチへの指示に足す、地域の注意
    var variantNote: String {
        switch self {
        case .enUS: return "学習者が目指すのはアメリカ英語です。綴り（color, center）と言い回しはアメリカ式に揃えてください。"
        case .enGB: return "学習者が目指すのはイギリス英語です。綴り（colour, centre）と言い回し（flat, holiday, queue など）はイギリス式に揃え、アメリカ式の綴りは直してください。"
        case .esES: return "学習者が目指すのはスペインのスペイン語です。二人称複数は vosotros を使い、語彙もスペインで自然なもの（coche, ordenador など）に揃えてください。"
        case .esMX: return "学習者が目指すのは中南米（メキシコを中心とした）スペイン語です。二人称複数は ustedes を使い、vosotros は使いません。語彙も中南米で自然なもの（carro, computadora など）に揃えてください。"
        }
    }

    /// 指示文を、この言語向けに直す。「英語」を言語名に置き換え、冒頭に地域の注意を足す。
    /// 例文の中の英文はそのまま（言語の例として残して支障がない）
    public func localize(_ prompt: String) -> String {
        var s = prompt
        if self != .enUS && self != .enGB {
            s = s.replacingOccurrences(of: "英語", with: name)
        }
        // 1 行目（人物像の一文）の直後に地域の注意を入れる
        if let r = s.range(of: "\n") {
            s.insert(contentsOf: "\n" + variantNote, at: r.lowerBound)
        }
        return s
    }

    public var systemPrompt: String { localize(Prompts.system) }
    public var audioPrompt: String { localize(Prompts.audio) }
}
