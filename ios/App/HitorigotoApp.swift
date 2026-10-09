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
            RootTabs(tab: $tab)
                #if DEBUG
                // スクショ用: -HGShotTab <0-3> で開くタブ、-HGShot result で結果画面
                .onAppear {
                    let d = UserDefaults.standard
                    if d.object(forKey: "HGShotTab") != nil { tab = d.integer(forKey: "HGShotTab") }
                    if d.string(forKey: "HGShot") == "result" { model.showLatestSessionAsResult() }
                }
                #endif
            .environmentObject(model)
            .tint(Theme.tint)
            #if os(macOS)
            .frame(minWidth: 400, minHeight: 600)
            #endif
        }
        #if os(macOS)
        // 拡張機能のサイドパネルと同じ縦長。横に広げても読みやすくならない
        .defaultSize(width: 440, height: 800)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        #endif
    }
}

/// タブの並び。iPhone は下のタブバー（絵つき）。
/// **Mac は標準の TabView だと文字だけの切り替えになるので、絵つきのタブを自前でタイトルバーに置く。**
/// 設定は「よくある歯車」だけにして右端に離す（2026-10-04 本人要望）
struct RootTabs: View {
    @Binding var tab: Int

    var body: some View {
        #if os(macOS)
        // タイトルバーは隠して、信号機ボタンの右に自前のタブを並べる。
        // toolbar に置くと、窓が細いときに「>>」へ畳まれて見えなくなる（実測）
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tabButton(0, String(localized: "話す"), "mic.fill")
                tabButton(1, String(localized: "表現"), "books.vertical.fill")
                tabButton(2, String(localized: "履歴"), "clock.fill")
                Spacer(minLength: 0)
                Button { tab = 3 } label: {
                    Image(systemName: "gearshape.fill").font(.title3)
                        .foregroundStyle(tab == 3 ? Theme.accent : Theme.muted)
                        .frame(width: 32, height: 28)
                        .background(tab == 3 ? Theme.accentBg : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("設定")
            }
            .padding(.leading, 78).padding(.trailing, 10)
            .frame(height: 40)
            Divider().overlay(Theme.line)
            Group {
                switch tab {
                case 1: PhrasesView()
                case 2: HistoryView()
                case 3: SettingsView()
                default: SpeakView(goPhrases: { tab = 1 })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .ignoresSafeArea(.container, edges: .top)
        #else
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
        #endif
    }

    #if os(macOS)
    private func tabButton(_ i: Int, _ title: String, _ icon: String) -> some View {
        Button { tab = i } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(tab == i ? Theme.accent : Theme.muted)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(tab == i ? Theme.accentBg : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    #endif
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
