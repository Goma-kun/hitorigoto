import AVFoundation
import Foundation

/// AI の声を、届いた端から鳴らす（三人で話すの返事を速く聞くため・本人の要望 2026-10-29）。
/// Gemini の TTS を streamGenerateContent で受けると最初の音が 0.8 秒ほどで届く（まとめて受けると 3.5 秒）。
/// 24kHz・16bit・モノラルの PCM の断片を AVAudioPlayerNode に次々と渡す
@MainActor
final class StreamPlayer {
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private var carry = Data()            // 断片の境で 16bit が割れたときの持ち越し
    private var scheduled = 0             // 渡した断片の数
    private var played = 0                // 鳴り終わった断片の数
    private var ended = false             // もう断片は来ない
    private var waiter: CheckedContinuation<Bool, Never>?
    private var finished = false
    private(set) var isPlaying = false
    /// この再生に鳴らした秒数（進み具合の目安）
    private(set) var seconds: Double = 0

    /// 断片の流れを最後まで鳴らす。鳴り切ったら true、途中で止められたら false。
    /// onFirst は最初の音が鳴り始めたときに呼ぶ（「声を用意しています…」を消すため）
    func play(_ chunks: AsyncThrowingStream<Data, Error>, onFirst: @escaping () -> Void) async -> Bool {
        stop()
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        do { try engine.start() } catch { return false }
        self.engine = engine; self.node = node
        carry = Data(); scheduled = 0; played = 0; ended = false; finished = false; seconds = 0
        isPlaying = true
        var first = true
        do {
            for try await chunk in chunks {
                guard self.node === node else { return false }   // その間に止められた
                feed(chunk)
                if first, scheduled > 0 { first = false; node.play(); onFirst() }
            }
        } catch {
            if scheduled == 0 { finish(); return false }
        }
        guard self.node === node else { return false }
        if scheduled == 0 { finish(); return false }
        ended = true
        if played >= scheduled { finish(); return true }
        return await withCheckedContinuation { c in waiter = c }
    }

    private func feed(_ data: Data) {
        var d = carry + data
        let n = d.count / 2
        carry = d.count % 2 == 1 ? Data([d[d.count - 1]]) : Data()
        if d.count % 2 == 1 { d.removeLast() }
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)), let node else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let out = buf.floatChannelData![0]
        d.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<n { out[i] = Float(Int16(littleEndian: p[i])) / 32768 }
        }
        scheduled += 1
        seconds += Double(n) / 24000
        node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.chunkPlayed(on: node) }
        }
    }

    private func chunkPlayed(on n: AVAudioPlayerNode) {
        guard node === n else { return }
        played += 1
        if ended, played >= scheduled { finish(); resume(true) }
    }

    private func finish() {
        isPlaying = false
        node?.stop()
        engine?.stop()
        node = nil; engine = nil
    }

    private func resume(_ ok: Bool) {
        guard !finished else { return }
        finished = true
        waiter?.resume(returning: ok); waiter = nil
    }

    /// 止める（録音を始める・飛ばす・別の声を鳴らす）
    func stop() {
        guard node != nil || waiter != nil else { return }
        finish()
        resume(false)
    }
}
