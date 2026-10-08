# プライバシーポリシー / Privacy Policy

最終更新日: 2026-10-08

## 日本語

独り言（以下「本拡張機能」）は、利用者のプライバシーを尊重します。

### 収集する情報
本拡張機能は、開発者や第三者のサーバーへ利用者の個人情報・閲覧履歴・入力内容を**一切収集しません**。開発者が利用者のデータを受け取ることはありません。

### 音声認識について
- 話している間の文字起こしには、ブラウザ標準の音声認識機能（Web Speech API）を使用します。この処理は Chrome が提供するもので、音声が Google の音声認識サービスで処理される場合があります。
- 本拡張機能自体が音声データを保存することはありません。
- **音声の送信（Gemini APIキーを設定した場合のみ・既定でオン）**: 利用者が自分の Gemini APIキーを設定し、設定画面の「音声の送信」がオンのとき、練習中に録音した音声（1 回分）が、停止時に Google の Gemini API（generativelanguage.googleapis.com）へ送信され、書き起こしと添削に使われます。音声は添削のためにその場で送るだけで、端末内にも開発者のサーバーにも保存されません。設定画面でいつでもオフにでき、オフのときは Chrome の音声認識結果（テキスト）だけを送ります。端末内AI（Gemini Nano）を使う場合、音声は端末の外に送信されません。

### AIによる添削について
添削に使うAIは2通りあり、どちらを使うかは利用者が選べます。

- **端末内AI（Gemini Nano）**: Chrome に内蔵されたAIを使用します。話した内容（テキスト）は端末の外に送信されません。
- **Gemini API（任意）**: 利用者が自分の Google Gemini APIキーを設定した場合のみ、話した内容のテキスト（および「音声の送信」がオンのときは録音した音声、その日の「今日の表現」として選ばれている表現とその意味）が Google の Gemini API（generativelanguage.googleapis.com）へ送信されます。送信されるのは利用者自身のキーによる、利用者と Google の間の通信であり、開発者のサーバーは介在しません。

### 保存されるデータ
- 練習の記録（話した内容・添削結果・繰り返し指摘）、表現集（利用者が入れた表現・意味とその練習結果）、設定（APIキーを含む）は、利用者自身の端末内の `chrome.storage.local` にのみ保存されます。
- 同期は行いません。他の端末や他の利用者と共有されることはありません。
- 記録の書き出し（エクスポート）は、利用者がその操作を行ったときに端末内のファイルとして保存されるだけです。

### 権限について
- **storage**: 練習の記録と設定を利用者の端末内に保存するために使用します。
- **generativelanguage.googleapis.com への接続**: 利用者がAPIキーを設定した場合の添削（および音声の書き起こし）にのみ使用します。
- **マイク**: 話している間の音声認識と、「音声の送信」がオンのときの録音に使用します。録音は停止時に添削のため送信するだけで、保存しません。

閲覧中のページを読み取る権限、ページにコードを差し込む仕組み（content script）、外部から取得したコードの実行（remote code）は、いずれも使用していません。

### データの削除
Chromeから本拡張機能をアンインストールすると、保存されたデータは削除されます。APIキーは設定画面からいつでも削除できます。

### お問い合わせ
本ポリシーに関するご質問は、GitHubリポジトリ（https://github.com/Goma-kun/hitorigoto）のIssueよりご連絡ください。

## iPhone / Mac アプリ版について（2026-10-08 追記）

App Store で配布するアプリ版「独り言」は、上の拡張機能と同じ考え方で作られています。違いは次の 3 点です。

### 添削のエンジン（設定で選べます）
- **おまかせ（既定・API キー不要）**: 停止したときに、録音した音声（1 回分）と、その日の「今日の表現」、繰り返し指摘されている点が、開発者の中継サーバー（Cloudflare Workers 上）へ送られます。中継サーバーは Google の Gemini API に転送して添削を受け取り、そのまま返します。**中継サーバーは音声や話した内容を保存しません。**利用者の身元に結びつく情報は送られません。回数制限のために、アプリが端末ごとに作るランダムな識別子（UUID）を送ります。この識別子は端末にだけ保存され、利用者を特定するものではありません。無料で使えるのは端末ごとに 1 日 3 回です。
- **自分の Gemini キー**: 拡張機能と同じく、利用者自身のキーで Google の Gemini API に直接送られます。開発者のサーバーは介在しません。
- **この端末の AI（試験的）**: Apple Intelligence（Apple Foundation Models）を使い、録音中の字幕の文字を端末の中で添削します。話した内容は端末の外に出ません。

### マイクと音声認識
- マイクは録音に使います。録音は添削のためにその場で送るだけで、端末にも保存しません（添削が終わるまでの間だけ、失敗時のやり直し用に端末内に残します）。
- 話している間の字幕には、端末の音声認識（iOS / macOS の Speech フレームワーク）を使います。設定で切れます。

### 保存されるデータ
- 練習の記録・表現集・設定は端末の中にだけ保存されます。Gemini キーは端末の Keychain に保存されます。開発者が受け取ることはありません。アプリを削除すると消えます。

---

## English

Hitorigoto ("the Extension") respects your privacy.

### Information We Collect
The Extension does **not** collect any personal information, browsing history, or input data on any server operated by the developer or a third party. The developer never receives your data.

### Speech Recognition
- Live transcription while you speak uses the browser's standard speech recognition (Web Speech API). This is provided by Chrome, and your audio may be processed by Google's speech recognition service.
- The Extension itself never stores your audio.
- **Audio upload (only with your Gemini API key, on by default)**: if you have set your own Gemini API key and "Audio upload" is on in Settings, the audio recorded during a session is sent to Google's Gemini API (generativelanguage.googleapis.com) when you stop, and is used for transcription and feedback. The audio is sent only for that review; it is not stored on your device or on any developer server. You can turn this off at any time in Settings; when off, only the text from Chrome's speech recognition is sent. With on-device AI (Gemini Nano), audio never leaves your device.

### AI Feedback
Two AI engines are available, and you choose which one to use.

- **On-device AI (Gemini Nano)**: uses the AI built into Chrome. The text of what you said never leaves your device.
- **Gemini API (optional)**: only if you set your own Google Gemini API key, the text of what you said (and, when "Audio upload" is on, the recorded audio, plus the phrases and meanings selected as "Today's phrases") is sent to Google's Gemini API (generativelanguage.googleapis.com). This communication happens directly between you and Google using your own key; no developer server is involved.

### Stored Data
- Your practice history (what you said, feedback, recurring patterns), your phrase list (phrases and meanings you added and their practice results) and settings (including your API key) are stored only in `chrome.storage.local` on your own device.
- No synchronization is performed. Nothing is shared with other devices or other users.
- Exporting your history simply saves a file on your device, and only when you perform that action.

### Permissions
- **storage**: to save your practice history and settings on your own device.
- **Access to generativelanguage.googleapis.com**: used only for feedback (and audio transcription) when you have set your own API key.
- **Microphone**: used for live speech recognition while you speak, and for recording when "Audio upload" is on. The recording is only sent for review when you stop; it is never stored.

The Extension does not read the pages you browse, does not use content scripts, and does not execute remote code.

### Deleting Your Data
Uninstalling the Extension from Chrome removes the stored data. You can delete your API key at any time from the settings screen.

### Contact
For questions about this policy, please open an issue on the GitHub repository: https://github.com/Goma-kun/hitorigoto

## About the iPhone / Mac app (added 2026-10-08)

The app version of Hitorigoto distributed on the App Store follows the same principles as the extension above, with three differences.

### Feedback engine (selectable in Settings)
- **Default (no API key needed)**: when you stop, the recorded audio of that session, your "Today's phrases" and your recurring issues are sent to the developer's relay server (hosted on Cloudflare Workers). The relay forwards them to Google's Gemini API, receives the feedback and returns it unchanged. **The relay does not store your audio or what you said.** Nothing that identifies you is sent. For rate limiting, the app sends a random per-device identifier (UUID) that it generates and keeps only on the device; it does not identify you. Free use is limited to 3 reviews per device per day.
- **Your own Gemini key**: as with the extension, requests go directly to Google's Gemini API with your own key. No developer server is involved.
- **On-device AI (experimental)**: uses Apple Intelligence (Apple Foundation Models) to review the live caption text on the device. What you said never leaves the device.

### Microphone and speech recognition
- The microphone is used for recording. The recording is sent only for that review and is not stored on the device (it is kept on the device only until the review succeeds, so that a failed request can be retried).
- Live captions while you speak use the device's speech recognition (the Speech framework on iOS / macOS). You can turn captions off in Settings.

### Stored data
- Your practice history, phrase list and settings are stored only on your device. Your Gemini key is stored in the device Keychain. The developer never receives them. Deleting the app removes them.
