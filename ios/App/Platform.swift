import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#else
import AppKit
import CoreAudio
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

    /// 今の入力（マイク）の名前。Mac は「サウンド」設定の既定の入力がそのまま使われる
    static var inputDeviceName: String {
        #if os(iOS)
        return AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? ""
        #else
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return "" }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let name else { return "" }
        return name.takeRetainedValue() as String
        #endif
    }

    /// 録音に使えるマイク。Mac だけ（iPhone は OS が選ぶので空）
    struct InputDevice: Identifiable, Hashable {
        let uid: String
        let name: String
        /// Bluetooth のイヤホン・ヘッドセットか（「つながっているイヤホンを優先」の対象）
        let bluetooth: Bool
        var id: String { uid }
    }

    /// 設定値「つながっているイヤホンを優先」。XM4 と XM6 のように使う機種が日によって変わるので、
    /// 機種を固定せず、そのとき Mac につながっている Bluetooth のマイクを掴む（2026-10-12 本人要望）
    static let micAuto = "auto"

    static func inputDevices() -> [InputDevice] {
        #if os(macOS)
        return macInputDevices().map { InputDevice(uid: $0.uid, name: $0.name, bluetooth: $0.bluetooth) }
        #else
        return []
        #endif
    }

    /// 設定のマイクを、今つながっている装置の uid に解決する。
    /// "" は Mac の既定（nil）、"auto" はつながっている Bluetooth のマイク（無ければ nil）、それ以外は選んだ uid がつながっていればそれ
    static func resolveMic(_ setting: String) -> InputDevice? {
        if setting.isEmpty { return nil }
        let devices = inputDevices()
        if setting == micAuto { return devices.first { $0.bluetooth } }
        return devices.first { $0.uid == setting }
    }

    /// つながってはいるがマイクが Mac に出ていない Bluetooth 機器の名前。
    /// Sony のイヤホンのように 2 台同時につなげる機種は、通話用（マイク）を iPhone 側が掴んでいると
    /// Mac には音の出口（出力）だけが見えて、入力装置が現れない（2026-10-12 XM4 で実測）
    static func bluetoothOutputsWithoutMic() -> [String] {
        #if os(macOS)
        let inputs = Set(macInputDevices().map(\.uid))
        return macOutputDevices().filter { $0.bluetooth }.map(\.uid).compactMap { uid -> String? in
            let base = uid.hasSuffix(":output") ? String(uid.dropLast(7)) : uid
            if inputs.contains(base + ":input") || inputs.contains(base) { return nil }
            return macOutputDevices().first { $0.uid == uid }?.name
        }
        #else
        return []
        #endif
    }

    /// 設定で選んだマイクの名前。選んでいない・今つながっていないときは nil（そのときは Mac の既定で録る）。
    /// 選んだマイクは Recorder が名指しで掴む。**Mac の既定の入力は変えない**
    /// （既定を Bluetooth イヤホンにすると、ほかのアプリがマイクを使うたびに通話モードに落ちて音楽の音が細くなるため）
    static func inputName(uid: String) -> String? {
        resolveMic(uid)?.name
    }

    #if os(macOS)
    private static func macString(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    /// 装置のつなぎ方（Bluetooth かどうか）
    private static func macIsBluetooth(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value == kAudioDeviceTransportTypeBluetooth || value == kAudioDeviceTransportTypeBluetoothLE
    }

    /// 出力装置（Bluetooth のイヤホンがマイク無しでつながっている状態を見分けるのに使う）
    private static func macOutputDevices() -> [(id: AudioDeviceID, uid: String, name: String, bluetooth: Bool)] {
        macDevices(scope: kAudioDevicePropertyScopeOutput)
    }

    private static func macInputDevices() -> [(id: AudioDeviceID, uid: String, name: String, bluetooth: Bool)] {
        macDevices(scope: kAudioDevicePropertyScopeInput)
    }

    private static func macDevices(scope: AudioObjectPropertyScope) -> [(id: AudioDeviceID, uid: String, name: String, bluetooth: Bool)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            // その向き（入力／出力）のチャンネルを持つものだけ
            var cfg = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
            var cfgSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &cfg, 0, nil, &cfgSize) == noErr, cfgSize > 0 else { return nil }
            let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(cfgSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { buf.deallocate() }
            guard AudioObjectGetPropertyData(id, &cfg, 0, nil, &cfgSize, buf) == noErr else { return nil }
            let list = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
            guard list.reduce(0, { $0 + Int($1.mNumberChannels) }) > 0 else { return nil }
            let uid = macString(id, kAudioDevicePropertyDeviceUID)
            let name = macString(id, kAudioObjectPropertyName)
            return uid.isEmpty || name.isEmpty ? nil : (id, uid, name, macIsBluetooth(id))
        }
    }
    #endif

    /// マイクを選ぶ設定画面を開く（Mac は「サウンド」の入力。iPhone は選ぶ画面が無いので何もしない）
    static func openSoundInputSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input") { NSWorkspace.shared.open(url) }
        #endif
    }

    static var canChooseInput: Bool {
        #if os(macOS)
        return true
        #else
        return false
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
