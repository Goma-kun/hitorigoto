import SwiftUI

@main
struct HitorigotoApp: App {
    @StateObject private var model: AppModel
    @State private var tab = 0

    init() {
        DevHooks.apply()
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                SpeakView(goPhrases: { tab = 1 })
                    .tabItem { Label("話す", systemImage: "mic.fill") }.tag(0)
                PhrasesView()
                    .tabItem { Label("表現", systemImage: "books.vertical.fill") }.tag(1)
                HistoryView()
                    .tabItem { Label("履歴", systemImage: "clock.fill") }.tag(2)
                SettingsView()
                    .tabItem { Label("設定", systemImage: "gearshape.fill") }.tag(3)
            }
            .environmentObject(model)
            .tint(Theme.tint)
            #if os(macOS)
            .frame(minWidth: 400, minHeight: 600)
            #endif
        }
        #if os(macOS)
        // 拡張機能のサイドパネルと同じ縦長。横に広げても読みやすくならない
        .defaultSize(width: 440, height: 800)
        .windowResizability(.contentMinSize)
        #endif
    }
}

/// 検証用のフック。**Release では何もしない。**
///   -HGKeyFile <path>   そのファイルの中身を Gemini キーとして Keychain に入れる（キーをチャットや引数に出さないため）
///   -HGSeed <path>      記録がまだ無ければ、その JSON（書き出しファイルと同じ形）を最初の記録にする
enum DevHooks {
    static func apply() {
        #if DEBUG
        let d = UserDefaults.standard
        if let path = d.string(forKey: "HGKeyFile"),
           let key = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            KeychainStore.apiKey = key
        }
        if let path = d.string(forKey: "HGSeed"), let url = try? SnapshotStore.defaultURL(),
           !FileManager.default.fileExists(atPath: url.path),
           let data = FileManager.default.contents(atPath: path) {
            // copyItem（clonefile）は Mac 側のフォルダに対して止まることがあるので、読んで書く
            try? data.write(to: url)
        }
        #endif
    }
}
