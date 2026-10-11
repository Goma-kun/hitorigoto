package jp.nishira.hitorigoto.core

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/** 読み書きに使う JSON の設定。null は省き（Swift の nil と同じ）、既定値は書く（JS と同じ） */
@OptIn(ExperimentalSerializationApi::class)
val HgJson: Json = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    explicitNulls = false
    coerceInputValues = true
}

/** 読みやすい形で書き出すとき（記録の書き出し） */
@OptIn(ExperimentalSerializationApi::class)
val HgJsonPretty: Json = Json(from = HgJson) { prettyPrint = true }

/**
 * 記録の入れ物。**拡張機能の chrome.storage.local と同じ形のまま持つ。**
 * 書き出し／読み込み（hitorigoto-english-v1）が拡張機能・iOS とそのまま行き来できる
 */
@Serializable
data class Snapshot(
    val sessions: List<Session> = emptyList(),
    val recurring: List<Recurring> = emptyList(),
    val phrases: List<PhraseCard> = emptyList(),
    val today: Today? = null,
)

/** 書き出しファイル（拡張機能の exportEnglishJson と同じ形） */
@Serializable
data class ExportFile(
    val format: String = "",
    @SerialName("exported_at") val exportedAt: String = "",
    val sessions: List<Session> = emptyList(),
    val recurring: List<Recurring> = emptyList(),
    val phrases: List<PhraseCard>? = null,
) {
    companion object {
        const val format = "hitorigoto-english-v1"
        val acceptedFormats = listOf("hitorigoto-english-v1", "mamorukun-english-v1")

        /** JS の `new Date().toISOString()` と同じ形（ミリ秒つき・UTC） */
        fun isoNow(now: Instant = Instant.now()): String =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC).format(now)

        fun of(snapshot: Snapshot, now: Instant = Instant.now()) = ExportFile(
            format = format, exportedAt = isoNow(now),
            sessions = snapshot.sessions, recurring = snapshot.recurring, phrases = snapshot.phrases,
        )
    }
}

sealed class ImportError(message: String) : Exception(message) {
    class NotJson : ImportError("notJson")
    class BadFormat : ImportError("badFormat")
}

object Merge {
    internal fun normKey(s: String) = Logic.collapseSpaces(s.lowercase())

    /** 同じ id のセッションは二重に増やさない。新しい順を保つ */
    fun sessions(current: List<Session>, incoming: List<Session>): List<Session> {
        val seen = current.map { it.id }.toSet()
        val added = incoming.filter { it.id.isNotEmpty() && it.id !in seen }
        return (current + added).sortedByDescending { it.id }
    }

    /** 同じ文言なら回数の大きい方 */
    fun recurring(current: List<Recurring>, incoming: List<Recurring>): List<Recurring> {
        val order = ArrayList<String>()
        val map = HashMap<String, Recurring>()
        for (r in current) { val k = normKey(r.text); if (k !in map) order.add(k); map[k] = r }
        for (r in incoming) {
            if (r.text.isEmpty()) continue
            val k = normKey(r.text)
            val cur = map[k]
            if (cur != null) {
                map[k] = cur.copy(count = maxOf(cur.count, r.count), lastSeen = if (r.lastSeen > cur.lastSeen) r.lastSeen else cur.lastSeen)
            } else { order.add(k); map[k] = r }
        }
        return order.mapNotNull { map[it] }
    }

    /** 同じ表現なら履歴の長い方 */
    fun phrases(current: List<PhraseCard>, incoming: List<PhraseCard>): List<PhraseCard> {
        val order = ArrayList<String>()
        val map = HashMap<String, PhraseCard>()
        for (p in current) { val k = normKey(p.phrase); if (k !in map) order.add(k); map[k] = p }
        for (p in incoming) {
            if (p.phrase.isEmpty()) continue
            val k = normKey(p.phrase)
            val cur = map[k]
            if (cur != null) {
                if (p.history.size > cur.history.size) map[k] = p
            } else { order.add(k); map[k] = p }
        }
        return order.mapNotNull { map[it] }.map(PhraseLogic::rebuild)
    }

    data class ImportResult(val snapshot: Snapshot, val addedSessions: Int)

    /** 読み込み。混ぜたあとの記録と、追加されたセッション数を返す */
    fun importJson(text: String, into: Snapshot): ImportResult {
        val file = try { HgJson.decodeFromString(ExportFile.serializer(), text) } catch (e: Exception) { throw ImportError.NotJson() }
        if (file.format !in ExportFile.acceptedFormats) throw ImportError.BadFormat()
        val before = into.sessions.size
        val out = into.copy(
            sessions = sessions(into.sessions, file.sessions),
            recurring = recurring(into.recurring, file.recurring),
            phrases = phrases(into.phrases, file.phrases ?: emptyList()),
        )
        return ImportResult(out, out.sessions.size - before)
    }
}

/** 端末のディスクに置く。アプリ専用領域の中の 1 ファイル（`filesDir/Hitorigoto/snapshot.json`） */
class SnapshotStore(private val file: File) {

    fun load(): Snapshot {
        if (!file.exists()) return Snapshot()
        val s = HgJson.decodeFromString(Snapshot.serializer(), file.readText())
        // 読み込んだ表現は履歴から状態を組み立て直す（取り込んだ JSON の due や hits が古くても正しくなる）
        return s.copy(phrases = s.phrases.map(PhraseLogic::rebuild))
    }

    /** 書き込みは一時ファイル経由。途中で落ちても、読めないファイルを残さない */
    fun save(snapshot: Snapshot) {
        file.parentFile?.mkdirs()
        val tmp = File(file.path + ".tmp")
        tmp.writeText(HgJson.encodeToString(Snapshot.serializer(), snapshot))
        Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }
}
