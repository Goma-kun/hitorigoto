import AVFoundation
import SwiftUI

/// 英語の文を端末の声で読み上げる。**端末の中だけで鳴る**ので、通信もお金もかからない
/// （本人の要望・2026-10-03「例文を読み上げてくれるとより良い」）。
///
/// 速さは既定で少しゆっくりにしてある。真似して口に出すのが目的で、聞き流すためではない。
/// **録音中は鳴らさない**（自分の声に混ざるため。呼ぶ側で止めている）
@MainActor
final class Speaker: NSObject, ObservableObject {
    static let shared = Speaker()

    private let synth = AVSpeechSynthesizer()
    /// いま読み上げている文。同じ文をもう一度押したら止める・ボタンの絵を変えるのに使う
    @Published private(set) var speaking: String?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// 押すたびに「読む／止める」。別の文を押したら、前のを止めてそちらを読む
    func toggle(_ text: String, rate: Float = 0.42) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if speaking == t { stop(); return }
        stop()
        #if os(iOS)
        // 再生だけなので playback。マナーモードでも鳴らしたいが、録音の設定は壊さない
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let u = AVSpeechUtterance(string: t)
        u.voice = Self.voice(for: language)
        u.rate = rate
        u.postUtteranceDelay = 0.1
        speaking = t
        synth.speak(u)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speaking = nil
    }

    /// 読み上げる言語（設定「話す言語」に合わせて AppModel が入れる）
    var language = TargetLanguage.default.locale
    private static var cache: [String: AVSpeechSynthesisVoice?] = [:]

    /// その言語でいちばん良い声を選ぶ。**端末に入っている声は機種と設定で違う**ので、
    /// 上等なものから順に探して、無ければ既定の声に落とす
    private static func voice(for lang: String) -> AVSpeechSynthesisVoice? {
        if let v = cache[lang] { return v }
        let vs = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        let v = vs.first(where: { $0.quality == .premium }) ?? vs.first(where: { $0.quality == .enhanced }) ?? AVSpeechSynthesisVoice(language: lang)
        cache[lang] = v
        return v
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = nil }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = nil }
    }
}

/// 英語の文の横に置く、小さな読み上げボタン
struct SpeakButton: View {
    let text: String
    @ObservedObject private var speaker = Speaker.shared

    private var isSpeaking: Bool { speaker.speaking == text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Button {
            speaker.toggle(text)
        } label: {
            Image(systemName: isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                .font(.system(size: 15))
                .foregroundStyle(isSpeaking ? Theme.accent : Theme.muted)
                .frame(width: 32, height: 32)       // 指で押せる大きさ
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("読み上げます")
    }
}
