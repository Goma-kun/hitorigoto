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
    private var scheduled = 0             // 今のノードに渡した断片の数
    private var played = 0                // 今のノードで鳴り終わった断片の数
    private var ended = false             // もう断片は来ない
    private var waiter: CheckedContinuation<Bool, Never>?
    private var finished = false
    private(set) var isPlaying = false
    /// この再生に鳴らした秒数（進み具合の目安）
    private(set) var seconds: Double = 0
    /// 会話の音声を残すとき: 止まった時点で spoken に「実際に鳴った分」を渡す
    private var spoken: Speaker.Spoken?
    /// 渡した音の全部。出力先が切り替わってエンジンが止まったとき、続きから鳴らし直すのにも使う
    private var fed: [Int16] = []
    private var doneFrames = 0            // 今のノードで鳴り終わった標本の数
    private var base = 0                  // 今のノードを作る前に鳴り終わっていた標本の数
    private var clockStart: Date?         // 今のノードが鳴り始めた時刻（鳴った量の上限を時計で押さえる）
    private var run = 0                   // play / stop のたびに進む番号
    private var rebuilds = 0
    private var starting = false          // 作り直したエンジンの start を待っている間
    private var observer: NSObjectProtocol?

    /// 断片の流れを最後まで鳴らす。鳴り切ったら true、途中で止められたら false。
    /// onFirst は最初の音が鳴り始めたときに呼ぶ（「声を用意しています…」を消すため）
    /// spoken を渡すと、鳴り終わったとき・止められたときに必ず 1 回だけ呼ぶ（鳴らなかったら空で呼ぶ）
    func play(_ chunks: AsyncThrowingStream<Data, Error>, onFirst: @escaping () -> Void, spoken: Speaker.Spoken? = nil) async -> Bool {
        stop()
        run += 1
        let run = self.run
        self.spoken = spoken; fed = []; doneFrames = 0; base = 0; clockStart = nil; rebuilds = 0; starting = false
        carry = Data(); scheduled = 0; played = 0; ended = false; finished = false; seconds = 0
        // **音声セッションを先に再生用へ切り替えてから、エンジンを作る**。
        // 逆の順だと、録音のあと（Bluetooth イヤホンは通話用の接続のまま）の出力形式でエンジンが組まれ、
        // 再生用の接続に切り替わった時点でエンジンが黙って止まる（2026-11-25 本人の iPhone＋イヤホンで声が出なかった）
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let (engine, _) = build()
        do { try engine.start() } catch { finish(); return false }
        isPlaying = true
        var first = true
        do {
            for try await chunk in chunks {
                guard self.run == run else { return false }   // その間に止められた
                feed(chunk)
                if first, !fed.isEmpty { first = false; onFirst() }
            }
        } catch {
            if fed.isEmpty { finish(); return false }
        }
        guard self.run == run else { return false }
        if fed.isEmpty { finish(); return false }
        ended = true
        if !starting, played >= scheduled { return settle() ? true : await withCheckedContinuation { c in waiter = c } }
        return await withCheckedContinuation { c in waiter = c }
    }

    /// エンジンとノードを作ってつなぐ。出力先が切り替わったら知らせを受ける
    private func build() -> (AVAudioEngine, AVAudioPlayerNode) {
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        #if DEBUG
        if let v = Self.testVolume { engine.mainMixerNode.outputVolume = v }
        #endif
        self.engine = engine; self.node = node
        // 出力先の形式が変わると（イヤホンの接続の切り替えなど）エンジンは自分で止まる。続きから鳴らし直す
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engine === engine else { return }
                self.rebuild()
            }
        }
        return (engine, node)
    }

    #if DEBUG
    /// 確認用: 聞こえない音量で鳴らす
    static var testVolume: Float?
    #endif

    private func feed(_ data: Data) {
        var d = carry + data
        let n = d.count / 2
        carry = d.count % 2 == 1 ? Data([d[d.count - 1]]) : Data()
        if d.count % 2 == 1 { d.removeLast() }
        guard n > 0, node != nil else { return }
        // 知らせが来ないままエンジンが止まっていたら、ここで作り直す
        if let e = engine, !e.isRunning, !starting { rebuild() }
        var samples = [Int16](repeating: 0, count: n)
        d.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<n { samples[i] = Int16(littleEndian: p[i]) }
        }
        fed.append(contentsOf: samples)
        seconds += Double(n) / 24000
        schedule(samples[...])
        kick()
    }

    private func schedule(_ samples: ArraySlice<Int16>) {
        let n = samples.count
        guard n > 0, let node, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let out = buf.floatChannelData![0]
        var i = 0
        for s in samples { out[i] = Float(s) / 32768; i += 1 }
        scheduled += 1
        node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.chunkPlayed(on: node, frames: n) }
        }
    }

    /// 渡した音があってエンジンが動いていれば、鳴らし始める
    private func kick() {
        guard let node, let engine, engine.isRunning, !starting, scheduled > 0, !node.isPlaying else { return }
        node.play()
        clockStart = Date()
    }

    private func chunkPlayed(on n: AVAudioPlayerNode, frames: Int) {
        guard node === n else { return }
        played += 1
        doneFrames += frames
        if ended, played >= scheduled, settle() { resume(true) }
    }

    /// 全部の断片が「鳴り終わった」と返ってきたときの締め。締めたら true。
    /// エンジンが止まったときも断片は「鳴り終わった」と返ってくるので、時計で見て早すぎたら続きから鳴らし直す（false）
    private func settle() -> Bool {
        if position() < fed.count - 12000, rebuilds < 5 { rebuild(); return false }
        finish(cut: false)
        return true
    }

    /// いま何標本ぶん鳴ったか。再生位置が取れなければ鳴り終わった断片の合計。鳴り始めてからの時間より多くはならない
    private func position() -> Int {
        var n = doneFrames
        if let node, node.isPlaying, let t = node.lastRenderTime, t.isSampleTimeValid, let p = node.playerTime(forNodeTime: t) {
            n = max(n, Int(Double(p.sampleTime) * 24000 / p.sampleRate))
        }
        if let s = clockStart { n = min(n, Int(Date().timeIntervalSince(s) * 24000)) } else { n = 0 }
        return min(fed.count, base + max(0, n))
    }

    /// エンジンを作り直して、鳴り終わった所の続きから鳴らす
    private func rebuild() {
        guard isPlaying, node != nil else { return }
        let at = position()
        rebuilds += 1
        teardown()
        let (engine, node) = build()
        base = at; doneFrames = 0; scheduled = 0; played = 0; clockStart = nil
        if at < fed.count { schedule(fed[at...]) }
        starting = true
        Task { @MainActor in
            // 切り替わる途中は start が通らないことがあるので、間を置いて何度か試す
            for wait in [0.0, 0.3, 0.8, 1.5] {
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                guard self.node === node else { return }
                if (try? engine.start()) != nil {
                    self.starting = false
                    self.kick()
                    if self.ended, self.played >= self.scheduled, self.settle() { self.resume(true) }
                    return
                }
            }
            guard self.node === node else { return }
            self.starting = false
            self.finish(); self.resume(false)
        }
    }

    private func teardown() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        let n = node, e = engine
        node = nil; engine = nil   // 先に外す（止めたときに返ってくる「鳴り終わった」を数えないように）
        n?.stop()
        e?.stop()
    }

    /// cut は途中で止められたとき（録音を始めた・飛ばした）。そのときは鳴った分だけを spoken に渡す
    private func finish(cut: Bool = true) {
        let n = cut ? position() : fed.count
        if let s = spoken {
            spoken = nil
            s(fed, n > 0 ? [(0, Double(n) / 24000)] : [])
        }
        fed = []
        isPlaying = false
        starting = false
        run += 1
        teardown()
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
