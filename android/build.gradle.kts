// 独り言 Android 版。モジュールは 2 つ:
//   core … 純 Kotlin/JVM。拡張機能 english-core.js / phrase-core.js / iOS の HitorigotoCore と同じロジック（Android 依存なし）
//   app  … Jetpack Compose の画面と、録音・字幕・読み上げ
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}
