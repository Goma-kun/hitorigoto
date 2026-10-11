package jp.nishira.hitorigoto.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.Base64

/**
 * Gemini API を呼ぶ。拡張機能の ai-providers.js（createGeminiProvider）・iOS の GeminiClient.swift と
 * 同じ送り方・同じエラー分類。**通信は同期**（純 JVM で済ませるため）。呼ぶ側が IO スレッドで回す
 */
class GeminiClient(val transport: Transport) {

    companion object {
        /** モデルは拡張機能・まもるくんと揃える */
        const val model = "gemini-3.6-flash"
        /** inlineData で送れる全体上限（20MB）に対する安全側の目安 */
        const val audioMaxBytes = 18 * 1024 * 1024
        private const val timeoutMs = 120_000
    }

    /** 送り先。Direct＝自分のキーで Gemini へ直接／Relay＝開発者の中継サーバー（キー不要・回数制限あり） */
    sealed class Transport {
        data class Direct(val key: String) : Transport()
        data class Relay(val url: String, val deviceId: String, val appKey: String) : Transport()
    }

    constructor(key: String) : this(Transport.Direct(key))

    /** 直近の中継サーバーの返事に付いていた回数（used, limit）。直接のときは null */
    data class Quota(val used: Int, val limit: Int) { val remaining: Int get() = maxOf(0, limit - used) }

    sealed class Failure(message: String = "") : Exception(message) {
        object NoKey : Failure()
        object KeyInvalid : Failure()
        object ProjectDenied : Failure()      // 403 + denied access（無料枠が割り当てられていないプロジェクト）
        object RateLimited : Failure()
        class Server(val detail: String) : Failure(detail)
        class Network(val detail: String) : Failure(detail)
        object Parse : Failure()              // JSON として読めない応答
        object Audio : Failure()              // 音声が空・大きすぎる
        object Silent : Failure()             // 音声に聞き取れる発話が無かった
        class Quota(val used: Int, val limit: Int) : Failure()   // 中継サーバーの無料回数を使い切った
        object RelayBusy : Failure()          // 中継サーバーの全体の上限
    }

    private val endpoint: String get() = when (transport) {
        is Transport.Direct -> "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent"
        is Transport.Relay -> transport.url.trimEnd('/') + "/v1/review"
    }

    private fun open(url: String, method: String, timeout: Int): HttpURLConnection {
        val c = URL(url).openConnection() as HttpURLConnection
        c.requestMethod = method
        c.connectTimeout = timeout
        c.readTimeout = timeout
        when (transport) {
            is Transport.Direct -> c.setRequestProperty("x-goog-api-key", transport.key)   // キーは URL ではなくヘッダーで渡す
            is Transport.Relay -> {
                c.setRequestProperty("x-device-id", transport.deviceId)
                c.setRequestProperty("x-app-key", transport.appKey)
            }
        }
        return c
    }

    private fun readAll(c: HttpURLConnection): Pair<Int, String> {
        val status = c.responseCode
        val stream = if (status >= 400) c.errorStream else c.inputStream
        val text = stream?.use { s -> ByteArrayOutputStream().also { s.copyTo(it) }.toString(Charsets.UTF_8) } ?: ""
        return status to text
    }

    /** Gemini へ送り、返事の本文（text パートをつないだもの）を返す */
    internal fun call(body: JsonObject): String {
        if (transport is Transport.Direct && transport.key.isEmpty()) throw Failure.NoKey
        val c = open(endpoint, "POST", timeoutMs)
        c.doOutput = true
        c.setRequestProperty("Content-Type", "application/json")
        val status: Int; val text: String
        try {
            c.outputStream.use { it.write(HgJson.encodeToString(JsonObject.serializer(), body).toByteArray(Charsets.UTF_8)) }
            val r = readAll(c); status = r.first; text = r.second
        } catch (e: IOException) {
            throw Failure.Network(e.message ?: e.javaClass.simpleName)
        } finally { c.disconnect() }

        val json = try { Json.parseToJsonElement(text) as? JsonObject } catch (e: Exception) { null }
        val err = json?.get("error") as? JsonObject
        if (status !in 200..299 || err != null) {
            val msg = (err?.get("message") as? JsonPrimitive)?.content ?: ""
            // 中継サーバーの返事は code で見分ける
            if (transport is Transport.Relay) {
                when ((err?.get("code") as? JsonPrimitive)?.content) {
                    "quota" -> throw Failure.Quota(err?.get("used")?.jsonPrimitive?.content?.toIntOrNull() ?: 0,
                        err?.get("limit")?.jsonPrimitive?.content?.toIntOrNull() ?: 0)
                    "busy" -> throw Failure.RelayBusy
                    "forbidden", "device" -> throw Failure.Server(msg)
                }
            }
            throw classify(status, msg)
        }
        val cands = json?.get("candidates") as? JsonArray ?: return ""
        val content = cands.firstOrNull()?.jsonObject?.get("content") as? JsonObject ?: return ""
        val parts = content["parts"] as? JsonArray ?: return ""
        return parts.mapNotNull { (it.jsonObject["text"] as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }.joinToString("")
    }

    private fun classify(status: Int, message: String): Failure {
        val lower = message.lowercase()
        return when {
            status == 403 && (lower.contains("denied access") || lower.contains("permission_denied")) -> Failure.ProjectDenied
            status == 400 || status == 401 ->
                if (lower.contains("api key") || lower.contains("api_key") || lower.contains("invalid")) Failure.KeyInvalid
                else Failure.Server(message.ifEmpty { "HTTP $status" })
            status == 403 -> Failure.KeyInvalid
            status == 429 -> Failure.RateLimited
            else -> Failure.Server(message.ifEmpty { "HTTP $status" })
        }
    }

    private fun generationConfig(responseJson: Boolean) = buildJsonObject {
        putJsonObject("thinkingConfig") { put("thinkingLevel", "low") }
        if (responseJson) put("responseMimeType", "application/json")
    }

    /** テキストだけで添削する */
    fun reviewEnglish(text: String, recurring: List<Recurring>, extra: String = "", system: String = Prompts.system): Feedback {
        val raw = call(buildJsonObject {
            putJsonObject("systemInstruction") { putJsonArray("parts") { add(buildJsonObject { put("text", system) }) } }
            putJsonArray("contents") {
                add(buildJsonObject {
                    put("role", "user")
                    putJsonArray("parts") { add(buildJsonObject { put("text", Logic.buildEnglishUserMessage(text, recurring, extra)) }) }
                })
            }
            put("generationConfig", generationConfig(false))
            put("tools", buildJsonArray { })
        })
        return Logic.parseFeedback(raw) ?: throw Failure.Parse
    }

    /**
     * 音声そのものを渡して、書き起こしと添削を一度にやらせる。
     * asrTranscript は端末の音声認識結果（比較材料）。空でもよい
     */
    fun reviewEnglishAudio(audio: ByteArray, mimeType: String, asrTranscript: String,
                           recurring: List<Recurring>, extra: String = "", system: String = Prompts.audio): Feedback {
        if (audio.isEmpty() || audio.size > audioMaxBytes) throw Failure.Audio
        val raw = call(buildJsonObject {
            putJsonObject("systemInstruction") { putJsonArray("parts") { add(buildJsonObject { put("text", system) }) } }
            putJsonArray("contents") {
                add(buildJsonObject {
                    put("role", "user")
                    putJsonArray("parts") {
                        add(buildJsonObject {
                            putJsonObject("inlineData") { put("mimeType", mimeType); put("data", Base64.getEncoder().encodeToString(audio)) }
                        })
                        add(buildJsonObject { put("text", Logic.buildEnglishAudioUserMessage(asrTranscript, recurring, extra)) })
                    }
                })
            }
            put("generationConfig", generationConfig(true))
            put("tools", buildJsonArray { })
        })
        val fb = Logic.parseFeedback(raw) ?: throw Failure.Parse
        // 音声に聞き取れる発話が無かった（無音・雑音）。AI が作った結果を出さない
        if (fb.transcript.isEmpty()) throw Failure.Silent
        return fb
    }

    /** 中継サーバーの今日の残り回数を聞く（Direct のときは null） */
    fun quota(): Quota? {
        val t = transport as? Transport.Relay ?: return null
        return try {
            val c = open(t.url.trimEnd('/') + "/v1/quota", "GET", 15_000)
            val (_, text) = try { readAll(c) } finally { c.disconnect() }
            val j = Json.parseToJsonElement(text) as? JsonObject ?: return null
            val used = j["used"]?.jsonPrimitive?.content?.toIntOrNull() ?: return null
            val limit = j["limit"]?.jsonPrimitive?.content?.toIntOrNull() ?: return null
            Quota(used, limit)
        } catch (e: Exception) { null }
    }

    /** 設定画面の接続テスト。**本番と同じ指定**（thinkingLevel low ＋ tools）で投げる */
    fun testConnection() {
        call(buildJsonObject {
            putJsonArray("contents") {
                add(buildJsonObject { put("role", "user"); putJsonArray("parts") { add(buildJsonObject { put("text", "ping") }) } })
            }
            put("generationConfig", generationConfig(false))
            put("tools", buildJsonArray { })
        })
    }
}
