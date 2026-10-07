import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var editingKey = false
    @State private var keyStatus = ""
    @State private var exporting = false
    @State private var importing = false
    @State private var dataStatus = ""

    var body: some View {
        Form {
            Section {
                Picker("添削に使う AI", selection: $model.engine) {
                    Text("自動（キーがあれば Gemini）").tag("auto")
                    Text("端末内 AI（Apple Intelligence）を優先").tag("apple")
                    Text("Gemini API だけ").tag("gemini")
                }
                Label(AppModel.unavailableMessage(model.appleState),
                      systemImage: model.appleState == .available ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.caption).foregroundStyle(model.appleState == .available ? Theme.good : Theme.muted)
                Text("端末内 AI はキー不要・無料で、話した内容が端末の外に出ません。添削は端末の音声認識の字幕をもとに行うので、字幕は自動でオンになります。音声そのものは渡せないため、発音の評価はしません。指摘の精度は Gemini より下がることがあります。")
                    .font(.caption).foregroundStyle(Theme.muted)
            } header: { Text("AI エンジン") }

            Section {
                if model.hasKey {
                    Label("キーは登録済みです", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                } else {
                    Label("まだ登録されていません", systemImage: "exclamationmark.circle").foregroundStyle(Theme.warn)
                }
                // 入力欄はシートに出す。**Mac の設定画面（Form）に直に置いた入力欄はクリックしてもフォーカスが入らなかった**
                // （2026-09-27 実測。同じ TextField でもシートの中なら入る）
                HStack {
                    Button(model.hasKey ? "キーを変更…" : "キーを登録…") { editingKey = true }
                    if model.hasKey {
                        Button("削除", role: .destructive) { model.setKey(nil); keyStatus = "削除しました" }
                    }
                }
                if !keyStatus.isEmpty { Text(keyStatus).font(.caption).foregroundStyle(keyStatus.hasPrefix("✗") ? Theme.bad : Theme.good) }
                Text("キーは端末の Keychain にだけ保存します。録音した音声と話した内容は、あなたのキーで Google の Gemini API に直接送られます。開発者のサーバーは介在しません。日本からの利用は無料枠が使えず従量課金になることがあります（1 回の添削で数円程度）。")
                    .font(.caption).foregroundStyle(Theme.muted)
            } header: { Text(model.appleState == .available ? "Google Gemini API キー（任意・精度を上げたい人向け）" : "Google Gemini API キー（必須）") }

            if Platform.canChooseInput {
                Section {
                    Picker("録音に使うマイク", selection: $model.micUID) {
                        Text("Mac の既定に合わせる").tag("")
                        ForEach(Platform.inputDevices()) { d in Text(d.name).tag(d.uid) }
                    }
                    Text("ここで選んだマイクは、このアプリの録音中だけ使います。Mac の「サウンド」設定は変わりません。選んだマイクがつながっていないときは、Mac の既定のマイクで録ります。")
                        .font(.caption).foregroundStyle(Theme.muted)
                } header: { Text("マイク") }
            }

            Section {
                Toggle("話している最中に字幕を出す（端末の音声認識）", isOn: $model.captionsOn)
                Picker("聞き取る英語", selection: $model.language) {
                    Text("English (US)").tag("en-US"); Text("English (UK)").tag("en-GB")
                }
                Text("Gemini のときの字幕は参考です。添削は録音した音声そのものから行うので、字幕が化けていても直されることはありません。字幕を切ると、音声認識の許可は求めません。端末内 AI で添削するときは字幕が一次資料になるので、この設定に関わらず字幕を出します。")
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
        // Apple Intelligence の設定を変えて戻ってきたときに、案内文を取り直す
        .onAppear { model.refreshAppleState() }
        .sheet(isPresented: $editingKey) { KeySheet(status: $keyStatus).environmentObject(model) }
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

/// キーの登録シート。入力→接続テスト→保存
struct KeySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var status: String
    @State private var keyInput = ""
    @State private var result = ""
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("キー", text: $keyInput, prompt: Text("AIza… または AQ… で始まるキー"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    HStack {
                        Button(testing ? "確認中…" : "接続テスト") {
                            testing = true
                            Task { result = (await model.testKey(keyInput.trimmingCharacters(in: .whitespaces))).map { "✗ \($0)" } ?? "✓ つながりました"; testing = false }
                        }
                        .disabled(testing || keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("保存") {
                            model.setKey(keyInput)
                            status = "✓ 保存しました"
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !result.isEmpty { Text(result).font(.caption).foregroundStyle(result.hasPrefix("✗") ? Theme.bad : Theme.good) }
                } header: { Text("Google Gemini API キー") } footer: {
                    Text("Google AI Studio で作ったキーを貼り付けてください。キーはこの端末の Keychain にだけ保存します。")
                }
                Section {
                    Link("Google AI Studio でキーを取得する", destination: URL(string: "https://aistudio.google.com/apikey")!)
                }
            }
            .navigationTitle("キーを登録").compactNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
        #if os(macOS)
        // 本体の窓（幅 440）からはみ出さない幅にする
        .frame(minWidth: 400, idealWidth: 420, minHeight: 280)
        #endif
    }
}
