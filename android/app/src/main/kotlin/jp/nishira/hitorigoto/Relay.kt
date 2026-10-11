package jp.nishira.hitorigoto

import jp.nishira.hitorigoto.core.GeminiClient

/**
 * 開発者の中継サーバー（Cloudflare Worker・`../server/`）。ユーザーは API キーを持たなくてよい。
 * 音声はここを経由して Gemini に送られる。回数は端末ごとに 1 日 FREE_PER_DAY 回（サーバー側の設定）。
 *
 * 合言葉は**ソースに書かない**。`local.properties` の `hitorigoto.relayAppKey` → BuildConfig.RELAY_APP_KEY
 */
object Relay {
    val url: String = BuildConfig.RELAY_URL
    val appKey: String = BuildConfig.RELAY_APP_KEY

    /** 合言葉がビルドに入っていないとき（README の置き方を見る）。中継は 403 になる */
    val configured: Boolean get() = appKey.isNotEmpty()

    fun transport(prefs: Prefs): GeminiClient.Transport = GeminiClient.Transport.Relay(url, prefs.deviceId, appKey)
}
