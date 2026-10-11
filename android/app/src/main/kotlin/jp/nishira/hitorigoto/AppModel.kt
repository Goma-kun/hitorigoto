package jp.nishira.hitorigoto

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import jp.nishira.hitorigoto.core.ExportFile
import jp.nishira.hitorigoto.core.Ask
import jp.nishira.hitorigoto.core.Feedback
import jp.nishira.hitorigoto.core.GeminiClient
import jp.nishira.hitorigoto.core.HgJson
import jp.nishira.hitorigoto.core.HgJsonPretty
import jp.nishira.hitorigoto.core.Issue
import jp.nishira.hitorigoto.core.Judged
import jp.nishira.hitorigoto.core.Logic
import jp.nishira.hitorigoto.core.Merge
import jp.nishira.hitorigoto.core.PhraseCard
import jp.nishira.hitorigoto.core.PhraseLogic
import jp.nishira.hitorigoto.core.Session
import jp.nishira.hitorigoto.core.SessionTarget
import jp.nishira.hitorigoto.core.Snapshot
import jp.nishira.hitorigoto.core.TargetLanguage
import jp.nishira.hitorigoto.core.Today
import jp.nishira.hitorigoto.core.TodayResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import java.io.File
import java.time.Instant
import java.util.Locale

/**
 * 画面が見ている状態のぜんぶ。記録を持ち、変わるたびに保存する。
 * 純ロジックは core（拡張機能・iOS と同じ答えを返す）。ここは画面と保存とマイクの段取りだけ（iOS の AppModel と同じ）
 */
class AppModel(app: Application) : AndroidViewModel(app) {

    val prefs = Prefs(app)
    private val store = Prefs.store(app)
    val recorder = Recorder(app)
    val speaker = Speaker(app)

    var snapshot by mutableStateOf(try { store.load() } catch (e: Exception) { Snapshot() }); private set
    var hasKey by mutableStateOf(prefs.hasKey); private set

    /** 話すタブの状態 */
    enum class Phase { IDLE, RECORDING, REVIEWING, RESULT }
    var phase by mutableStateOf(Phase.IDLE); private set
    var latest by mutableStateOf<Feedback?>(null); private set
    var latestJudged by mutableStateOf<List<Judged>>(emptyList()); private set
    /** 直近の結果を履歴と同じ形で持つ（まとめてコピー用） */
    var latestSession by mutableStateOf<Session?>(null); private set
    var errorMessage by mutableStateOf<String?>(null)
    /** 送れていない録音。**結果が出るまで消さない**（通信に失敗しても話した内容を失わせない）。ディスクにも置く */
    var pending by mutableStateOf(PendingRecording.load(app)); private set

    // 設定（SharedPreferences）
    var dailyTotal by mutableStateOf(prefs.dailyTotal); private set
    var dailyNew by mutableStateOf(prefs.dailyNew); private set
    var captionsOn by mutableStateOf(prefs.captionsOn); private set
    var language by mutableStateOf(prefs.language); private set
    var engine by mutableStateOf(prefs.engine.let { if (it == "apple") "cloud" else it }); private set
    var voiceRate by mutableStateOf(prefs.voiceRate); private set
    /** 中継サーバーの今日の回数（設定画面と話す画面に出す） */
    var quota by mutableStateOf<GeminiClient.Quota?>(null); private set

    init {
        speaker.language = language
        speaker.rate = voiceRate
    }

    fun changeDailyTotal(v: Int) { dailyTotal = v; prefs.dailyTotal = v }
    fun changeDailyNew(v: Int) { dailyNew = v; prefs.dailyNew = v }
    fun changeCaptionsOn(v: Boolean) { captionsOn = v; prefs.captionsOn = v }
    fun changeLanguage(v: String) { language = v; prefs.language = v; speaker.language = v }
    fun changeEngine(v: String) { engine = v; prefs.engine = v; refreshQuota() }
    fun changeVoiceRate(v: Float) { voiceRate = v; prefs.voiceRate = v; speaker.rate = v }

    /** 話す言語（設定）。知らない値が入っていたら既定に */
    val targetLanguage: TargetLanguage get() = TargetLanguage.of(language)

    /** 説明（reason・good）の言語。端末が日本語なら日本語、それ以外は英語 */
    val explanation: TargetLanguage.Explanation
        get() = if (Locale.getDefault().language == "ja") TargetLanguage.Explanation.JA else TargetLanguage.Explanation.EN

    val usesRelay: Boolean get() = engine != "gemini"

    private fun str(id: Int, vararg args: Any): String = getApplication<Application>().getString(id, *args)
    private fun plural(id: Int, n: Int, vararg args: Any): String = getApplication<Application>().resources.getQuantityString(id, n, *args)

    /** 今の設定で添削できるか。できないときは理由 */
    val reviewBlocker: String?
        get() {
            if (usesRelay) {
                val q = quota
                if (q != null && q.remaining == 0) return plural(R.plurals.err_quota_blocker, q.limit, q.limit)
                return null
            }
            return if (hasKey) null else str(R.string.err_need_key_blocker)
        }

    /** 中継サーバーの残り回数を取り直す */
    fun refreshQuota() {
        if (!usesRelay) { quota = null; return }
        viewModelScope.launch {
            val q = withContext(Dispatchers.IO) { GeminiClient(Relay.transport(prefs)).quota() }
            if (usesRelay) quota = q
        }
    }

    private fun save() { try { store.save(snapshot) } catch (_: Exception) {} }

    val today: String get() = Logic.todayStamp()

    // ---- 今日の表現 ----

    /** 日をまたいでいたら選び直し、決めてある分は保つ。見送りや削除で空いた枠は埋める */
    fun todayCards(): List<PhraseCard> {
        val t = today
        val cur = snapshot.today
        val fixed = if (cur?.date == t) cur.ids else emptyList()
        val cards = PhraseLogic.pickToday(snapshot.phrases, t, dailyTotal, dailyNew, fixed)
        val ids = cards.map { it.id }
        if (cur?.date != t || cur.ids != ids) {
            val results = if (cur?.date == t) cur.results else emptyMap()
            snapshot = snapshot.copy(today = Today(t, ids, results))
            save()
        }
        return cards
    }

    fun todayResult(id: String): TodayResult? {
        val cur = snapshot.today ?: return null
        if (cur.date != today) return null
        return cur.results[id]
    }

    private fun withPhrase(id: String, f: (PhraseCard) -> PhraseCard) {
        val i = snapshot.phrases.indexOfFirst { it.id == id }
        if (i < 0) return
        val list = snapshot.phrases.toMutableList()
        list[i] = f(list[i])
        snapshot = snapshot.copy(phrases = list)
    }

    private fun applyPhraseResult(id: String, result: String, asSaid: String) {
        withPhrase(id) { PhraseLogic.setSpeechResult(it, today, result, asSaid) }
    }

    private fun todayOrNew(): Today = snapshot.today?.takeIf { it.date == today } ?: Today(today)

    /** 判定結果を今日の記録と表現集の両方に入れる。同じ日に 2 回話したときは良い方を残す。手で直したものは上書きしない */
    private fun recordTodayResults(judged: List<Judged>) {
        var t = todayOrNew()
        val rank = mapOf("hit" to 3, "partial" to 2, "miss" to 1, "skip" to 0)
        for (j in judged) {
            val cur = t.results[j.id]
            if (cur?.judge == "manual") continue
            if (cur != null && (rank[cur.r] ?: 0) > (rank[j.result] ?: 0)) continue
            t = t.copy(results = t.results + (j.id to TodayResult(j.result, j.asSaid, j.note, j.judge)))
            applyPhraseResult(j.id, j.result, j.asSaid)
        }
        snapshot = snapshot.copy(today = t)
    }

    private val cycle = listOf("hit", "partial", "miss", "skip")

    /** 結果の記号をタップして直す（◎→△→✗→−→◎） */
    fun cycleTodayResult(id: String) {
        val cur = todayResult(id)
        val next = cycle[(cycle.indexOf(cur?.r ?: "skip").coerceAtLeast(0) + 1) % cycle.size]
        val t = todayOrNew()
        snapshot = snapshot.copy(today = t.copy(results = t.results + (id to TodayResult(next, cur?.asSaid ?: "", cur?.note ?: "", "manual"))))
        applyPhraseResult(id, next, cur?.asSaid ?: "")
        latestJudged = latestJudged.map { if (it.id == id) it.copy(result = next, judge = "manual") else it }
        // 履歴の最新セッションにも反映（見返したときに画面と食い違わないように）
        val card = snapshot.phrases.firstOrNull { it.id == id }
        val first = snapshot.sessions.firstOrNull()
        if (card != null && first?.targets != null) {
            val targets = first.targets!!.map { if (it.phrase == card.phrase) it.copy(r = next) else it }
            snapshot = snapshot.copy(sessions = listOf(first.copy(targets = targets)) + snapshot.sessions.drop(1))
        }
        save()
    }

    /** 見送り：今日の話に合わない表現を外す。回数に数えず、2 日あけて戻る */
    fun skipToday(id: String) {
        applyPhraseResult(id, "skip", "")
        snapshot.today?.let { t ->
            snapshot = snapshot.copy(today = t.copy(ids = t.ids.filter { it != id }, results = t.results - id))
        }
        save()
    }

    /** スクショ用（デバッグ版だけ）: 記録の先頭を「いま添削が終わった」ように見せる */
    fun showLatestSessionAsResult() {
        if (!BuildConfig.DEBUG) return
        val s = snapshot.sessions.firstOrNull() ?: return
        latest = Feedback(correctedText = s.correctedText ?: "", issues = s.issues, good = s.good ?: "",
            transcript = s.transcript ?: "", pronunciation = s.pronunciation ?: emptyList(), asks = s.asks ?: emptyList())
        latestSession = s
        latestJudged = (s.targets ?: emptyList()).mapNotNull { t ->
            val c = snapshot.phrases.firstOrNull { it.phrase == t.phrase } ?: return@mapNotNull null
            Judged(id = c.id, result = t.r, asSaid = t.asSaid, judge = "ai")
        }
        phase = Phase.RESULT
    }

    // ---- 録音と添削 ----

    /** 録音を始める（マイクの許可は画面側で取ってから呼ぶ） */
    fun startRecording() {
        errorMessage = null
        latest = null; latestJudged = emptyList()
        viewModelScope.launch {
            try {
                speaker.stop()   // 読み上げ中なら止める。録音に混ざらないように
                recorder.start(captions = captionsOn, language = language)
                phase = Phase.RECORDING
            } catch (e: Exception) {
                errorMessage = str(R.string.err_start, e.message ?: "")
            }
        }
    }

    fun stopAndReview() {
        if (phase != Phase.RECORDING) return
        viewModelScope.launch {
            val result = recorder.stop()
            if (result == null) { phase = Phase.IDLE; errorMessage = str(R.string.err_no_recording); return@launch }
            if (result.seconds < 2) { result.audio.delete(); phase = Phase.IDLE; errorMessage = str(R.string.err_too_short); return@launch }
            // まず手元に残す。ここから先で何が起きても、話した内容は消えない
            val p = withContext(Dispatchers.IO) {
                PendingRecording.create(getApplication(), result.audio, result.transcript, result.seconds, System.currentTimeMillis())
            }
            pending = p
            // 録音そのものが無音なら送らない（Gemini が架空の独り言を作る・無料枠も減る）。本人が「もう一度送る」か「捨てる」を選ぶ
            if (result.peakAmplitude < 200) {
                phase = Phase.IDLE
                val mic = recorder.inputName
                errorMessage = str(R.string.err_silent_local) + (if (mic.isEmpty()) "" else str(R.string.current_mic, mic)) + str(R.string.err_kept)
                return@launch
            }
            review()
        }
    }

    /** 手元に残っている録音を添削に出す。「もう一度送る」もここを通る */
    fun review() {
        val p = pending ?: return
        val client: GeminiClient = if (usesRelay) GeminiClient(Relay.transport(prefs)) else {
            val key = prefs.geminiKey
            if (key == null) { phase = Phase.IDLE; errorMessage = str(R.string.err_need_key_kept); return }
            GeminiClient(key)
        }
        phase = Phase.REVIEWING
        errorMessage = null
        val targetCards = todayCards()
        val extra = PhraseLogic.targetsSection(targetCards)
        val recurring = Logic.topRecurring(snapshot.recurring)
        val system = targetLanguage.audioPrompt(explanation)
        val wasRelay = usesRelay
        viewModelScope.launch {
            try {
                val fb = withContext(Dispatchers.IO) {
                    client.reviewEnglishAudio(p.audio.readBytes(), Recorder.mimeType, p.transcript, recurring, extra, system)
                }
                finish(p, fb, if (wasRelay) "cloud" else "gemini", targetCards)
            } catch (f: GeminiClient.Failure) {
                phase = Phase.IDLE
                errorMessage = message(f, recorder.inputName) + str(R.string.err_kept)
            } catch (e: Exception) {
                phase = Phase.IDLE
                errorMessage = (e.message ?: e.javaClass.simpleName) + str(R.string.err_kept)
            }
            if (wasRelay) refreshQuota()
        }
    }

    /** 添削の結果を記録に入れて画面に出す */
    private fun finish(p: PendingRecording, feedback: Feedback, engine: String, targetCards: List<PhraseCard>) {
        // 言った形と直した形が同じ「指摘」は指摘ではない（コーチが褒め言葉を指摘の枠に入れることがある）
        val issues = feedback.issues.filter { i ->
            val a = (i.original ?: "").lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }.joinToString(" ")
            val b = i.suggestion.lowercase().split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }.joinToString(" ")
            a.isEmpty() || a != b
        }
        val fb = feedback.copy(issues = issues)
        var session = Session(id = ExportFile.isoNow(Instant.ofEpochMilli(p.date)), transcript = fb.transcript,
            correctedText = fb.correctedText, issues = fb.issues, good = fb.good, engine = engine)
        if (p.transcript.isNotEmpty() && p.transcript != fb.transcript) session = session.copy(asrTranscript = p.transcript)
        if (fb.pronunciation.isNotEmpty()) session = session.copy(pronunciation = fb.pronunciation)
        if (fb.asks.isNotEmpty()) session = session.copy(asks = fb.asks)

        var judged: List<Judged> = emptyList()
        if (targetCards.isNotEmpty()) {
            judged = PhraseLogic.mergeAiTargets(PhraseLogic.judge(targetCards, fb.transcript), targetCards, fb.targets)
            recordTodayResults(judged)
            session = session.copy(targets = judged.map { j ->
                SessionTarget(targetCards.firstOrNull { it.id == j.id }?.phrase ?: "", j.result, j.asSaid)
            })
        }
        snapshot = snapshot.copy(
            sessions = Logic.foldSessions(listOf(session) + snapshot.sessions),
            recurring = Logic.promoteRecurring(snapshot.recurring, fb.issues, today),
        )
        save()
        // ここで初めて録音を手放す
        p.discard()
        pending = null
        latest = fb
        latestJudged = judged
        latestSession = session
        phase = Phase.RESULT
    }

    /** 残っている録音を捨てる（本人が押したときだけ） */
    fun discardPending() {
        pending?.discard()
        pending = null
        errorMessage = null
    }

    fun message(f: GeminiClient.Failure, mic: String = ""): String = when (f) {
        is GeminiClient.Failure.NoKey -> str(R.string.err_no_key)
        is GeminiClient.Failure.KeyInvalid -> str(R.string.err_key_invalid)
        is GeminiClient.Failure.ProjectDenied -> str(R.string.err_project_denied)
        is GeminiClient.Failure.RateLimited -> str(R.string.err_rate_limited)
        is GeminiClient.Failure.Server -> str(R.string.err_server, f.detail)
        is GeminiClient.Failure.Network -> str(R.string.err_network, f.detail)
        is GeminiClient.Failure.Parse -> str(R.string.err_parse)
        is GeminiClient.Failure.Audio -> str(R.string.err_audio)
        is GeminiClient.Failure.Quota -> plural(R.plurals.err_quota, f.limit, f.limit)
        is GeminiClient.Failure.RelayBusy -> str(R.string.err_relay_busy)
        is GeminiClient.Failure.Silent -> {
            val name = mic.ifEmpty { recorder.currentInputName() }
            str(R.string.err_silent) + (if (name.isEmpty()) "" else str(R.string.current_mic, name)) + str(R.string.check_mic)
        }
    }

    fun clearResult() {
        latest = null; latestJudged = emptyList(); latestSession = null; errorMessage = null
        if (phase == Phase.RESULT) phase = Phase.IDLE
    }

    // ---- 表現集 ----

    fun addPhrase(phrase: String, meaning: String, kind: String, source: String = "manual", note: String = ""): Boolean {
        val card = PhraseLogic.makePhrase(phrase, meaning, kind, source, today, note) ?: return false
        val r = PhraseLogic.addPhrases(snapshot.phrases, listOf(card))
        if (r.added == 0) return false
        snapshot = snapshot.copy(phrases = PhraseLogic.trim(r.list))
        save()
        return true
    }

    fun addFromIssue(issue: Issue): Boolean =
        addPhrase(issue.suggestion, "", if (issue.type == "vocabulary") "word" else "phrase", "issue", issue.original ?: "")

    /** 「日本語で言った分 → 英語ならこう」から表現集へ。意味の欄に日本語で言ったことを残す */
    fun addFromAsk(ask: Ask, way: String): Boolean = addPhrase(way, ask.said, "phrase", "issue")

    fun hasPhrase(text: String): Boolean = PhraseLogic.findPhrase(snapshot.phrases, text) != null

    fun addBulk(text: String, kind: String): Int {
        val items = PhraseLogic.parsePhraseLines(text).mapNotNull { PhraseLogic.makePhrase(it.first, it.second, kind, today = today) }
        val r = PhraseLogic.addPhrases(snapshot.phrases, items)
        snapshot = snapshot.copy(phrases = PhraseLogic.trim(r.list))
        save()
        return r.added
    }

    fun deletePhrase(id: String) {
        val t = snapshot.today
        snapshot = snapshot.copy(
            phrases = snapshot.phrases.filter { it.id != id },
            today = t?.copy(ids = t.ids.filter { it != id }, results = t.results - id),
        )
        save()
    }

    fun toggleGraduate(id: String) {
        withPhrase(id) { PhraseLogic.setManualStatus(it, if (it.status == "graduated") "active" else "graduated", today) }
        save()
    }

    fun recall(id: String, ok: Boolean) {
        withPhrase(id) { PhraseLogic.setRecallResult(it, today, ok) }
        save()
    }

    // ---- キーと記録の出し入れ ----

    fun setKey(key: String?) {
        prefs.geminiKey = key
        hasKey = prefs.hasKey
    }

    /** 接続テスト。問題なければ null、だめなら理由 */
    suspend fun testKey(key: String): String? = withContext(Dispatchers.IO) {
        try { GeminiClient(key).testConnection(); null }
        catch (f: GeminiClient.Failure) { message(f) }
        catch (e: Exception) { e.message ?: e.javaClass.simpleName }
    }

    fun exportJson(): String = HgJsonPretty.encodeToString(ExportFile.serializer(), ExportFile.of(snapshot))

    /** 読み込み。追加されたセッション数を返す。読めなければ例外 */
    fun importJson(text: String): Int {
        val r = Merge.importJson(text, snapshot)
        snapshot = r.snapshot
        save()
        return r.addedSessions
    }

    override fun onCleared() { speaker.shutdown() }
}

/** 送れていない録音。音声とメモをアプリ領域に置き、送れたら消す */
class PendingRecording(val audio: File, private val meta: File, val transcript: String, val seconds: Int, val date: Long) {

    @Serializable
    private data class Meta(val transcript: String, val seconds: Int, val date: Long)

    fun discard() { audio.delete(); meta.delete() }

    companion object {
        private fun audioFile(app: Application) = File(Prefs.dataDir(app), "pending.m4a")
        private fun metaFile(app: Application) = File(Prefs.dataDir(app), "pending.json")

        fun create(app: Application, recorded: File, transcript: String, seconds: Int, date: Long): PendingRecording {
            val dir = Prefs.dataDir(app); dir.mkdirs()
            val a = audioFile(app); val m = metaFile(app)
            if (!recorded.renameTo(a)) { recorded.copyTo(a, overwrite = true); recorded.delete() }
            m.writeText(HgJson.encodeToString(Meta.serializer(), Meta(transcript, seconds, date)))
            return PendingRecording(a, m, transcript, seconds, date)
        }

        fun load(app: Application): PendingRecording? {
            val a = audioFile(app); val m = metaFile(app)
            if (!a.exists() || a.length() == 0L || !m.exists()) return null
            val meta = try { HgJson.decodeFromString(Meta.serializer(), m.readText()) } catch (e: Exception) { return null }
            return PendingRecording(a, m, meta.transcript, meta.seconds, meta.date)
        }
    }
}
