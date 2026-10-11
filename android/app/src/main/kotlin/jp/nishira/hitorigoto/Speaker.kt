package jp.nishira.hitorigoto

import android.content.Context
import android.media.AudioAttributes
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import jp.nishira.hitorigoto.core.TargetLanguage
import java.util.Locale

/**
 * 文を端末の声で読み上げる。**端末の中だけで鳴る**ので、通信もお金もかからない。
 * 速さは既定で少しゆっくり。真似して口に出すのが目的で、聞き流すためではない。
 * **録音中は鳴らさない**（自分の声に混ざるため。呼ぶ側で止めている）
 */
class Speaker(context: Context) {
    private var ready = false
    private var queued: String? = null
    private var lastId = 0

    /** いま読み上げている文。同じ文をもう一度押したら止める・ボタンの絵を変えるのに使う */
    var speaking by mutableStateOf<String?>(null)
        private set

    /** 読み上げる言語（設定「話す言語」に合わせて AppModel が入れる） */
    var language: String = TargetLanguage.default.locale
        set(v) { field = v; if (ready) applyLanguage() }

    var rate: Float = 0.85f

    private val tts: TextToSpeech = TextToSpeech(context.applicationContext) { status ->
        ready = status == TextToSpeech.SUCCESS
        if (ready) {
            applyLanguage()
            tts.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            queued?.let { queued = null; toggle(it) }
        }
    }

    init {
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) { if (utteranceId == lastId.toString()) speaking = null }
            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) { speaking = null }
            override fun onError(utteranceId: String?, errorCode: Int) { speaking = null }
        })
    }

    private fun applyLanguage() {
        tts.language = Locale.forLanguageTag(language)
    }

    /** 押すたびに「読む／止める」。別の文を押したら、前のを止めてそちらを読む */
    fun toggle(text: String) {
        val t = text.trim()
        if (t.isEmpty()) return
        if (speaking == t) { stop(); return }
        stop()
        if (!ready) { queued = t; speaking = t; return }
        tts.setSpeechRate(rate)
        lastId++
        speaking = t
        tts.speak(t, TextToSpeech.QUEUE_FLUSH, Bundle(), lastId.toString())
    }

    fun stop() {
        queued = null
        if (ready && tts.isSpeaking) tts.stop()
        speaking = null
    }

    fun shutdown() { stop(); tts.shutdown() }
}
