package jp.nishira.hitorigoto.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * 移植そのものの突き合わせは ../test/parity_android.mjs（JS 版と実際に比べる）が担う。
 * ここには「Kotlin 側だけで壊れうるところ」を置く（iOS の CoreTests.swift を移したもの）
 */
class CoreTests {

    @Test
    fun dayArithmetic() {
        assertEquals("2026-10-04", PhraseLogic.addDays("2026-09-27", 7))
        assertEquals("2027-01-01", PhraseLogic.addDays("2026-12-31", 1))
        assertEquals("うるう年", "2028-02-29", PhraseLogic.addDays("2028-02-28", 1))
        assertEquals(7, PhraseLogic.daysBetween("2026-09-27", "2026-10-04"))
        assertEquals(-7, PhraseLogic.daysBetween("2026-10-04", "2026-09-27"))
    }

    @Test
    fun promptsDerived() {
        assertTrue(Prompts.system.contains("音声は届いていません"))
        assertTrue(Prompts.audio.contains("## 重要な前提（音声モード）"))
        assertFalse(Prompts.audio.contains("音声は届いていません"))
        assertTrue(Prompts.audio.contains("\"transcript\""))
        assertTrue(Prompts.audio.contains("\"targets\""))
        assertEquals(1, Prompts.audio.split("## 出力").size - 1)
        assertEquals(1, Prompts.audio.split("## 重要な前提").size - 1)
    }

    @Test
    fun localizePrompt() {
        val en = TargetLanguage.EN_GB.localize(Prompts.audio, TargetLanguage.Explanation.JA)
        assertTrue(en.lines()[1].contains("イギリス英語"))
        assertFalse(en.contains("出力言語の上書き"))
        val es = TargetLanguage.ES_MX.localize(Prompts.system, TargetLanguage.Explanation.EN)
        assertTrue(es.contains("スペイン語学習者"))
        assertFalse(es.contains("英語学習者"))
        assertTrue(es.endsWith("は学習者が話している言語のまま。"))
        val ja = TargetLanguage.JA_JP.localize(Prompts.audio, TargetLanguage.Explanation.JA)
        assertTrue(ja.contains("非母語話者の日本語"))
    }

    /** 拡張機能の書き出しファイル（実物と同じ形）が読める */
    @Test
    fun importExtensionExport() {
        val json = """
        {"format":"hitorigoto-english-v1","exported_at":"2026-09-27T00:00:00.000Z",
         "sessions":[{"id":"2026-09-26T12:00:00.000Z","transcript":"I go to park.","corrected_text":"I went to the park.",
                      "issues":[{"type":"grammar","original":"I go to park","suggestion":"I went to the park","reason":"r"}],
                      "good":"g","asr_transcript":"I go to bark.","pronunciation":[{"said":"park","heard_as":"bark","note":"n"}]},
                     {"id":"2026-08-01T00:00:00.000Z","folded":true,"issues":[{"type":"grammar","suggestion":"went"}]}],
         "recurring":[{"text":"a → b","count":2,"last_seen":"2026-09-01"}],
         "phrases":[{"id":"p1","phrase":"under the hood","meaning":"裏側","kind":"phrase","source":"manual","added":"2026-09-12",
                     "due":"2026-09-13","hits":0,"status":"active","history":[{"d":"2026-09-12","r":"miss"}]}]}
        """
        val r = Merge.importJson(json, Snapshot())
        assertEquals(2, r.addedSessions)
        assertEquals("bark", r.snapshot.sessions.first().pronunciation?.first()?.heardAs)
        assertEquals(true, r.snapshot.sessions.last().folded)
        assertEquals("2026-09-13", r.snapshot.phrases.first().due)
        // 同じファイルをもう一度読んでも増えない
        val again = Merge.importJson(json, r.snapshot)
        assertEquals(0, again.addedSessions)
        assertEquals(1, again.snapshot.phrases.size)
        // 書き出して読み直せる（キー名が JS と同じ）
        val s = HgJson.encodeToString(ExportFile.serializer(), ExportFile.of(r.snapshot))
        assertTrue(s.contains("\"corrected_text\"") && s.contains("\"heard_as\"") && s.contains("\"last_seen\""))
        assertFalse("null は書かない", s.contains("null"))
        try { Merge.importJson("{\"format\":\"x\"}", Snapshot()); fail() } catch (e: ImportError.BadFormat) {}
        try { Merge.importJson("not json", Snapshot()); fail() } catch (e: ImportError.NotJson) {}
    }

    @Test
    fun snapshotStoreRoundTrip() {
        val f = File.createTempFile("hg-test-", ".json")
        f.delete()
        val store = SnapshotStore(f)
        val card = PhraseLogic.makePhrase(phrase = "tweak", meaning = "少し直す", today = "2026-09-27")!!
        val snap = Snapshot(phrases = listOf(card), today = Today("2026-09-27", listOf(card.id), mapOf(card.id to TodayResult(r = "hit", judge = "ai"))))
        store.save(snap)
        val back = store.load()
        assertEquals("tweak", back.phrases.first().phrase)
        assertEquals("hit", back.today?.results?.values?.first()?.r)
        f.delete()
    }

    @Test
    fun detectRealExamples() {
        assertEquals(true, PhraseLogic.detect("hog someone's food", "the kitten was hogging his food").exact)
        assertEquals(false, PhraseLogic.detect("he's on the mend", "he is on the mat now").used)
        val d = PhraseLogic.detect("connect the dots", "and then it connected it's a dot")
        assertEquals(listOf(true, false), listOf(d.used, d.exact))
    }

    @Test
    fun parseFeedbackShapes() {
        assertNull(Logic.parseFeedback("ローマ帝国は…"))
        assertNull(Logic.parseFeedback("{ \"corrected_text\": "))
        val fb = Logic.parseFeedback("```json\n{\"corrected_text\":\"Hello.\",\"issues\":[{\"type\":\"X\",\"original\":\"a\",\"suggestion\":\"b\"}],\"targets\":[{\"phrase\":\"p\",\"used\":1}]}\n```")!!
        assertEquals("Hello.", fb.correctedText)
        assertEquals("phrasing", fb.issues.first().type)
        assertEquals(true, fb.targets.first().used)
        assertEquals(false, fb.targets.first().exact)
    }

    @Test
    fun exportedAtLooksLikeJs() {
        assertTrue(Regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$").matches(ExportFile.isoNow()))
    }
}
