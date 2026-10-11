package jp.nishira.hitorigoto.core.probe

import jp.nishira.hitorigoto.core.HgJson
import jp.nishira.hitorigoto.core.Issue
import jp.nishira.hitorigoto.core.Logic
import jp.nishira.hitorigoto.core.Merge
import jp.nishira.hitorigoto.core.PhraseCard
import jp.nishira.hitorigoto.core.PhraseLogic
import jp.nishira.hitorigoto.core.Prompts
import jp.nishira.hitorigoto.core.Recurring
import jp.nishira.hitorigoto.core.Session
import jp.nishira.hitorigoto.core.Snapshot
import jp.nishira.hitorigoto.core.Target
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.system.exitProcess

// JS 版と答えを突き合わせるためだけの入口（iOS の hg-probe と同じ入出力）。
// 標準入力に {"cases":[...]} を受け取り、1 件ずつ Core を呼んで結果を JSON で返す。
// アプリからは使わない。../../test/parity_android.mjs が使う

private fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
private fun JsonElement?.int(): Int? = (this as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toDoubleOrNull()?.toInt()
private fun JsonElement?.bool(): Boolean? = (this as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toBooleanStrictOrNull()
private fun <T> JsonElement?.decode(s: KSerializer<T>): T? = this?.let { if (it is JsonNull) null else HgJson.decodeFromJsonElement(s, it) }
private fun <T> T.encode(s: KSerializer<T>): JsonElement = HgJson.encodeToJsonElement(s, this)

private fun run(c: JsonObject): JsonElement {
    val recurringS = ListSerializer(Recurring.serializer())
    val issuesS = ListSerializer(Issue.serializer())
    val cardsS = ListSerializer(PhraseCard.serializer())
    return when (c["fn"].str() ?: "") {
        "prompts" -> buildJsonObject { put("system", Prompts.system); put("audio", Prompts.audio) }
        "parseFeedback" -> Logic.parseFeedback(c["raw"].str())?.encode(jp.nishira.hitorigoto.core.Feedback.serializer()) ?: JsonNull
        "promoteRecurring" -> Logic.promoteRecurring(c["prev"].decode(recurringS) ?: emptyList(), c["issues"].decode(issuesS) ?: emptyList(),
            c["today"].str() ?: "").encode(recurringS)
        "topRecurring" -> Logic.topRecurring(c["list"].decode(recurringS) ?: emptyList(), c["limit"].int() ?: Logic.recurringSend,
            c["min"].int() ?: Logic.recurringMin).encode(recurringS)
        "foldSessions" -> Logic.foldSessions(c["sessions"].decode(ListSerializer(Session.serializer())) ?: emptyList(),
            c["keepFull"].int() ?: Logic.keepFull, c["keepTotal"].int() ?: Logic.keepTotal).encode(ListSerializer(Session.serializer()))
        "userMessage" -> {
            val rec = c["recurring"].decode(recurringS) ?: emptyList()
            val extra = c["extra"].str() ?: ""
            if (c["audio"].bool() == true) JsonPrimitive(Logic.buildEnglishAudioUserMessage(c["text"].str() ?: "", rec, extra))
            else JsonPrimitive(Logic.buildEnglishUserMessage(c["text"].str() ?: "", rec, extra))
        }
        "sessionText" -> {
            val s = c["session"].decode(Session.serializer())!!
            val L = c["labels"] as? JsonObject ?: JsonObject(emptyMap())
            val types = (L["types"] as? JsonObject)?.mapValues { it.value.str() ?: "" } ?: emptyMap()
            JsonPrimitive(Logic.buildSessionText(s, Logic.Labels(L["corrected"].str() ?: "", L["issues"].str() ?: "",
                L["good"].str() ?: "", L["said"].str() ?: "", L["pron"].str() ?: "", types)))
        }
        "addDays" -> JsonPrimitive(PhraseLogic.addDays(c["date"].str() ?: "", c["n"].int() ?: 0))
        "daysBetween" -> JsonPrimitive(PhraseLogic.daysBetween(c["from"].str() ?: "", c["to"].str() ?: ""))
        "parsePhraseLine" -> PhraseLogic.parsePhraseLine(c["line"].str() ?: "")?.let { buildJsonObject { put("phrase", it.first); put("meaning", it.second) } } ?: JsonNull
        "detect" -> {
            val d = PhraseLogic.detect(c["phrase"].str() ?: "", c["text"].str() ?: "")
            buildJsonObject { put("used", d.used); put("exact", d.exact); put("asSaid", d.asSaid) }
        }
        "rebuild" -> PhraseLogic.rebuild(c["card"].decode(PhraseCard.serializer())!!).encode(PhraseCard.serializer())
        "setSpeechResult" -> PhraseLogic.setSpeechResult(c["card"].decode(PhraseCard.serializer())!!, c["today"].str() ?: "",
            c["result"].str() ?: "", c["asSaid"].str() ?: "").encode(PhraseCard.serializer())
        "setRecallResult" -> PhraseLogic.setRecallResult(c["card"].decode(PhraseCard.serializer())!!, c["today"].str() ?: "",
            c["ok"].bool() ?: false).encode(PhraseCard.serializer())
        "setManualStatus" -> PhraseLogic.setManualStatus(c["card"].decode(PhraseCard.serializer())!!, c["status"].str() ?: "",
            c["today"].str() ?: "").encode(PhraseCard.serializer())
        "pickToday" -> {
            val picked = PhraseLogic.pickToday(c["list"].decode(cardsS) ?: emptyList(), c["today"].str() ?: "",
                c["total"].int() ?: PhraseLogic.defaultTotal, c["maxNew"].int() ?: PhraseLogic.defaultNew,
                (c["fixedIds"] as? JsonArray)?.mapNotNull { it.str() } ?: emptyList())
            JsonArray(picked.map { JsonPrimitive(it.id) })
        }
        "mergeAiTargets" -> {
            val cards = c["cards"].decode(cardsS) ?: emptyList()
            val ai = c["ai"].decode(ListSerializer(Target.serializer())) ?: emptyList()
            val judged = PhraseLogic.mergeAiTargets(PhraseLogic.judge(cards, c["text"].str() ?: ""), cards, ai)
            // JS の judgePhrases は note を持たない（AI が触れたものだけ note が付く）
            JsonArray(judged.map { j ->
                buildJsonObject {
                    put("id", j.id); put("result", j.result); put("asSaid", j.asSaid); put("judge", j.judge)
                    if (j.judge == "ai") put("note", j.note)
                }
            })
        }
        "targetsSection" -> JsonPrimitive(PhraseLogic.targetsSection(c["cards"].decode(cardsS) ?: emptyList()))
        "stats" -> {
            val s = PhraseLogic.stats(c["list"].decode(cardsS) ?: emptyList())
            buildJsonObject { put("total", s.total); put("active", s.active); put("fresh", s.fresh); put("graduated", s.graduated) }
        }
        "marks" -> JsonPrimitive(PhraseLogic.marks(c["card"].decode(PhraseCard.serializer())!!))
        "importJson" -> {
            val snap = c["snapshot"].decode(Snapshot.serializer()) ?: Snapshot()
            try {
                val r = Merge.importJson(c["json"].str() ?: "", snap)
                buildJsonObject { put("sessions", r.addedSessions); put("recurring", r.snapshot.recurring.size); put("phrases", r.snapshot.phrases.size) }
            } catch (e: Exception) { buildJsonObject { put("error", e.message ?: "error") } }
        }
        else -> buildJsonObject { put("error", "unknown fn ${c["fn"].str()}") }
    }
}

fun main() {
    val input = System.`in`.readBytes().toString(Charsets.UTF_8)
    val obj = try { HgJson.parseToJsonElement(input) as? JsonObject } catch (e: Exception) { null }
    val cases = obj?.get("cases") as? JsonArray
    if (cases == null) { System.err.println("NG: 入力が読めません"); exitProcess(1) }
    val results = JsonArray(cases.map { run(it as JsonObject) })
    print(HgJson.encodeToString(JsonObject.serializer(), buildJsonObject { put("results", results) }))
}
