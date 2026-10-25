package jp.nishira.hitorigoto.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import java.time.LocalDate

/**
 * 拡張機能の extension/english-core.js をそのまま移した層。
 * 同じ入力に同じ答えを返すことを ../test/parity_android.mjs が突き合わせる。
 */
object Logic {

    const val keepFull = 30        // 全文で残すセッション数
    const val keepTotal = 400      // 畳んだものも含めた保持上限
    const val recurringMin = 2     // 何回出たら「繰り返し」として AI に渡すか
    const val recurringSend = 5    // AI に渡す繰り返し指摘の件数
    val types = listOf("phrasing", "vocabulary", "grammar")

    // ---- 応答の解釈 ----

    /** 最初の { から対応する } までを取り出す。取れなければ null */
    fun extractJsonObject(raw: String?): String? {
        if (raw == null) return null
        val start = raw.indexOf('{')
        if (start < 0) return null
        var depth = 0; var inStr = false; var esc = false
        var i = start
        while (i < raw.length) {
            val c = raw[i]
            if (inStr) {
                if (esc) esc = false
                else if (c == '\\') esc = true
                else if (c == '"') inStr = false
            } else if (c == '"') {
                inStr = true
            } else if (c == '{') {
                depth++
            } else if (c == '}') {
                depth--
                if (depth == 0) return raw.substring(start, i + 1)
            }
            i++
        }
        return null
    }

    /** JS の `typeof v === 'string' ? v.trim() : ''` */
    internal fun asText(v: JsonElement?): String {
        val p = v as? JsonPrimitive ?: return ""
        return if (p.isString) p.content.trim() else ""
    }

    internal fun asStringArray(v: JsonElement?): List<String> {
        val a = v as? JsonArray ?: return emptyList()
        return a.map { asText(it) }.filter { it.isNotEmpty() }
    }

    /** JS の `!!v` */
    internal fun truthy(v: JsonElement?): Boolean = when (v) {
        null, JsonNull -> false
        is JsonPrimitive -> when {
            v.isString -> v.content.isNotEmpty()
            else -> v.booleanOrNull ?: (v.doubleOrNull?.let { it != 0.0 && !it.isNaN() } ?: true)
        }
        else -> true
    }

    private val strictJson = Json { }

    private val trailingMarks = Regex("[.!?。]+$")

    /** 直しの重なりを比べるときの形（JS の fixKey と同じ）。大文字小文字・空白の数・文末の記号の違いは同じとみなす */
    internal fun fixKey(t: String): String =
        collapseSpaces(t.lowercase()).replace(trailingMarks, "").trim()

    /**
     * 同じ直しの重なりを外す（JS の tidyFixes と同じ）。AI が同じ直しを 2 度書くことがある。
     * - issues: 直す前と後が同じもの（直しになっていない）と、同じ組の 2 件目以降を外す。順番は保つ
     * - fixes（more_fixes）: 同じく外したうえで、残した issues のどれかで説明済みの直し
     *   （言った形も直した形も、その issue の中に語の区切りごと含まれる）も外す
     */
    internal fun tidyFixes(issues: List<Issue>, fixes: List<Fix>): Pair<List<Issue>, List<Fix>> {
        val seen = HashSet<String>()
        fun keep(original: String, suggestion: String): Pair<String, String>? {
            val o = fixKey(original); val s = fixKey(suggestion)
            if (o == s) return null
            if (!seen.add(o + "\n" + s)) return null
            return o to s
        }
        val outIssues = ArrayList<Issue>()
        val covered = ArrayList<Pair<String, String>>()
        for (it in issues) {
            val p = keep(it.original ?: "", it.suggestion) ?: continue
            outIssues.add(it)
            covered.add(" ${p.first} " to " ${p.second} ")
        }
        val outFixes = ArrayList<Fix>()
        for (f in fixes) {
            val o = " ${fixKey(f.original)} "; val s = " ${fixKey(f.suggestion)} "
            if (covered.any { c -> c.first.contains(o) && c.second.contains(s) }) continue
            if (keep(f.original, f.suggestion) != null) outFixes.add(f)
        }
        return outIssues to outFixes
    }

    /** JS の asFixes。言った形と直した形が揃っていて違うものだけ・最大 20 件 */
    internal fun asFixes(v: JsonElement?): List<Fix> {
        val a = v as? JsonArray ?: return emptyList()
        return a.mapNotNull { raw ->
            val it = raw as? JsonObject
            val original = asText(it?.get("original")); val suggestion = asText(it?.get("suggestion"))
            if (original.isEmpty() || suggestion.isEmpty() || original == suggestion) null
            else Fix(original, suggestion, asText(it?.get("note")))
        }.take(20)
    }

    /** 応答を、表示と保存が前提にできる形に揃える。読み取れなければ null */
    fun parseFeedback(raw: String?): Feedback? {
        val json = extractJsonObject(raw) ?: return null
        val d = try { strictJson.parseToJsonElement(json) as? JsonObject } catch (e: Exception) { null } ?: return null

        val issues = (d["issues"] as? JsonArray ?: JsonArray(emptyList())).mapNotNull { raw ->
            val it = raw as? JsonObject
            val type = asText(it?.get("type")).lowercase()
            val original = asText(it?.get("original"))
            val suggestion = asText(it?.get("suggestion"))
            if (original.isEmpty() || suggestion.isEmpty()) null
            else Issue(type = if (type in types) type else "phrasing", original = original,
                suggestion = suggestion, reason = asText(it?.get("reason")))
        }
        val pron = (d["pronunciation"] as? JsonArray ?: JsonArray(emptyList())).mapNotNull { raw ->
            val it = raw as? JsonObject
            val said = asText(it?.get("said")); val heard = asText(it?.get("heard_as"))
            if (said.isEmpty() || heard.isEmpty()) null else Pronunciation(said, heard, asText(it?.get("note")))
        }
        val targets = (d["targets"] as? JsonArray ?: JsonArray(emptyList())).mapNotNull { raw ->
            val it = raw as? JsonObject
            val phrase = asText(it?.get("phrase"))
            if (phrase.isEmpty()) null
            else Target(phrase, used = truthy(it?.get("used")), exact = truthy(it?.get("exact")),
                asSaid = asText(it?.get("as_said")), note = asText(it?.get("note")))
        }
        // 「日本語で言った分 → 英語ならこう」。said と ways が揃っているものだけ。ways は最大 3・件数は最大 5（JS と同じ）
        val asks = (d["asks"] as? JsonArray ?: JsonArray(emptyList())).mapNotNull { raw ->
            val it = raw as? JsonObject
            val said = asText(it?.get("said"))
            val ways = (it?.get("ways") as? JsonArray ?: JsonArray(emptyList())).map { w -> asText(w) }.filter { w -> w.isNotEmpty() }.take(3)
            val ipaRaw = (it?.get("ipa") as? JsonArray ?: JsonArray(emptyList())).map { w -> asText(w) }
            val ipa = ways.indices.map { i -> ipaRaw.getOrNull(i) ?: "" }
            if (said.isEmpty() || ways.isEmpty()) null else Ask(said, ways, ipa, asText(it?.get("note")))
        }
        // 同じ直しの重なりを外す（JS の tidyFixes と同じ）。more_fixes は先に最大 20 件に切ってから外す
        val (tidyIssues, tidyMore) = tidyFixes(issues, asFixes(d["more_fixes"]))
        return Feedback(
            correctedText = asText(d["corrected_text"]),
            issues = tidyIssues,
            moreFixes = tidyMore,
            recurring = asStringArray(d["recurring"]),
            recognitionDoubt = asStringArray(d["recognition_doubt"]),
            good = asText(d["good"]),
            transcript = asText(d["transcript"]),
            pronunciation = pron.take(3),
            targets = targets,
            asks = asks.take(5),
        )
    }

    // ---- 繰り返し指摘 ----

    fun recurringText(issue: Issue): String = "${issue.original ?: ""} → ${issue.suggestion}"

    fun recurringKey(text: String): String = collapseSpaces(text.lowercase())

    /** JS の `\s`（Unicode の空白）。Android の正規表現（ICU）は `(?U)` を受け付けず、`\s` は ASCII だけなので文字で書く */
    const val JS_WS = "[\\t\\n\\x0B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]"
    private val spaces = Regex("$JS_WS+")

    /** 空白の連続を 1 つに（JS の replace(/\s+/g, ' ').trim()） */
    fun collapseSpaces(s: String): String = s.split(spaces).filter { it.isNotEmpty() }.joinToString(" ")

    /** 今回の指摘を繰り返しリストへ反映する。1 回目は count:1 で控えるだけ */
    fun promoteRecurring(prev: List<Recurring>, issues: List<Issue>, today: String): List<Recurring> {
        val list = ArrayList(prev)
        val index = HashMap<String, Int>()
        list.forEachIndexed { i, r -> index[recurringKey(r.text)] = i }
        val seen = HashSet<String>()
        for (issue in issues) {
            val text = recurringText(issue)
            val key = recurringKey(text)
            if (key.isEmpty() || key in seen) continue
            seen.add(key)
            val at = index[key]
            if (at != null) {
                list[at] = list[at].copy(count = list[at].count + 1, lastSeen = today)
            } else {
                index[key] = list.size
                list.add(Recurring(text, 1, today))
            }
        }
        return list
    }

    /** AI に渡すのは「2 回以上出たもの」の上位だけ */
    fun topRecurring(list: List<Recurring>, limit: Int = recurringSend, min: Int = recurringMin): List<Recurring> =
        list.filter { it.count >= min }
            .sortedWith(Comparator { a, b -> if (a.count != b.count) b.count - a.count else LocaleCompare.compare(a.text, b.text) })
            .take(limit)

    /** 直近 keepFull 件は全文、それ以前は指摘の type と suggestion だけ残す */
    fun foldSessions(sessions: List<Session>, keepFull: Int = Logic.keepFull, keepTotal: Int = Logic.keepTotal): List<Session> =
        sessions.take(keepTotal).mapIndexed { i, s ->
            if (i < keepFull || s.folded == true) s
            else Session(id = s.id, folded = true, issues = s.issues.map { Issue(type = it.type, suggestion = it.suggestion) })
        }

    // ---- コピー用の本文 ----

    data class Labels(
        val corrected: String, val issues: String, val good: String, val said: String, val pron: String,
        val types: Map<String, String>,
        /** 「日本語で言った分 → 英語ならこう」の見出し。空なら出さない（JS の L.asks が無いときと同じ） */
        val asks: String = "",
        /** 「直すべし」に入りきらなかった直しの見出し。空なら出さない（JS の L.more が無いときと同じ） */
        val more: String = "",
    )

    /** 履歴からコピーするときの本文。修正版だけでなく、何をどう直されたのかも持ち出せる */
    fun buildSessionText(s: Session, L: Labels): String {
        val out = ArrayList<String>()
        val c = s.correctedText
        if (!c.isNullOrEmpty()) out.add("【${L.corrected}】\n$c")
        if (s.issues.isNotEmpty()) {
            val lines = s.issues.mapIndexed { i, it ->
                val head = if (!it.original.isNullOrEmpty()) "${it.original}\n   → ${it.suggestion}" else "→ ${it.suggestion}"
                val type = L.types[it.type]?.takeIf { t -> t.isNotEmpty() }?.let { t -> "[$t] " } ?: ""
                val reason = if (!it.reason.isNullOrEmpty()) "\n   ${it.reason}" else ""
                "${i + 1}. $type$head$reason"
            }
            out.add("【${L.issues}】\n${lines.joinToString("\n\n")}")
        }
        // 「直すべし」に入りきらなかった直し（理由つき）。無いセッションでは出さない
        val more = s.moreFixes
        if (!more.isNullOrEmpty() && L.more.isNotEmpty()) {
            val lines = more.mapIndexed { i, it -> "${i + 1}. ${it.original}\n   → ${it.suggestion}" + (if (it.note.isEmpty()) "" else "\n   ${it.note}") }
            out.add("【${L.more}】\n${lines.joinToString("\n\n")}")
        }
        val pron = s.pronunciation
        if (!pron.isNullOrEmpty() && L.pron.isNotEmpty()) {
            val lines = pron.mapIndexed { i, it -> "${i + 1}. ${it.said} → ${it.heardAs}" + (if (it.note.isEmpty()) "" else "\n   ${it.note}") }
            out.add("【${L.pron}】\n${lines.joinToString("\n\n")}")
        }
        val asks = s.asks
        if (!asks.isNullOrEmpty() && L.asks.isNotEmpty()) {
            val lines = asks.mapIndexed { i, it -> "${i + 1}. ${it.said}\n   → ${it.ways.joinToString(" / ")}" + (if (it.note.isEmpty()) "" else "\n   ${it.note}") }
            out.add("【${L.asks}】\n${lines.joinToString("\n\n")}")
        }
        val g = s.good
        if (!g.isNullOrEmpty()) out.add("【${L.good}】\n$g")
        val t = s.transcript
        if (!t.isNullOrEmpty()) out.add("【${L.said}】\n${t.trim()}")
        return out.joinToString("\n\n")
    }

    // ---- AI へ渡すユーザーメッセージ（JS と一字一句同じ）----

    private fun recurringLines(recurring: List<Recurring>): String {
        val lines = recurring.map { "- ${it.text}（${it.count} 回）" }
        return if (lines.isEmpty()) "なし" else lines.joinToString("\n")
    }

    fun buildEnglishUserMessage(transcript: String, recurring: List<Recurring>, extra: String = ""): String =
        "## 今回の独り言（音声認識結果）\n${transcript.trim()}\n\n## これまでに繰り返し指摘されている点\n${recurringLines(recurring)}$extra"

    fun buildEnglishAudioUserMessage(asrTranscript: String, recurring: List<Recurring>, extra: String = ""): String {
        val asr = asrTranscript.trim()
        return "## 今回の独り言\n音声を添付しています。まず音声を聞いて、実際に言ったことを書き起こしてください。\n\n" +
            "## 参考：Chrome の音声認識結果（化けている可能性があります。書き起こしの根拠にしないこと）\n" +
            (if (asr.isEmpty()) "（取れませんでした。音声だけを頼りにしてください）" else asr) +
            "\n\n## これまでに繰り返し指摘されている点\n${recurringLines(recurring)}$extra"
    }

    /** 今日の日付（'YYYY-MM-DD'・端末のローカル時刻） */
    fun todayStamp(date: LocalDate = LocalDate.now()): String =
        String.format("%04d-%02d-%02d", date.year, date.monthValue, date.dayOfMonth)
}

/**
 * JS の `String.prototype.localeCompare`（ICU の既定の照合）に寄せた比較。
 * 1 段目は大文字小文字を区別せず、空白・記号 < 数字 < 文字の順。同じなら小文字が先（ICU の既定）、
 * それでも同じなら文字コード順。繰り返し指摘の並びにしか使わないので、この範囲で十分
 */
object LocaleCompare : Comparator<String> {
    private fun cls(c: Char): Int = when {
        c.isWhitespace() -> 0
        c.isDigit() -> 2
        c.isLetter() -> 3
        else -> 1
    }

    override fun compare(a: String, b: String): Int {
        val n = minOf(a.length, b.length)
        for (i in 0 until n) {
            val x = a[i]; val y = b[i]
            if (x == y) continue
            val cx = cls(x); val cy = cls(y)
            if (cx != cy) return cx - cy
            val lx = x.lowercaseChar(); val ly = y.lowercaseChar()
            if (lx != ly) return lx.compareTo(ly)
        }
        if (a.length != b.length) return a.length - b.length
        // 1 段目が同じ: 小文字が先
        for (i in 0 until n) {
            val x = a[i]; val y = b[i]
            if (x == y) continue
            if (x.isLowerCase() && y.isUpperCase()) return -1
            if (x.isUpperCase() && y.isLowerCase()) return 1
            return x.compareTo(y)
        }
        return 0
    }
}
