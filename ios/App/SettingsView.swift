import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var keyInput = ""
    @State private var keyStatus = ""
    @State private var testing = false
    @State private var exporting = false
    @State private var importing = false
    @State private var dataStatus = ""

    var body: some View {
        Form {
            Section {
                if model.hasKey {
                    Label("キーは登録済みです", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                }
                SecureField(model.hasKey ? "（登録済み。変えるときはここに入力）" : "AIza… または AQ… で始まるキー", text: $keyInput)
                    .autocorrectionDisabled()
                HStack {
                    Button("保存") { model.setKey(keyInput); keyInput = ""; keyStatus = "保存しました" }
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(testing ? "確認中…" : "接続テスト") {
                        let k = keyInput.trimmingCharacters(in: .whitespaces).isEmpty ? (KeychainStore.apiKey ?? "") : keyInput
                        guard !k.isEmpty else { keyStatus = "キーを入力するか保存してください"; return }
                        testing = true
                        Task { keyStatus = (await model.testKey(k)).map { "✗ \($0)" } ?? "✓ つながりました"; testing = false }
                    }
                    .disabled(testing)
                    if model.hasKey {
                        Button("削除", role: .destructive) { model.setKey(nil); keyStatus = "削除しました" }
                    }
                }
                if !keyStatus.isEmpty { Text(keyStatus).font(.caption).foregroundStyle(keyStatus.hasPrefix("✗") ? Theme.bad : Theme.good) }
                Link("Google AI Studio でキーを取得する", destination: URL(string: "https://aistudio.google.com/apikey")!)
                Text("キーは端末の Keychain にだけ保存します。録音した音声と話した内容は、あなたのキーで Google の Gemini API に直接送られます。開発者のサーバーは介在しません。日本からの利用は無料枠が使えず従量課金になることがあります（1 回の添削で数円程度）。")
                    .font(.caption).foregroundStyle(Theme.muted)
            } header: { Text("Google Gemini API キー（必須）") }

            Section {
                Toggle("話している最中に字幕を出す（端末の音声認識）", isOn: $model.captionsOn)
                Picker("聞き取る英語", selection: $model.language) {
                    Text("English (US)").tag("en-US"); Text("English (UK)").tag("en-GB")
                }
                Text("字幕は参考です。添削は録音した音声そのものから行うので、字幕が化けていても直されることはありません。字幕を切ると、音声認識の許可は求めません。")
                    .font(.caption).foregroundStyle(Theme.muted)
            } header: { Text("字幕") }

            Section {
                CountPicker(title: "1 日に出す表現の数", range: 1...12, value: $model.dailyTotal)
                CountPicker(title: "そのうち、まだ試していない表現は最大", range: 0...6, value: $model.dailyNew)
                Text("「話す」タブに毎日出す表現の数です。出せなかった表現（✗・△）と期日が来た表現を先に選び、残りの枠にまだ試していない表現を入れます。数を増やすより、無理なく混ぜられる数にしておくほうが続きます。")
                    .font(.caption).foregroundStyle(Theme.muted)
            } header: { Text("毎日の表現") }

            Section {
                HStack {
                    Button("書き出す") { exporting = true }
                    Button("読み込む") { importing = true }
                }
                if !dataStatus.isEmpty { Text(dataStatus).font(.caption).foregroundStyle(dataStatus.hasPrefix("✗") ? Theme.bad : Theme.good) }
                Text("独り言の記録（練習・繰り返し・表現集）を JSON として書き出し・読み込みできます。Chrome 拡張機能版の「書き出し」ファイルもそのまま読み込めます。読み込みは混ぜる方式で、同じ記録は増えません。")
                    .font(.caption).foregroundStyle(Theme.muted)
            } header: { Text("記録の書き出し・読み込み") }

            Section {
                Text("独り言 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")").font(.caption).foregroundStyle(Theme.muted)
                Link("プライバシーポリシー", destination: URL(string: "https://github.com/Goma-kun/hitorigoto/blob/main/PRIVACY.md")!)
            } header: { Text("このアプリについて") }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .fileExporter(isPresented: $exporting, document: JSONDocument(data: model.exportData()), contentType: .json,
                      defaultFilename: "hitorigoto-history-\(Logic.todayStamp().replacingOccurrences(of: "-", with: ""))") { r in
            dataStatus = (try? r.get()) != nil ? "✓ 書き出しました" : "✗ 書き出せませんでした"
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in
            do {
                let url = try r.get()
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                let n = try model.importData(Data(contentsOf: url))
                dataStatus = "✓ 読み込みました（追加されたセッション: \(n) 件）"
            } catch {
                dataStatus = "✗ 読み込めませんでした（独り言の書き出しファイルではないようです）"
            }
        }
    }
}

struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
