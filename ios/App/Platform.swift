import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// OS ごとに違うところを、ここ 1 か所にまとめる。**画面の側に `#if` を散らさない**
enum Platform {

    /// マイクの許可を求める（すでに決まっていればそれを返す）
    static func requestMicrophone() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    /// マイクの許可が拒否されているか
    static var microphoneDenied: Bool {
        #if os(iOS)
        return AVAudioApplication.shared.recordPermission == .denied
        #else
        return AVCaptureDevice.authorizationStatus(for: .audio) == .denied
        #endif
    }

    /// 録音のための音声セッション。Mac には無い
    static func activateAudioSession() throws {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
        try s.setActive(true)
        #endif
    }

    static func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// クリップボードへ
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// このアプリの設定画面（マイクの許可など）を開く
    static func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
        #endif
    }
}

extension View {
    /// `navigationBarTitleDisplayMode` は iOS にしか無い
    @ViewBuilder
    func compactNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// 数を選ぶ入力。**ステッパーにしない**（上下矢印は押す向きと数字の動きが分かりにくい・本人指摘）。
/// iOS も Mac もプルダウン（メニュー）にする
struct CountPicker: View {
    let title: String
    let range: ClosedRange<Int>
    @Binding var value: Int

    var body: some View {
        Picker(title, selection: $value) {
            ForEach(Array(range), id: \.self) { Text(String($0)).tag($0) }
        }
        #if os(iOS)
        .pickerStyle(.menu)
        #endif
    }
}
