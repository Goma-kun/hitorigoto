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
    /// AI の声（三人で話す）を鳴らす
    private var player: AVAudioPlayer?
    /// 端末の声で順に読む残り（三人で話すの代わりの声: トラさん → ネイティブ役）
    private var queue: [(String, String?)] = []
    /// 止めるたびに進む番号。声が遅れて届いたとき、もう止めた後（録音を始めた等）なら鳴らさないのに使う
    private(set) var epoch = 0
    /// いま読み上げている文。同じ文をもう一度押したら止める・ボタンの絵を変えるのに使う
    @Published private(set) var speaking: String?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// 押すたびに「読む／止める」。別の文を押したら、前のを止めてそちらを読む
    func toggle(_ text: String, rate: Float = 0.42, language: String? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if speaking == t { stop(); return }
        speak(t, rate: rate, language: language)
    }

    /// 読む（読み上げ中なら止めてから）。会話の返事を自動で読むときはこちら（押し直しで止まらないように）
    /// language を渡すと、その言語の声で読む（トラさんの日本語など）。省略すると設定の「話す言語」
    func speak(_ text: String, rate: Float = 0.42, language: String? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        stop()
        #if os(iOS)
        // 再生だけなので playback。マナーモードでも鳴らしたいが、録音の設定は壊さない
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let u = AVSpeechUtterance(string: t)
        u.voice = Self.voice(for: language ?? self.language)
        u.rate = rate
        u.postUtteranceDelay = 0.1
        speaking = t
        synth.speak(u)
    }

    func stop() {
        epoch += 1
        queue = []
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        player?.stop(); player = nil
        speaking = nil
    }

    /// いま声が鳴っているか（AI の声か端末の声）
    var isPlaying: Bool { (player?.isPlaying ?? false) || synth.isSpeaking }
    /// 鳴っている声のどこまで聞いたか（0〜1）。AI の声なら再生位置から、端末の声なら分からないので 0.5
    var progress: Double? {
        if let p = player, p.isPlaying, p.duration > 0 { return min(1, p.currentTime / p.duration) }
        if synth.isSpeaking { return 0.5 }
        return nil
    }

    /// 止めて、新しい番号を返す。この番号を play に渡すと、その間に止められていたら鳴らさない
    func begin() -> Int { stop(); return epoch }

    /// AI の声（WAV）を鳴らす。epoch が古ければ（その後に止められていれば）何もしない。鳴らせたら true
    @discardableResult
    func play(_ wav: Data, epoch: Int) -> Bool {
        guard epoch == self.epoch, let p = try? AVAudioPlayer(data: wav) else { return false }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        player = p
        p.play()
        return true
    }

    /// 端末の声で、いくつかの文を順に読む（言語は文ごと）。epoch が古ければ読まない
    func speakInOrder(_ items: [(text: String, language: String?)], rate: Float = 0.46, epoch: Int) {
        guard epoch == self.epoch else { return }
        queue = items.map { ($0.text, $0.language) }
        sayNext(rate: rate)
    }

    private func sayNext(rate: Float) {
        guard !queue.isEmpty else { return }
        let (text, lang) = queue.removeFirst()
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.voice(for: lang ?? language)
        u.rate = rate
        u.postUtteranceDelay = 0.25
        nextRate = rate
        synth.speak(u)
    }
    private var nextRate: Float = 0.46

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
        Task { @MainActor in
            self.speaking = nil
            if !self.queue.isEmpty { self.sayNext(rate: self.nextRate) }
        }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = nil }
    }
}

/// 英語の文の横に置く、小さな読み上げボタン
struct SpeakButton: View {
    let text: String
    /// 読む言語。省略すると設定の「話す言語」
    var language: String? = nil
    @ObservedObject private var speaker = Speaker.shared

    private var isSpeaking: Bool { speaker.speaking == text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Button {
            speaker.toggle(text, language: language)
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
