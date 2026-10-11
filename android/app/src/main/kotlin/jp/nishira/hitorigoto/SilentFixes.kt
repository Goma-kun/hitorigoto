package jp.nishira.hitorigoto

import jp.nishira.hitorigoto.core.Ask
import jp.nishira.hitorigoto.core.Issue

/**
 * 添削文（corrected_text）と書き起こしを突き合わせて、「直すべし」に挙がらなかった直しを拾う。
 * コーチの指摘は最大 5 件なので、添削文の中で黙って直された箇所が残る。読者がそれを自分で拾っていたのを、アプリでやる。
 * iOS の SilentFixes.swift と同じ LCS の単語差分。語の切り方は空白（英語・スペイン語）。日本語は直しを出さない
 */
object SilentFixes {
    data class Fix(val from: String, val to: String) { val id: String get() = "$from→$to" }

    private val fillers = setOf("uh", "um", "er", "hmm", "mm", "ah", "oh")

    private class Tok(val text: String, val key: String)

    fun find(transcript: String, corrected: String, issues0: List<Issue>, wordSpaces: Boolean = true, limit: Int = 10, asks: List<Ask> = emptyList()): List<Fix> {
        if (!wordSpaces) return emptyList()
        // 「日本語で言った分 → 英語ならこう」は指摘と同じ扱いで除く（日本語の箇所を "直し" として出さない）
        val issues = issues0 + asks.mapNotNull { a -> a.ways.firstOrNull()?.let { Issue("phrasing", a.said, it) } }
        val a = tokens(transcript); val b = tokens(corrected)
        if (a.isEmpty() || b.isEmpty() || a.size >= 1200 || b.size >= 1200) return emptyList()
        val n = a.size; val m = b.size
        val dp = Array(n + 1) { IntArray(m + 1) }
        for (i in n - 1 downTo 0) for (j in m - 1 downTo 0) {
            dp[i][j] = if (a[i].key == b[j].key) dp[i + 1][j + 1] + 1 else maxOf(dp[i + 1][j], dp[i][j + 1])
        }
        var i = 0; var j = 0
        val runs = ArrayList<IntArray>()      // [ai, aj, bi, bj]  a[ai..<aj] → b[bi..<bj]
        var cur: IntArray? = null
        fun closeRun() { cur?.let { runs.add(it) }; cur = null }
        while (i < n || j < m) {
            if (i < n && j < m && a[i].key == b[j].key) { closeRun(); i++; j++ }
            else if (j < m && (i >= n || dp[i][j + 1] >= dp[i + 1][j])) {
                if (cur == null) cur = intArrayOf(i, i, j, j)
                cur!![3] = j + 1; j++
            } else {
                if (cur == null) cur = intArrayOf(i, i, j, j)
                cur!![1] = i + 1; i++
            }
        }
        closeRun()
        // 日本語は分かち書きで語が割れるので、空白を除いた形で比べる
        val coveredFrom = issues.mapNotNull { it.original?.lowercase()?.replace(" ", "") }
        val coveredTo = issues.map { it.suggestion.lowercase().replace(" ", "") }
        val out = ArrayList<Fix>()
        for (r in runs) {
            val (ai, aj, bi, bj) = r
            val fromWords = a.subList(ai, aj).map { it.text }; val toWords = b.subList(bi, bj).map { it.text }
            if (fromWords.isEmpty() && toWords.isEmpty()) continue
            // 言いよどみ（uh）と同じ語の繰り返しを除いた「中身」で比べる。中身が同じなら出さない
            fun gist(toks: List<Tok>, before: String?): List<String> {
                val g = ArrayList<String>()
                for (t in toks) {
                    if (t.key in fillers) continue
                    if (g.lastOrNull() == t.key) continue
                    if (g.isEmpty() && before == t.key) continue
                    g.add(t.key)
                }
                return g
            }
            val gf = gist(a.subList(ai, aj), if (ai > 0) a[ai - 1].key else null)
            val gt = gist(b.subList(bi, bj), if (bi > 0) b[bi - 1].key else null)
            if (gf == gt) continue
            val gfs = gf.joinToString(""); val gts = gt.joinToString("")
            if ((gfs.isNotEmpty() && coveredFrom.any { it.contains(gfs) || gfs.contains(it) })
                || (gts.isNotEmpty() && coveredTo.any { it.contains(gts) || gts.contains(it) })) continue
            // 前後 1 語を添えて読める形にする
            val from = ((if (ai > 0) listOf(a[ai - 1].text) else emptyList()) + fromWords + (if (aj < n) listOf(a[aj].text) else emptyList())).joinToString(" ")
            val to = ((if (bi > 0) listOf(b[bi - 1].text) else emptyList()) + toWords + (if (bj < m) listOf(b[bj].text) else emptyList())).joinToString(" ")
            if (from.lowercase() == to.lowercase()) continue
            out.add(Fix(from, to))
            if (out.size >= limit) break
        }
        return out
    }

    private val ws = Regex("\\s+")

    /** 語に切る。句読点は語に付いたまま（表示用）、比べるときは外す */
    private fun tokens(s: String): List<Tok> = s.trim().split(ws).filter { it.isNotEmpty() }.map { w ->
        Tok(w, w.lowercase().trim { !it.isLetterOrDigit() && it != '\'' })
    }
}
