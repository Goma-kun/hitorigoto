package jp.nishira.hitorigoto.core

/**
 * 拡張機能の extension/phrase-core.js をそのまま移した層（表現集と「今日の表現」）。
 * 考え方はそちらの冒頭コメントに書いてある。答えが同じことを ../test/parity_android.mjs が突き合わせる
 */
object PhraseLogic {

    const val graduateHits = 3
    val ladderDays = listOf(7, 21)
    const val missDays = 1
    const val partialDays = 1
    const val skipDays = 2
    const val recallNgDays = 1
    const val defaultTotal = 5
    const val defaultNew = 3
    const val maxPhrases = 2000
    val kinds = listOf("phrase", "word")
    val results = listOf("hit", "partial", "miss", "skip", "rok", "rng")

    // ---- 日付（'YYYY-MM-DD' の文字列。暦の日数で計算し、時刻・時差の影響を受けない）----

    private fun ymd(s: String): Triple<Int, Int, Int> {
        val p = s.split("-").map { it.toIntOrNull() ?: 0 }
        return Triple(p.getOrElse(0) { 0 }, p.getOrElse(1) { 1 }, p.getOrElse(2) { 1 })
    }

    /** 通算日（グレゴリオ暦）。日付の足し引きと差はすべてこれで行う */
    private fun dayNumber(y: Int, m: Int, d: Int): Int {
        val a = (14 - m) / 12
        val yy = y + 4800 - a
        val mm = m + 12 * a - 3
        return d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045
    }

    private fun fromDayNumber(n: Int): String {
        val a = n + 32044
        val b = (4 * a + 3) / 146097
        val c = a - 146097 * b / 4
        val d = (4 * c + 3) / 1461
        val e = c - 1461 * d / 4
        val m = (5 * e + 2) / 153
        val day = e - (153 * m + 2) / 5 + 1
        val month = m + 3 - 12 * (m / 10)
        val year = 100 * b + d - 4800 + m / 10
        return String.format("%04d-%02d-%02d", year, month, day)
    }

    fun addDays(dateStr: String, n: Int): String {
        val (y, m, d) = ymd(dateStr)
        return fromDayNumber(dayNumber(y, m, d) + n)
    }

    fun daysBetween(from: String, to: String): Int {
        val (y1, m1, d1) = ymd(from); val (y2, m2, d2) = ymd(to)
        return dayNumber(y2, m2, d2) - dayNumber(y1, m1, d1)
    }

    // ---- 正規化・作成 ----

    private val curlyQuotes = Regex("[’‘]")

    fun phraseKey(text: String): String = Logic.collapseSpaces(text.lowercase().replace(curlyQuotes, "'"))

    private const val idChars = "abcdefghijklmnopqrstuvwxyz0123456789"

    fun newId(today: String): String = today + "-" + (0 until 6).map { idChars.random() }.joinToString("")

    fun makePhrase(phrase: String, meaning: String = "", kind: String = "phrase", source: String = "manual",
                   today: String, note: String = ""): PhraseCard? {
        val p = Logic.collapseSpaces(phrase)
        if (p.isEmpty()) return null
        return PhraseCard(id = newId(today), phrase = p, meaning = meaning.trim(), note = note.trim(),
            kind = if (kind in kinds) kind else "phrase", source = if (source == "issue") "issue" else "manual",
            added = today, due = today, hits = 0, status = "active", history = emptyList())
    }

    private val lineRe = Regex("(?U)^(.+?)(?:\\t+|\\s*[｜|—–]\\s*|\\s+-\\s+)(.+)$")

    /** まとめて追加の 1 行 → (表現, 意味)。区切りは タブ・｜・|・—・–・「 - 」 */
    fun parsePhraseLine(line: String): Pair<String, String>? {
        val s = line.trim()
        if (s.isEmpty()) return null
        val m = lineRe.find(s)
        if (m != null) return m.groupValues[1].trim() to m.groupValues[2].trim()
        return s to ""
    }

    fun parsePhraseLines(text: String): List<Pair<String, String>> =
        text.split(Regex("\r?\n")).mapNotNull { parsePhraseLine(it) }

    data class Added(val list: List<PhraseCard>, val added: Int)

    /** 既にある表現（同じ文字列）は増やさない */
    fun addPhrases(list: List<PhraseCard>, newOnes: List<PhraseCard>): Added {
        val cur = ArrayList(list)
        val seen = cur.map { phraseKey(it.phrase) }.toHashSet()
        var added = 0
        for (p in newOnes) {
            val key = phraseKey(p.phrase)
            if (key.isEmpty() || key in seen) continue
            seen.add(key); cur.add(p); added++
        }
        return Added(cur, added)
    }

    fun findPhrase(list: List<PhraseCard>, text: String): PhraseCard? {
        val key = phraseKey(text)
        return list.firstOrNull { phraseKey(it.phrase) == key }
    }

    // ---- 履歴から状態を組み立て直す ----

    fun rebuild(card: PhraseCard): PhraseCard {
        val history = card.history.sortedBy { it.d }
        var hits = 0
        var due: String? = card.added.ifEmpty { history.firstOrNull()?.d ?: "" }
        var status = "active"
        for (h in history) {
            when (h.r) {
                "hit" -> {
                    hits++
                    if (hits >= graduateHits) { status = "graduated"; due = null }
                    else due = addDays(h.d, ladderDays[minOf(hits - 1, ladderDays.size - 1)])
                }
                "partial" -> due = addDays(h.d, partialDays)
                "miss" -> due = addDays(h.d, missDays)
                "skip" -> due = addDays(h.d, skipDays)
                "rok" -> {}
                "rng" -> {
                    if (status == "graduated") { status = "active"; hits = graduateHits - 1 }
                    due = addDays(h.d, recallNgDays)
                }
            }
        }
        if (card.manual == "graduated") { status = "graduated"; due = null }
        if (card.manual == "active" && status == "graduated") {
            status = "active"
            if (due.isNullOrEmpty()) due = history.lastOrNull()?.d?.ifEmpty { null } ?: card.added
        }
        return card.copy(history = history, hits = hits, due = due,
            status = if (card.status == "archived") "archived" else status)
    }

    /** その日の独り言の結果を記録する（同じ日は 1 つ。後から直したら置き換える） */
    fun setSpeechResult(card: PhraseCard, today: String, result: String, asSaid: String = ""): PhraseCard {
        if (result !in results) return card
        val history = card.history.filter { !(it.d == today && it.r != "rok" && it.r != "rng") } +
            PhraseHistory(d = today, r = result, asSaid = if (asSaid.isEmpty()) null else asSaid.trim())
        return rebuild(card.copy(history = history, manual = if (card.manual == "graduated") "" else card.manual))
    }

    fun setRecallResult(card: PhraseCard, today: String, ok: Boolean): PhraseCard {
        val history = card.history.filter { !(it.d == today && (it.r == "rok" || it.r == "rng")) } +
            PhraseHistory(d = today, r = if (ok) "rok" else "rng")
        return rebuild(card.copy(history = history, manual = if (!ok && card.manual == "graduated") "" else card.manual))
    }

    fun setManualStatus(card: PhraseCard, status: String, today: String): PhraseCard {
        if (status == "graduated") return rebuild(card.copy(manual = "graduated"))
        if (status == "active") {
            val c = rebuild(card.copy(manual = "active"))
            return if (c.due.isNullOrEmpty()) c.copy(due = today) else c
        }
        return card
    }

    fun speechResults(card: PhraseCard): List<PhraseHistory> = card.history.filter { it.r != "rok" && it.r != "rng" }

    fun isNew(card: PhraseCard): Boolean = speechResults(card).isEmpty()

    fun lastSpeechResult(card: PhraseCard): String = speechResults(card).lastOrNull()?.r ?: ""

    // ---- 今日の表現を選ぶ ----

    fun pickToday(list: List<PhraseCard>, today: String, total: Int = defaultTotal,
                  maxNew: Int = defaultNew, fixedIds: List<String> = emptyList()): List<PhraseCard> {
        val all = list.filter { it.status == "active" }
        val byId = all.associateBy { it.id }
        val picked = ArrayList<PhraseCard>()
        val used = HashSet<String>()
        for (id in fixedIds) {
            val p = byId[id]
            if (p != null && id !in used) { picked.add(p); used.add(id) }
        }
        fun newCount() = picked.count { isNew(it) }

        val due = all.filter { it.id !in used && !isNew(it) && it.due != null && it.due <= today }
        val retry = due.filter { lastSpeechResult(it) in listOf("miss", "partial") }
        val retryIds = retry.map { it.id }.toHashSet()
        val rest = due.filter { it.id !in retryIds }
        val byDue = compareBy<PhraseCard> { it.due ?: "" }.thenBy { it.added }
        for (p in retry.sortedWith(byDue) + rest.sortedWith(byDue)) {
            if (picked.size >= total) break
            picked.add(p); used.add(p.id)
        }
        val fresh = all.filter { it.id !in used && isNew(it) && it.due != null && it.due <= today }
            .sortedWith(compareByDescending<PhraseCard> { it.added }.thenByDescending { it.id })
        for (p in fresh) {
            if (picked.size >= total || newCount() >= maxNew) break
            picked.add(p); used.add(p.id)
        }
        return picked
    }

    // ---- 独り言の中に表現が出たか ----

    private val wildcards = setOf("someone", "somebody", "something", "sb", "sth", "one's", "someone's", "oneself", "sth.", "sb.")
    private val optionals = setOf("a", "an", "the", "my", "your", "his", "her", "its", "our", "their", "to", "be")
    private val irregular = mapOf(
        "am" to "be", "is" to "be", "are" to "be", "was" to "be", "were" to "be", "been" to "be", "being" to "be",
        "has" to "have", "had" to "have", "did" to "do", "done" to "do", "does" to "do",
        "went" to "go", "gone" to "go", "goes" to "go", "came" to "come", "ran" to "run", "took" to "take", "taken" to "take",
        "made" to "make", "got" to "get", "gotten" to "get", "gave" to "give", "given" to "give", "saw" to "see", "seen" to "see",
        "knew" to "know", "known" to "know", "thought" to "think", "felt" to "feel", "kept" to "keep", "told" to "tell",
        "said" to "say", "paid" to "pay", "laid" to "lay", "drew" to "draw", "drawn" to "draw", "spoke" to "speak", "spoken" to "speak",
        "wrote" to "write", "written" to "write", "broke" to "break", "broken" to "break", "brought" to "bring", "bought" to "buy",
        "caught" to "catch", "taught" to "teach", "found" to "find", "held" to "hold", "left" to "leave", "lost" to "lose",
        "met" to "meet", "sat" to "sit", "sold" to "sell", "sent" to "send", "stood" to "stand", "understood" to "understand",
        "woke" to "wake", "wore" to "wear", "worn" to "wear", "won" to "win", "fell" to "fall", "fallen" to "fall", "flew" to "fly",
        "forgot" to "forget", "forgotten" to "forget", "grew" to "grow", "grown" to "grow", "hid" to "hide", "hidden" to "hide",
        "ate" to "eat", "eaten" to "eat", "began" to "begin", "begun" to "begin", "chose" to "choose", "chosen" to "choose",
        "led" to "lead", "meant" to "mean", "built" to "build", "spent" to "spend", "slept" to "sleep", "threw" to "throw", "thrown" to "throw",
        "stuck" to "stick", "struck" to "strike", "shook" to "shake", "rose" to "rise", "risen" to "rise", "sang" to "sing", "swam" to "swim",
        "became" to "become", "forgave" to "forgive", "froze" to "freeze", "fed" to "feed", "bit" to "bite", "beat" to "beat", "lent" to "lend",
        "children" to "child", "people" to "person", "men" to "man", "women" to "woman", "feet" to "foot", "teeth" to "tooth", "mice" to "mouse",
    )

    internal fun stem(word: String): String {
        var w = word.lowercase().replace(curlyQuotes, "'").filter { it in 'a'..'z' || it == '\'' }
        if (w.isEmpty()) return ""
        irregular[w]?.let { return it }
        for (suf in listOf("ing", "ed", "es", "s")) {
            if (w.length - suf.length >= 3 && w.endsWith(suf)) { w = w.dropLast(suf.length); break }
        }
        if (w.length >= 4 && w[w.length - 1] == w[w.length - 2]) w = w.dropLast(1)
        return w
    }

    private fun stemEq(a: String, b: String): Boolean {
        if (a.isEmpty() || b.isEmpty()) return false
        if (a == b) return true
        if (a + "e" == b || b + "e" == a) return true
        if (a + "i" == b || b + "i" == a) return true
        return false
    }

    private class Tok(val wild: Boolean = false, val stem: String = "", val optional: Boolean = false)

    private val parenRe = Regex("\\([^)]*\\)|（[^）]*）")
    private val edgeRe = Regex("^[^a-z〜~…]+|[^a-z'〜~…]+$")
    private val wildRe = Regex("[〜~…]")
    private val xRe = Regex("^x+$")
    private val ws = Regex("(?U)\\s+")

    /** 表現を照合用トークン列にする。「／」で区切った別形ごとの配列 */
    private fun tokenAlternatives(phrase: String): List<List<Tok>> {
        val cleaned = phrase.replace(parenRe, " ")
        val out = ArrayList<List<Tok>>()
        for (alt in cleaned.split(Regex("[／/]"))) {
            val raw = alt.replace(curlyQuotes, "'").split(ws).map { it.trim() }.filter { it.isNotEmpty() }
            val toks = ArrayList<Tok>()
            for (t in raw) {
                val low = t.lowercase().replace(edgeRe, "")
                if (low.isEmpty()) continue
                if (low in wildcards || wildRe.containsMatchIn(low) || xRe.matches(low)) { toks.add(Tok(wild = true)); continue }
                toks.add(Tok(stem = stem(low), optional = low in optionals))
            }
            if (toks.any { !it.wild && !it.optional }) out.add(toks)
        }
        return out
    }

    private val ntRe = Regex("n't\\b", RegexOption.IGNORE_CASE)

    /** 本文の語（英字とアポストロフィだけ。n't は not に開く） */
    private fun textWords(text: String): List<String> {
        val s = text.replace(curlyQuotes, "'").replace(ntRe, " not")
        val words = ArrayList<String>()
        val cur = StringBuilder()
        for (c in s) {
            if (c in 'A'..'Z' || c in 'a'..'z' || c == '\'') cur.append(c)
            else if (cur.isNotEmpty()) { words.add(cur.toString()); cur.setLength(0) }
        }
        if (cur.isNotEmpty()) words.add(cur.toString())
        return words
    }

    private class Match(val exact: Boolean, val start: Int, val end: Int)

    private fun matchTokens(toks: List<Tok>, stems: List<String>): Match? {
        var best: Match? = null
        for (start in 0 until stems.size) {
            var i = start; var ti = 0; var gaps = 0; var dropped = 0
            var ok = true
            while (ti < toks.size) {
                val tk = toks[ti]
                if (tk.wild) {
                    val next = toks.subList(ti + 1, toks.size).firstOrNull { !it.wild && !it.optional }
                    if (next == null) { i += 1; ti++; continue }
                    var found = -1
                    var k = i
                    while (k <= minOf(stems.size - 1, i + 3)) {
                        if (stemEq(stems[k], next.stem)) { found = k; break }
                        k++
                    }
                    if (found < 0) { ok = false; break }
                    i = found; ti++
                    while (ti < toks.size && toks[ti].optional) ti++
                    continue
                }
                if (i >= stems.size) { ok = false; break }
                if (stemEq(stems[i], tk.stem)) { i++; ti++; continue }
                if (tk.optional) { dropped++; ti++; continue }
                if (i + 1 < stems.size && stemEq(stems[i + 1], tk.stem) && gaps < 2) { gaps++; i += 2; ti++; continue }
                if (i + 2 < stems.size && stemEq(stems[i + 2], tk.stem) && gaps < 1) { gaps += 2; i += 3; ti++; continue }
                ok = false; break
            }
            if (!ok) continue
            val cand = Match(gaps == 0 && dropped == 0, start, i)
            if (best == null || (cand.exact && !best.exact)) best = cand
            if (best.exact) break
        }
        return best
    }

    data class Detection(val used: Boolean, val exact: Boolean, val asSaid: String)

    fun detect(phrase: String, text: String): Detection {
        val words = textWords(text)
        val stems = words.map { stem(it) }
        var best: Match? = null
        for (toks in tokenAlternatives(phrase)) {
            val m = matchTokens(toks, stems)
            if (m != null && (best == null || (m.exact && !best.exact))) best = m
            if (best != null && best.exact) break
        }
        val b = best ?: return Detection(false, false, "")
        val end = minOf(b.end, words.size)
        return Detection(true, b.exact, words.subList(b.start, end).joinToString(" "))
    }

    fun judge(cards: List<PhraseCard>, text: String): List<Judged> = cards.map { c ->
        val d = detect(c.phrase, text)
        Judged(id = c.id, result = if (!d.used) "miss" else if (d.exact) "hit" else "partial", asSaid = d.asSaid, judge = "auto")
    }

    /** AI が返した targets を優先して重ねる */
    fun mergeAiTargets(judged: List<Judged>, cards: List<PhraseCard>, aiTargets: List<Target>): List<Judged> {
        if (aiTargets.isEmpty()) return judged
        val byKey = HashMap<String, String>()
        for (c in cards) byKey[phraseKey(c.phrase)] = c.id
        val out = ArrayList(judged)
        for (t in aiTargets) {
            val id = byKey[phraseKey(t.phrase)] ?: continue
            val idx = out.indexOfFirst { it.id == id }
            if (idx < 0) continue
            val j = out[idx]
            out[idx] = j.copy(
                result = if (!t.used) "miss" else if (t.exact) "hit" else "partial",
                asSaid = if (t.used) (t.asSaid.ifEmpty { j.asSaid }) else "",
                note = t.note,
                judge = "ai",
            )
        }
        return out
    }

    /** AI へ渡す「今日の狙いの表現」の節（無ければ空文字） */
    fun targetsSection(cards: List<PhraseCard>): String {
        val list = cards.filter { it.phrase.isNotEmpty() }
        if (list.isEmpty()) return ""
        val lines = list.map { "- ${it.phrase}" + (if (it.meaning.isEmpty()) "" else "（${it.meaning}）") }
        return "\n\n## 今日使うと決めていた表現（それぞれ使えたかを \"targets\" で判定してください）\n" + lines.joinToString("\n")
    }

    data class Stats(val total: Int, val active: Int, val fresh: Int, val graduated: Int)

    fun stats(list: List<PhraseCard>) = Stats(
        total = list.size,
        active = list.count { it.status == "active" && !isNew(it) },
        fresh = list.count { it.status == "active" && isNew(it) },
        graduated = list.count { it.status == "graduated" },
    )

    fun trim(list: List<PhraseCard>, max: Int = maxPhrases): List<PhraseCard> {
        if (list.size <= max) return list
        val grads = list.filter { it.status == "graduated" }.sortedBy { it.added }
        val drop = grads.take(list.size - max).map { it.id }.toHashSet()
        return list.filter { it.id !in drop }.take(max)
    }

    val markOf = mapOf("hit" to "◎", "partial" to "△", "miss" to "✗", "skip" to "−", "rok" to "○", "rng" to "×")

    fun marks(card: PhraseCard): String = card.history.joinToString("") { markOf[it.r] ?: "" }
}
