package jp.nishira.hitorigoto

import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File

/**
 * マイクから ①AAC の音声ファイル（Gemini に送る一次資料）と ②端末の音声認識による字幕
 * （話している最中の表示と、認識ずれの比較材料）の両方を作る。
 *
 * Android では録音（MediaRecorder）と字幕（SpeechRecognizer＝別アプリのサービス）が同じマイクを取り合う。
 * **録音を優先**し、字幕側がマイクを奪って録音が無音になったら字幕を止める。字幕が使えない機種では字幕なしで録音だけ続ける
 */
class Recorder(private val context: Context) {

    var isRecording by mutableStateOf(false); private set
    var seconds by mutableIntStateOf(0); private set
    var level by mutableFloatStateOf(0f); private set            // 0〜1。声が入っていることを見せる
    var transcript by mutableStateOf(""); private set            // 字幕の確定分
    var interim by mutableStateOf(""); private set               // 字幕の未確定分
    var captionsAvailable by mutableStateOf(false); private set
    var inputName by mutableStateOf(""); private set             // 今使っているマイクの名前
    var inputDetail by mutableStateOf(""); private set           // 入力の形式（例: 16000 Hz・1ch）
    var micSilent by mutableStateOf(false); private set          // しばらく音が入っていない
    var engineNote by mutableStateOf(""); private set            // 字幕を止めたなど、起きたこと（空なら順調）

    companion object {
        /** 録音した音声（AAC / m4a）。Gemini の inlineData には audio/mp4 で渡す（iOS と同じ） */
        const val mimeType = "audio/mp4"
        const val sampleRate = 16000
        /** MediaRecorder.maxAmplitude（0〜32767）がこれ以上なら「音が入っている」（−44dB ほど） */
        private const val soundAmplitude = 200
        /** 音が無いまま、この秒数たったら知らせる */
        private const val silentAfterMs = 6000L
    }

    class Result(val audio: File, val transcript: String, val seconds: Int, val peakAmplitude: Int)

    class Failure(message: String) : Exception(message)

    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var recorder: MediaRecorder? = null
    private var file: File? = null
    private var startedAt = 0L
    private var lastSound = 0L
    private var peak = 0
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var meterJob: Job? = null
    private var usingBluetooth = false

    private var recognizer: SpeechRecognizer? = null
    private var wantCaptions = false
    private var captionLanguage = ""
    private var captionErrors = 0
    private var captionGotText = false
    private var triedCloud = false

    // ---- 開始・停止 ----

    /** 録音を始める（マイクの許可は呼ぶ側が取っておく）。メインスレッドから呼ぶ */
    suspend fun start(captions: Boolean, language: String) {
        if (isRecording) return
        transcript = ""; interim = ""; seconds = 0; level = 0f
        micSilent = false; engineNote = ""; peak = 0
        captionErrors = 0; captionGotText = false; triedCloud = false
        wantCaptions = captions; captionLanguage = language

        usingBluetooth = routeToBluetooth()
        if (usingBluetooth) delay(900)   // SCO のつながりを待つ（すぐ録ると内蔵マイクで始まる）
        updateInputName()

        val f = File(context.cacheDir, "hitorigoto-${System.currentTimeMillis()}.m4a")
        val r = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else @Suppress("DEPRECATION") MediaRecorder()
        try {
            // 16kHz モノラル 32kbps の AAC。5 分で 1.2MB ほど（iOS と同じ）
            r.setAudioSource(if (usingBluetooth) MediaRecorder.AudioSource.VOICE_COMMUNICATION else MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioSamplingRate(sampleRate)
            r.setAudioChannels(1)
            r.setAudioEncodingBitRate(32000)
            r.setOutputFile(f.path)
            r.prepare()
            r.start()
        } catch (e: Exception) {
            try { r.release() } catch (_: Exception) {}
            f.delete()
            clearBluetooth()
            throw Failure(e.message ?: e.javaClass.simpleName)
        }
        recorder = r
        file = f
        inputDetail = "$sampleRate Hz・1ch"
        isRecording = true
        startedAt = System.currentTimeMillis()
        lastSound = 0L
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        meterJob = scope.launch { meter() }
        if (captions) startCaptions()
    }

    /** 音量と経過時間。MediaRecorder は「前回から今までのピーク」しか教えてくれないので 100ms ごとに読む */
    private suspend fun meter() {
        var tick = 0
        while (scope.isActive && isRecording) {
            val amp = try { recorder?.maxAmplitude ?: 0 } catch (e: Exception) { 0 }
            if (amp > peak) peak = amp
            level = minOf(1f, amp / 32767f * 3f)
            val now = System.currentTimeMillis()
            if (amp >= soundAmplitude) { lastSound = now; if (micSilent) micSilent = false }
            if (tick % 10 == 0) {
                seconds = ((now - startedAt) / 1000).toInt()
                val silent = now - (if (lastSound == 0L) startedAt else lastSound) >= silentAfterMs
                if (silent && !micSilent) {
                    micSilent = true
                    // 字幕側がマイクを奪っている疑い（字幕は文字が出ているのに録音は無音）。録音を優先して字幕を止める
                    if (recognizer != null && captionGotText) {
                        stopCaptions()
                        captionsAvailable = false
                        engineNote = context.getString(R.string.captions_stopped_for_recording)
                    }
                }
            }
            tick++
            delay(100)
        }
    }

    suspend fun stop(): Result? {
        if (!isRecording) return null
        isRecording = false
        meterJob?.cancel(); meterJob = null
        val tail = finishCaptions()
        val r = recorder; recorder = null
        var ok = true
        try { r?.stop() } catch (e: Exception) { ok = false }
        try { r?.release() } catch (_: Exception) {}
        clearBluetooth()
        level = 0f; micSilent = false
        val f = file; file = null
        if (f == null || !ok || !f.exists() || f.length() == 0L) { f?.delete(); return null }
        val text = (transcript + (if (tail.isEmpty()) "" else tail + "\n")).trim()
        return Result(f, text, seconds, peak)
    }

    // ---- マイク（Bluetooth イヤホン） ----

    /** Bluetooth イヤホン（SCO）がつながっていれば、そのマイクに切り替える。なければ内蔵マイクのまま */
    private fun routeToBluetooth(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= 31) {
                val dev = audioManager.availableCommunicationDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
                    ?: return false
                audioManager.setCommunicationDevice(dev)
            } else {
                val has = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS).any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
                if (!has || !audioManager.isBluetoothScoAvailableOffCall) return false
                @Suppress("DEPRECATION") audioManager.startBluetoothSco()
                @Suppress("DEPRECATION") audioManager.isBluetoothScoOn = true
                true
            }
        } catch (e: Exception) { false }
    }

    private fun clearBluetooth() {
        if (!usingBluetooth) return
        usingBluetooth = false
        try {
            if (Build.VERSION.SDK_INT >= 31) audioManager.clearCommunicationDevice()
            else { @Suppress("DEPRECATION") audioManager.stopBluetoothSco(); @Suppress("DEPRECATION") audioManager.isBluetoothScoOn = false }
        } catch (_: Exception) {}
    }

    private fun updateInputName() {
        inputName = try {
            val devs = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
            val chosen = if (usingBluetooth) devs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
                else devs.firstOrNull { it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET }
                    ?: devs.firstOrNull { it.type == AudioDeviceInfo.TYPE_USB_HEADSET || it.type == AudioDeviceInfo.TYPE_USB_DEVICE }
                    ?: devs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }
            chosen?.let { deviceLabel(it) } ?: ""
        } catch (e: Exception) { "" }
    }

    private fun deviceLabel(d: AudioDeviceInfo): String = when (d.type) {
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> context.getString(R.string.mic_builtin)
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> d.productName.toString().ifEmpty { "Bluetooth" }
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> context.getString(R.string.mic_wired)
        AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE -> d.productName.toString().ifEmpty { "USB" }
        else -> d.productName.toString()
    }

    /** 今つながっている入力の名前（録音前の表示用） */
    fun currentInputName(): String {
        val devs = try { audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS) } catch (e: Exception) { return "" }
        val d = devs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
            ?: devs.firstOrNull { it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET }
            ?: devs.firstOrNull { it.type == AudioDeviceInfo.TYPE_USB_HEADSET || it.type == AudioDeviceInfo.TYPE_USB_DEVICE }
            ?: devs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC } ?: return ""
        return deviceLabel(d)
    }

    // ---- 字幕（端末の音声認識） ----

    private fun startCaptions() {
        if (!SpeechRecognizer.isRecognitionAvailable(context)) { captionsAvailable = false; return }
        val r = try {
            if (Build.VERSION.SDK_INT >= 31 && !triedCloud && SpeechRecognizer.isOnDeviceRecognitionAvailable(context))
                SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            else SpeechRecognizer.createSpeechRecognizer(context)
        } catch (e: Exception) { captionsAvailable = false; return }
        recognizer = r
        captionsAvailable = true
        r.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {
                if (recognizer !== r) return
                val t = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: return
                if (t.isNotEmpty()) { interim = t; captionGotText = true }
            }
            override fun onResults(results: Bundle?) {
                if (recognizer !== r) return
                val t = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""
                if (t.isNotEmpty()) { transcript += t + "\n"; captionGotText = true }
                interim = ""
                captionErrors = 0
                if (wantCaptions && isRecording) listen(r)
            }
            override fun onError(error: Int) {
                if (recognizer !== r) return
                if (interim.isNotEmpty()) { transcript += interim + "\n"; interim = "" }
                when (error) {
                    SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> {
                        // 黙っていただけ。張り直す
                        if (wantCaptions && isRecording) scope.launch { delay(200); if (recognizer === r && isRecording) listen(r) }
                    }
                    12, 13 -> {
                        // 端末内の認識がこの言語に対応していない（LANGUAGE_NOT_SUPPORTED / UNAVAILABLE）。クラウドの認識で 1 回だけ試す
                        stopCaptions()
                        if (!triedCloud && wantCaptions && isRecording) { triedCloud = true; startCaptions() } else captionsAvailable = false
                    }
                    else -> {
                        captionErrors++
                        if (captionErrors >= 3) { stopCaptions(); captionsAvailable = false }
                        else if (wantCaptions && isRecording) scope.launch { delay(500); if (recognizer === r && isRecording) listen(r) }
                    }
                }
            }
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        listen(r)
    }

    private fun listen(r: SpeechRecognizer) {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, captionLanguage)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
        }
        try { r.startListening(intent) } catch (e: Exception) { captionsAvailable = false }
    }

    private fun stopCaptions() {
        val r = recognizer ?: return
        recognizer = null
        try { r.cancel(); r.destroy() } catch (_: Exception) {}
    }

    /** 停止時：最後の未確定分を短く待って拾う */
    private suspend fun finishCaptions(): String {
        val r = recognizer ?: return ""
        wantCaptions = false
        try { r.stopListening() } catch (_: Exception) {}
        delay(700)
        val tail = interim
        interim = ""
        stopCaptions()
        return tail
    }
}
