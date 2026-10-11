# 独り言 Android 版

iPhone 版（`../ios/`）と同じ機能・同じ見た目の考え方で動く Android アプリ（Kotlin + Jetpack Compose）。
拡張機能 `../extension/english-core.js` / `phrase-core.js` のロジックと `ai-providers.js` のプロンプトを Kotlin に移してあり、
**JS 版と同じ答えを返すことを `../test/parity_android.mjs` で突き合わせる**（Swift 版は `../test/parity_swift_test.mjs`。場面は `../test/parity_cases.mjs` で共用）。

## 中身

| | |
|---|---|
| `core/` | 純 Kotlin/JVM。Android に依存しないロジック（Logic / PhraseLogic / Prompts / TargetLanguage / GeminiClient）と保存形式（Store）。`src/main/kotlin/.../probe/HgProbe.kt` が答え合わせの入口 |
| `app/` | Compose の画面（話す／表現／履歴／設定）と、録音（MediaRecorder）・字幕（SpeechRecognizer）・読み上げ（TextToSpeech） |
| `tools/gen_prompts.py` | `extension/ai-providers.js` のプロンプト文面を `core/.../Prompts.kt` に写す（JS が正本。Kotlin 側は手で編集しない） |
| `play-assets/` | Play Console 用のアイコン（512） |

保存先は `filesDir/Hitorigoto/snapshot.json`。拡張機能・iOS と同じ形（`hitorigoto-english-v1`）なので、「書き出す／読み込む」で相互に読める。
送れていない録音は `filesDir/Hitorigoto/pending.m4a` + `pending.json` に残し、添削が通ったときに消す（iOS と同じ安全装置）。

## 環境

- JDK: Android Studio 同梱の JBR（`/Applications/Android Studio.app/Contents/jbr/Contents/Home`）を `JAVA_HOME` に
- SDK: `~/Library/Android/sdk`（`local.properties` の `sdk.dir`）。`platforms;android-36` `build-tools;36.0.0` `platform-tools` が要る
- Gradle 9.5.1（wrapper）・AGP 8.13.2・Kotlin 2.3.21・Compose BOM 2026.06.01。**Gradle を 9.6 以降に上げると AGP 8.x が動かない**
- compileSdk / targetSdk 36・minSdk 26。パッケージ名 `jp.nishira.hitorigoto`。版は 1.0.0 (1)

```
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
cd android
```

## 中継サーバーの合言葉（リポジトリに入れない）

「おまかせ」の添削は開発者の中継サーバー（`https://hitorigoto-relay.jsphdn.workers.dev`・`../server/`）を通る。
アプリであることの合言葉は **ソースに書かず**、`android/local.properties`（gitignore 済み）から `BuildConfig.RELAY_APP_KEY` に流す。

```
# android/local.properties（git には入らない）
sdk.dir=/Users/<you>/Library/Android/sdk
hitorigoto.relayAppKey=<中継サーバーの APP_KEY と同じ値>
```

項目が無ければ空文字でビルドは通る（そのビルドでは「おまかせ」が 403 になり、「自分の Gemini キー」だけ使える）。
合言葉の値は README・ログ・コミット・スクショに出さない。

- 端末 ID は初回に UUID を作って SharedPreferences に置く（中継サーバーの 1 日の回数制限に使う）
- 自分の Gemini キーは AndroidKeyStore の鍵で AES/GCM 暗号化して SharedPreferences に置く（`Prefs.kt` の `SecureStore`）。画面にもログにも出さない

## ビルドとテスト

```
./gradlew :app:assembleDebug          # デバッグ APK → app/build/outputs/apk/debug/app-debug.apk
./gradlew :core:test                  # core のユニットテスト（iOS の CoreTests.swift を移したもの）
./gradlew :core:installDist           # 答え合わせ用 hg-probe → core/build/install/hg-probe/bin/hg-probe
node ../test/parity_android.mjs       # JS 版との突き合わせ（プロジェクトルートからは node test/parity_android.mjs）
python3 tools/gen_prompts.py          # プロンプトを JS から写し直す（プロジェクトルートからは python3 android/tools/gen_prompts.py）
```

`parity_android.mjs` は `test/parity_cases.mjs` で機械的に作った場面（1037 件）を JS 版と Kotlin 版の両方に食わせて答えを 1 件ずつ比べる。
プロンプト（system / audio）が JS と一字一句同じことも、この中で確かめる。
**`english-core.js` / `phrase-core.js` / `ai-providers.js` を直したら、`gen_prompts.py` を回し、Swift 版・Kotlin 版の両方の突き合わせを走らせる。**

## エミュレータ

```
export ANDROID_HOME=$HOME/Library/Android/sdk
$ANDROID_HOME/emulator/emulator -avd uk_pixel -no-snapshot -no-boot-anim -allow-host-audio &   # AVD はうながすくんと共用
$ANDROID_HOME/platform-tools/adb install -r app/build/outputs/apk/debug/app-debug.apk
$ANDROID_HOME/platform-tools/adb shell pm grant jp.nishira.hitorigoto android.permission.RECORD_AUDIO
$ANDROID_HOME/platform-tools/adb shell am start -n jp.nishira.hitorigoto/.MainActivity
$ANDROID_HOME/platform-tools/adb exec-out screencap -p > shot.png
```

- 言語の切り替え: `adb root` → `adb shell "setprop persist.sys.locale ja-JP; setprop ctl.restart zygote"`
- 暗い表示: `adb shell cmd uimode night yes` / `no`
- 見本データを入れる（デバッグ版だけ）: `adb push seed.json /data/local/tmp/seed.json` →
  `adb shell "run-as jp.nishira.hitorigoto sh -c 'mkdir -p files/Hitorigoto && cp /data/local/tmp/seed.json files/Hitorigoto/snapshot.json'"` → アプリを起動し直す
  （書き出しファイルと同じ形でよい。`format` などの余分なキーは読み飛ばす）
- スクショ用の起動（デバッグ版だけ）: `am start ... -e HGShot result`（記録の先頭を結果画面として出す）／`-e HGShotTab 2`（開くタブ）
- エミュレータのマイクは無音なので、停止すると「録音に音が入っていませんでした」で止まり、録音が手元に残る。
  「もう一度送る」を押すと無音のまま中継へ送られ、Gemini が「聞き取れる発話なし」を返す（中継が 200 を返すことの確認に使える。無料枠を 1 回使う）

## 録音・字幕・Bluetooth のしくみ

- 録音は `MediaRecorder`（AAC / m4a・16kHz モノラル・32kbps）。Gemini には `audio/mp4` の inlineData で送る（iOS と同じ）
- 字幕は `SpeechRecognizer`（端末内の認識があればそれ、無ければクラウド）。Android では録音と字幕が同じマイクを取り合うので、
  **録音を優先**する。字幕は文字が出ているのに録音が 6 秒無音なら、字幕を止めて録音を守る。字幕が使えない機種では字幕なしで録音だけ続ける
- Bluetooth イヤホン（SCO）がつながっていれば、録音の前に `setCommunicationDevice`（Android 12 以降）／`startBluetoothSco` で
  そのマイクに切り替え、停止時に戻す。だめなら内蔵マイクのまま
- 録音後にピークが小さければ（無音）Gemini に送らず「マイクが拾えていません」で止める。録音は手元に残る

## AAB（Google Play 用）

```
./gradlew :app:bundleRelease          # → app/build/outputs/bundle/release/app-release.aab
```

いまは **debug 署名**で作っている（`app/build.gradle.kts` の `release.signingConfig`）。
Play に出すときは upload key を作って `signingConfigs` に差し替える（キーはリポジトリに入れない）。版は 1.0.0 (1)。
AAB にも `local.properties` の合言葉が入るので、合言葉を置いた環境で作ること。
