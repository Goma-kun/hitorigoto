package jp.nishira.hitorigoto.core

/**
 * 話す言語（学ぶ対象）。iOS の TargetLanguage.swift と同じ置き換え。
 * Prompts.kt は JS から機械生成なので触らず、ここで文面を差し替えて使う。
 * 画面に出す名前（「英語（アメリカ）」など）は app 側の文字列リソースで持つ
 */
enum class TargetLanguage(val code: String) {
    EN_US("en-US"),
    EN_GB("en-GB"),
    ES_ES("es-ES"),
    ES_MX("es-MX"),
    JA_JP("ja-JP");

    /** 指示文の中で使う言語名（指示文は日本語で書かれている） */
    val promptName: String get() = when (this) {
        EN_US, EN_GB -> "英語"
        ES_ES, ES_MX -> "スペイン語"
        JA_JP -> "日本語"
    }

    /** 字幕や黙った直しの突き合わせで、語の区切りに空白が無い言語 */
    val hasNoWordSpaces: Boolean get() = this == JA_JP

    /** 音声認識・読み上げに渡すロケール */
    val locale: String get() = code

    /** コーチへの指示に足す、地域の注意 */
    internal val variantNote: String get() = when (this) {
        EN_US -> "学習者が目指すのはアメリカ英語です。綴り（color, center）と言い回しはアメリカ式に揃えてください。"
        EN_GB -> "学習者が目指すのはイギリス英語です。綴り（colour, centre）と言い回し（flat, holiday, queue など）はイギリス式に揃え、アメリカ式の綴りは直してください。"
        ES_ES -> "学習者が目指すのはスペインのスペイン語です。二人称複数は vosotros を使い、語彙もスペインで自然なもの（coche, ordenador など）に揃えてください。"
        ES_MX -> "学習者が目指すのは中南米（メキシコを中心とした）スペイン語です。二人称複数は ustedes を使い、vosotros は使いません。語彙も中南米で自然なもの（carro, computadora など）に揃えてください。"
        JA_JP -> "学習者は日本語を学んでいる非母語話者で、母語は日本語ではありません。学習者が話すのは日本語で、あなたはその日本語を添削します。自然な話し言葉の日本語に整え、敬体と常体の混在・助詞・活用の誤りを見てください。"
    }

    /** 説明（reason・good・note）をどの言語で書くか。アプリの表示言語に合わせる */
    enum class Explanation { JA, EN }

    /** 指示文を、この言語向けに直す。「英語」を言語名に置き換え、冒頭に地域の注意を足す */
    fun localize(prompt: String, explanation: Explanation): String {
        var s = prompt
        if (this != EN_US && this != EN_GB) {
            s = s.replace("英語", promptName)
            if (this == JA_JP) {
                // 「日本語話者の日本語」のような言い回しは意味が通らないので、話者の説明を言い換える
                s = s.replace("日本語話者の日本語", "非母語話者の日本語")
            }
        }
        // 1 行目（人物像の一文）の直後に地域の注意を入れる
        val nl = s.indexOf('\n')
        if (nl >= 0) s = s.substring(0, nl) + "\n" + variantNote + s.substring(nl)
        if (explanation == Explanation.EN) s += englishOverride
        return s
    }

    fun systemPrompt(explanation: Explanation) = localize(Prompts.system, explanation)
    fun audioPrompt(explanation: Explanation) = localize(Prompts.audio, explanation)

    companion object {
        val default = EN_US
        fun of(code: String?): TargetLanguage = entries.firstOrNull { it.code == code } ?: default

        /** 説明を英語にするときに末尾へ足す上書き指示。指示文そのものは日本語のまま（Gemini は最後の指示を優先する） */
        internal const val englishOverride = "\n## 出力言語の上書き（最優先）\n" +
            "- \"reason\"・\"recurring\"・\"good\"・\"note\"・\"recognition_doubt\" は**日本語ではなく英語**で書いてください。読む学習者は日本語が読めません。\n" +
            "- 老トレーナーの口調は英語で出してください（a gruff old boxing-gym trainer: blunt, short, boxing metaphors, but the grammar explanation itself must be accurate and clear）。\n" +
            "- \"corrected_text\"・\"suggestion\"・\"transcript\" は学習者が話している言語のまま。"
    }
}
