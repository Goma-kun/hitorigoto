# プライバシーポリシー / Privacy Policy

最終更新日: 2026-08-17

## 日本語

独り言（以下「本拡張機能」）は、利用者のプライバシーを尊重します。

### 収集する情報
本拡張機能は、開発者や第三者のサーバーへ利用者の個人情報・閲覧履歴・入力内容を**一切収集しません**。開発者が利用者のデータを受け取ることはありません。

### 音声認識について
- 音声の文字起こしには、ブラウザ標準の音声認識機能（Web Speech API）を使用します。この処理は Chrome が提供するもので、音声が Google の音声認識サービスで処理される場合があります。
- 本拡張機能自体が音声データを保存・送信することはありません。

### AIによる添削について
添削に使うAIは2通りあり、どちらを使うかは利用者が選べます。

- **端末内AI（Gemini Nano）**: Chrome に内蔵されたAIを使用します。話した内容（テキスト）は端末の外に送信されません。
- **Gemini API（任意）**: 利用者が自分の Google Gemini APIキーを設定した場合のみ、話した内容のテキストが Google の Gemini API（generativelanguage.googleapis.com）へ送信されます。送信されるのは利用者自身のキーによる、利用者と Google の間の通信であり、開発者のサーバーは介在しません。

### 保存されるデータ
- 練習の記録（話した内容・添削結果・繰り返し指摘）と設定（APIキーを含む）は、利用者自身の端末内の `chrome.storage.local` にのみ保存されます。
- 同期は行いません。他の端末や他の利用者と共有されることはありません。
- 記録の書き出し（エクスポート）は、利用者がその操作を行ったときに端末内のファイルとして保存されるだけです。

### 権限について
- **storage**: 練習の記録と設定を利用者の端末内に保存するために使用します。
- **generativelanguage.googleapis.com への接続**: 利用者がAPIキーを設定した場合の添削にのみ使用します。

閲覧中のページを読み取る権限、ページにコードを差し込む仕組み（content script）、外部から取得したコードの実行（remote code）は、いずれも使用していません。

### データの削除
Chromeから本拡張機能をアンインストールすると、保存されたデータは削除されます。APIキーは設定画面からいつでも削除できます。

### お問い合わせ
本ポリシーに関するご質問は、GitHubリポジトリ（https://github.com/Goma-kun/hitorigoto）のIssueよりご連絡ください。

---

## English

Hitorigoto ("the Extension") respects your privacy.

### Information We Collect
The Extension does **not** collect any personal information, browsing history, or input data on any server operated by the developer or a third party. The developer never receives your data.

### Speech Recognition
- Transcription uses the browser's standard speech recognition (Web Speech API). This is provided by Chrome, and your audio may be processed by Google's speech recognition service.
- The Extension itself never stores or transmits your audio.

### AI Feedback
Two AI engines are available, and you choose which one to use.

- **On-device AI (Gemini Nano)**: uses the AI built into Chrome. The text of what you said never leaves your device.
- **Gemini API (optional)**: only if you set your own Google Gemini API key, the text of what you said is sent to Google's Gemini API (generativelanguage.googleapis.com). This communication happens directly between you and Google using your own key; no developer server is involved.

### Stored Data
- Your practice history (what you said, feedback, recurring patterns) and settings (including your API key) are stored only in `chrome.storage.local` on your own device.
- No synchronization is performed. Nothing is shared with other devices or other users.
- Exporting your history simply saves a file on your device, and only when you perform that action.

### Permissions
- **storage**: to save your practice history and settings on your own device.
- **Access to generativelanguage.googleapis.com**: used only for feedback when you have set your own API key.

The Extension does not read the pages you browse, does not use content scripts, and does not execute remote code.

### Deleting Your Data
Uninstalling the Extension from Chrome removes the stored data. You can delete your API key at any time from the settings screen.

### Contact
For questions about this policy, please open an issue on the GitHub repository: https://github.com/Goma-kun/hitorigoto
