# 独り言 iPhone / Mac アプリ

Chrome 拡張機能「独り言」の iPhone / Mac 版。添削の純ロジック（`Sources/HitorigotoCore`）は拡張機能の
`extension/english-core.js` / `phrase-core.js` をそのまま移したもので、`../test/parity_swift_test.mjs` が
同じ入力に同じ答えを返すことを突き合わせる。画面は `App/`（SwiftUI）。

## 添削に使う AI（2 つ）

| | Gemini API | 端末内 AI（Apple Intelligence） |
|---|---|---|
| 必要なもの | 自分の API キー | iOS 26 / macOS 26 以降・Apple Intelligence 対応機種でオン |
| 渡すもの | **録音した音声そのもの**＋字幕（参考） | **字幕（端末の音声認識）だけ** |
| 通信 | Google へ（自分のキーで直接） | **なし。端末の外に出ない** |
| 発音の評価 | あり | なし（音声を渡していないため） |
| 今日の表現の判定 | AI＋文字照合 | 文字照合だけ |
| 精度 | 高い | 小型モデルなので下がることがある |

拡張機能の「Chrome 内蔵 AI（Gemini Nano）」に相当するのが端末内 AI。設定の「AI エンジン」で
「自動（キーがあれば Gemini）」「端末内 AI を優先」「Gemini だけ」を選べる。

端末内 AI の実装は `Sources/HitorigotoCore/AppleClient.swift`（Foundation Models）と
`ApplePrompts.swift`（短い指示。1 セッション 4096 トークンの制約のため Gemini 用の長文は使えない）。
応答は `@Generable` の型で受け、JSON に戻して `Logic.parseFeedback` に通す（拡張機能と同じ揃え方）。

## ビルドと実行

- Xcode 26 以降で `Hitorigoto.xcodeproj` を開く。ターゲットは `Hitorigoto`（iPhone）と `HitorigotoMac`
- iPhone 実機で動かすには、Signing & Capabilities で自分の Team を選ぶ（無料の Apple ID でも可。7 日で署名が切れる）
- 端末内 AI を試すには、iPhone 側で「設定」→「Apple Intelligence と Siri」をオンにしておく
- デプロイターゲットは iOS 17 のまま。端末内 AI は `#available(iOS 26, *)` の中でだけ動く

## 試し方

純ロジックのテスト（Mac でも Linux でも）:

```
swift test --package-path ios
```

端末内 AI を Mac のターミナルから直接叩く（macOS 26 以降・Apple Intelligence がオン）:

```
swift run --package-path ios hg-probe review --engine apple --text "Yesterday I go to park and I meet my friend."
```

Gemini と見比べるときは `--engine` を外す（キーは `~/.config/nishira/gemini_api_key`）。

JS 版との突き合わせ（リポジトリのルートで）:

```
swift build --package-path ios && node test/parity_swift_test.mjs
```

## 記録

`Application Support/Hitorigoto/snapshot.json`。拡張機能の書き出しファイル（`hitorigoto-english-v1`）と
そのまま行き来できる。履歴の各回に `engine`（gemini / apple）が付くので、どちらで添削したかを見比べられる。
