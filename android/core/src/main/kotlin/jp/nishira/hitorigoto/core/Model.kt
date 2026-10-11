package jp.nishira.hitorigoto.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// 拡張機能の chrome.storage.local・iOS の snapshot.json と同じ形で持つ。
// 書き出し／読み込み（hitorigoto-english-v1）をそのまま通すため、キー名は JS 側と一字一句そろえる。
// null は書かない（HgJson の explicitNulls=false）。既定値（"" や 0 や []）は書く（JS と同じ）

/** 添削の指摘 1 件 */
@Serializable
data class Issue(
    val type: String,                 // phrasing | vocabulary | grammar
    val original: String? = null,     // 畳んだ古い記録には無い
    val suggestion: String,
    val reason: String? = null,
)

/** 発音で伝わらなかった箇所（音声モードだけ） */
@Serializable
data class Pronunciation(
    val said: String,
    @SerialName("heard_as") val heardAs: String,
    val note: String = "",
)

/** 「今日の狙いの表現」の AI 判定 */
@Serializable
data class Target(
    val phrase: String,
    val used: Boolean,
    val exact: Boolean,
    @SerialName("as_said") val asSaid: String = "",
    val note: String = "",
)

/** AI の応答を、表示と保存が前提にできる形に揃えたもの（JS の parseFeedback の結果） */
@Serializable
data class Feedback(
    @SerialName("corrected_text") val correctedText: String = "",
    val issues: List<Issue> = emptyList(),
    val recurring: List<String> = emptyList(),
    @SerialName("recognition_doubt") val recognitionDoubt: List<String> = emptyList(),
    val good: String = "",
    val transcript: String = "",             // 音声モードだけ
    val pronunciation: List<Pronunciation> = emptyList(),
    val targets: List<Target> = emptyList(),
)

/** 履歴に残す「その日の今日の表現の結果」 */
@Serializable
data class SessionTarget(
    val phrase: String,
    val r: String,            // hit | partial | miss | skip
    @SerialName("as") val asSaid: String = "",
)

/** 練習 1 回の記録。id は ISO 日時（新しい順に並べる） */
@Serializable
data class Session(
    val id: String,
    val folded: Boolean? = null,
    val transcript: String? = null,
    @SerialName("asr_transcript") val asrTranscript: String? = null,
    @SerialName("corrected_text") val correctedText: String? = null,
    val issues: List<Issue> = emptyList(),
    val good: String? = null,
    val pronunciation: List<Pronunciation>? = null,
    val targets: List<SessionTarget>? = null,
    /** アプリ版だけ: どのエンジンで添削したか（cloud / gemini）。拡張の記録には無い */
    val engine: String? = null,
)

/** 繰り返し出ている指摘（"original → suggestion" をキーに数える） */
@Serializable
data class Recurring(
    val text: String,
    val count: Int,
    @SerialName("last_seen") val lastSeen: String,
)

/** 表現集の 1 件の履歴（d: 日付、r: hit|partial|miss|skip|rok|rng、as: 口から出た形） */
@Serializable
data class PhraseHistory(
    val d: String,
    val r: String,
    @SerialName("as") val asSaid: String? = null,
)

/** 表現集の 1 件（phrase-core.js の makePhrase と同じ形） */
@Serializable
data class PhraseCard(
    val id: String,
    val phrase: String,
    val meaning: String = "",
    val note: String = "",
    val kind: String = "phrase",        // phrase | word
    val source: String = "manual",      // manual | issue
    val added: String = "",
    val due: String? = null,            // 卒業したら null
    val hits: Int = 0,
    val status: String = "active",      // active | graduated | archived
    val history: List<PhraseHistory> = emptyList(),
    val manual: String? = null,         // graduated | active（手で押した記録）。"" は解除
)

/** 今日の表現の判定 1 件 */
@Serializable
data class TodayResult(
    val r: String,
    @SerialName("as") val asSaid: String = "",
    val note: String = "",
    val judge: String = "auto",         // auto | ai | manual
)

/** 今日の表現（日をまたいだら選び直す） */
@Serializable
data class Today(
    val date: String,
    val ids: List<String> = emptyList(),
    val results: Map<String, TodayResult> = emptyMap(),
)

/** 判定の結果（judgePhrases の 1 件） */
data class Judged(
    val id: String,
    val result: String,
    val asSaid: String = "",
    val note: String = "",
    val judge: String = "auto",
)
