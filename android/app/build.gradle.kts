import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// 中継サーバーの合言葉は local.properties（gitignore 済み）から BuildConfig に流す。
// ファイルや項目が無ければ空文字でビルドは通る（中継は 403 になる）。置き方は README を見る
val localProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val relayAppKey: String = localProps.getProperty("hitorigoto.relayAppKey", "").trim()

android {
    namespace = "jp.nishira.hitorigoto"
    compileSdk = 36

    defaultConfig {
        applicationId = "jp.nishira.hitorigoto"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
        // 日本語が既定・英語あり。ほかの言語の androidx リソースは落とす
        resourceConfigurations += listOf("ja", "en")
        buildConfigField("String", "RELAY_APP_KEY", "\"" + relayAppKey.replace("\\", "\\\\").replace("\"", "\\\"") + "\"")
        buildConfigField("String", "RELAY_URL", "\"https://hitorigoto-relay.jsphdn.workers.dev\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // 署名は後で。いまは AAB を作れることを確かめるために debug 署名で通す
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":core"))
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons.extended)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)
}
