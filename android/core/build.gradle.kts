// 添削・表現集のロジック（純 Kotlin/JVM）。Android に依存しないのは、
// JS 版との答え合わせ（../test/parity_android.mjs）を JVM のコマンドラインで回すため。
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    application
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

// 答え合わせ用の入口（iOS の hg-probe と同じ入出力）。アプリからは使わない
application {
    mainClass.set("jp.nishira.hitorigoto.core.probe.HgProbeKt")
    applicationName = "hg-probe"
}

dependencies {
    implementation(libs.kotlinx.serialization.json)
    testImplementation(libs.junit)
}

tasks.test {
    useJUnit()
    systemProperty("user.timezone", System.getProperty("user.timezone") ?: "Asia/Tokyo")
}
