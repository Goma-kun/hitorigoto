package jp.nishira.hitorigoto

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import jp.nishira.hitorigoto.core.PhraseLogic
import jp.nishira.hitorigoto.core.SnapshotStore
import jp.nishira.hitorigoto.core.TargetLanguage
import java.io.File
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** 端末ごとの設定（iOS の UserDefaults に当たる）。Gemini キーと端末 ID は Keychain 相当（SecureStore） */
class Prefs(context: Context) {
    private val p: SharedPreferences = context.getSharedPreferences("hitorigoto", Context.MODE_PRIVATE)

    var dailyTotal: Int
        get() = p.getInt("dailyTotal", PhraseLogic.defaultTotal)
        set(v) = p.edit().putInt("dailyTotal", v).apply()

    var dailyNew: Int
        get() = p.getInt("dailyNew", PhraseLogic.defaultNew)
        set(v) = p.edit().putInt("dailyNew", v).apply()

    var captionsOn: Boolean
        get() = p.getBoolean("captionsOn", true)
        set(v) = p.edit().putBoolean("captionsOn", v).apply()

    var language: String
        get() = p.getString("language", TargetLanguage.default.code) ?: TargetLanguage.default.code
        set(v) = p.edit().putString("language", v).apply()

    /** 添削のエンジン。"cloud"＝開発者の中継サーバー経由（キー不要・既定）／"gemini"＝自分のキーで直接 */
    var engine: String
        get() = p.getString("engine", if (hasKey) "gemini" else "cloud") ?: "cloud"
        set(v) = p.edit().putString("engine", v).apply()

    /** 読み上げの速さ（TextToSpeech の rate。1.0 がふつう） */
    var voiceRate: Float
        get() = p.getFloat("voiceRate", 0.85f)
        set(v) = p.edit().putFloat("voiceRate", v).apply()

    /** 端末ごとの識別子（中継サーバーの回数制限に使う）。初回に作って保存する */
    val deviceId: String
        get() {
            p.getString("deviceId", null)?.takeIf { it.isNotEmpty() }?.let { return it }
            val v = UUID.randomUUID().toString().uppercase()
            p.edit().putString("deviceId", v).apply()
            return v
        }

    /** Gemini の API キー。端末の鍵（AndroidKeyStore）で暗号化して置く。表示もログもしない */
    var geminiKey: String?
        get() = p.getString("geminiKeyEnc", null)?.let { SecureStore.decrypt(it) }?.takeIf { it.isNotEmpty() }
        set(v) {
            val t = v?.trim() ?: ""
            if (t.isEmpty()) p.edit().remove("geminiKeyEnc").apply()
            else SecureStore.encrypt(t)?.let { p.edit().putString("geminiKeyEnc", it).apply() }
        }

    val hasKey: Boolean get() = geminiKey != null

    companion object {
        /** 保存先。iOS と同じく「Hitorigoto/snapshot.json」 */
        fun dataDir(context: Context): File = File(context.filesDir, "Hitorigoto")
        fun store(context: Context) = SnapshotStore(File(dataDir(context), "snapshot.json"))
    }
}

/**
 * Keychain 相当。AndroidKeyStore に AES 鍵を 1 本作り、AES/GCM で暗号化した文字列を SharedPreferences に置く
 * （security-crypto ライブラリは非推奨になったので自前で。鍵は端末の外へ出ない）
 */
object SecureStore {
    private const val alias = "jp.nishira.hitorigoto.secrets"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(alias, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    fun encrypt(plain: String): String? = try {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val ct = c.doFinal(plain.toByteArray(Charsets.UTF_8))
        Base64.encodeToString(c.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(ct, Base64.NO_WRAP)
    } catch (e: Exception) { null }

    fun decrypt(stored: String): String? = try {
        val (iv, ct) = stored.split(":", limit = 2)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
        String(c.doFinal(Base64.decode(ct, Base64.NO_WRAP)), Charsets.UTF_8)
    } catch (e: Exception) { null }
}
