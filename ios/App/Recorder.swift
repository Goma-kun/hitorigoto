import Foundation
import AVFoundation
import Speech
import CoreMedia

/// オーディオスレッドと画面側の橋渡し。マイクのタップは別スレッドから呼ばれるので、
/// 書き込み先と認識リクエストの差し替えをロックで守る（まもるくん iOS 版の AudioSink と同じ型）
private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var requests: [SFSpeechAudioBufferRecognitionRequest?] = [nil, nil]   // 0: 話す言語、1: 母語（日本語）
    // SpeechAnalyzer（iOS 26 / macOS 26）へ流す口。形式が違えば変換して、全部の流れに同じバッファを入れる
    private var analyzerFormat: AVAudioFormat?
    private var analyzerConverter: AVAudioConverter?
    private var analyzerFeed: [(AVAudioPCMBuffer) -> Void] = []

    func open(file: AVAudioFile) {
        lock.lock(); defer { lock.unlock() }
        self.file = file; self.converter = nil
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        file = nil; converter = nil; requests = [nil, nil]
        analyzerFormat = nil; analyzerConverter = nil; analyzerFeed = []
    }

    func setAnalyzer(format: AVAudioFormat?, feed: [(AVAudioPCMBuffer) -> Void]) {
        lock.lock(); defer { lock.unlock() }
        analyzerFormat = format; analyzerConverter = nil; analyzerFeed = feed
    }

    func attach(_ request: SFSpeechAudioBufferRecognitionRequest?, slot: Int) {
        lock.lock(); defer { lock.unlock() }
        requests[slot] = request
    }

    /// 1 バッファぶんをファイルへ書き、認識にも流す。返り値はピーク（0〜1）
    func handle(_ buffer: AVAudioPCMBuffer) -> Float {
        lock.lock(); defer { lock.unlock() }
        if let file {
            // 変換器は最初のバッファの形式を見て作る（名指しで掴むマイクは、届くまで形式が分からない）
            if buffer.format != file.processingFormat, converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: file.processingFormat)
            }
            if buffer.format != file.processingFormat, let conv = converter {
                let ratio = file.processingFormat.sampleRate / buffer.format.sampleRate
                let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
                if let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: cap) {
                    var consumed = false
                    var err: NSError?
                    conv.convert(to: out, error: &err) { _, status in
                        if consumed { status.pointee = .noDataNow; return nil }
                        consumed = true; status.pointee = .haveData; return buffer
                    }
                    if err == nil, out.frameLength > 0 { try? file.write(from: out) }
                }
            } else {
                try? file.write(from: buffer)
            }
        }
        for r in requests { r?.append(buffer) }
        if !analyzerFeed.isEmpty, let fmt = analyzerFormat {
            if buffer.format == fmt { for f in analyzerFeed { f(buffer) } }
            else {
                if analyzerConverter?.inputFormat != buffer.format { analyzerConverter = AVAudioConverter(from: buffer.format, to: fmt) }
                if let conv = analyzerConverter {
                    let ratio = fmt.sampleRate / buffer.format.sampleRate
                    let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
                    if let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) {
                        var consumed = false
                        var err: NSError?
                        conv.convert(to: out, error: &err) { _, status in
                            if consumed { status.pointee = .noDataNow; return nil }
                            consumed = true; status.pointee = .haveData; return buffer
                        }
                        if err == nil, out.frameLength > 0 { for f in analyzerFeed { f(out) } }
                    }
                }
            }
        }
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        var m: Float = 0
        for i in 0..<Int(buffer.frameLength) { m = max(m, abs(ch[i])) }
        return min(1, m * 3)
    }
}

#if os(macOS)
/// 選んだマイクを**名指しで**掴む録り方（Mac だけ）。
/// AVAudioEngine は入力の機器を差し替えても、start した瞬間に Mac の既定の入力へ戻してしまう
/// （2026-10-04 実測。CurrentDevice も auAudioUnit.setDeviceID も同じ。本番で AT-UMX3 の無音を録った）。
/// AVCaptureSession なら uid で機器を指定でき、Mac の既定の入力も変えない
private final class DeviceCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "jp.nishira.hitorigoto.capture")
    private var toFloat: AVAudioConverter?
    private let onBuffer: (AVAudioPCMBuffer) -> Void

    init?(uid: String, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
        super.init()
        guard let device = AVCaptureDevice(uniqueID: uid), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return nil }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        guard session.canAddOutput(output) else { return nil }
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
    }

    func start() { session.startRunning() }
    func stop() { session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let src = AVAudioFormat(cmAudioFormatDescription: desc)
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard n > 0, let pcm = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: n) else { return }
        pcm.frameLength = n
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(n),
                                                           into: pcm.mutableAudioBufferList) == noErr else { return }
        // 届くのは 16bit 整数のことが多い。後段（音量・ファイル・字幕）は float を前提にしているので揃える
        guard let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: src.sampleRate,
                                      channels: src.channelCount, interleaved: false) else { return }
        if src == dst { onBuffer(pcm); return }
        if toFloat?.inputFormat != src { toFloat = AVAudioConverter(from: src, to: dst) }
        guard let conv = toFloat, let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: n),
              (try? conv.convert(to: out, from: pcm)) != nil else { return }
        onBuffer(out)
    }
}
#endif

/// マイクから 1 本の音声エンジンで、①AAC の音声ファイル（Gemini に送る一次資料）と
/// ②端末の音声認識による字幕（話している最中の表示と、認識ずれの比較材料）の両方を作る。
///
/// エンジンを 1 つにしているのは、録音と認識で別々にマイクを掴むと片方が取れないことがあるため。
/// 字幕は補助なので、認識が使えない端末・許可が無いときは字幕なしで録音だけ続ける
@MainActor
final class Recorder: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var seconds = 0
    @Published private(set) var level: Float = 0            // 0〜1。声が入っていることを見せる
    @Published private(set) var transcript = ""             // 字幕の確定分
    @Published private(set) var interim = ""                // 字幕の未確定分
    @Published private(set) var captionsAvailable = false
    @Published private(set) var inputName = ""              // 今使っているマイクの名前
    @Published private(set) var micSilent = false           // しばらく音が入っていない（別のマイクを掴んでいる疑い）
    @Published private(set) var inputDetail = ""            // 入力の形式（例: 16000 Hz・1ch）。不具合の切り分け用に画面へ出す
    @Published private(set) var engineNote = ""             // エンジンの張り直しで起きたこと（空なら順調）

    /// これ以上のピークが来たら「音が入っている」とみなす（level は 3 倍済み。素の値で −46dB ほど）
    private static let soundThreshold: Float = 0.015
    /// 音が無いまま、この秒数たったら知らせる
    private static let silentAfter: TimeInterval = 6
    private var lastSound: Date?

    /// 録音した音声（AAC / m4a）。Gemini の inlineData には audio/mp4 で渡す（実測で通ることを確認済み）
    static let mimeType = "audio/mp4"

    private let engine = AVAudioEngine()
    private let sink = Sink()
    #if os(macOS)
    private var capture: DeviceCapture?     // 設定でマイクを選んであるときだけ使う
    #endif
    private var fileURL: URL?
    private var timer: Timer?
    private var configObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var restartTask: Task<Void, Never>?
    private var started: Date?

    /// 字幕の認識。一度に 1 本（詳しくは「字幕」の節）
    private var active: CaptionStream?
    private var primaryRecognizer: SFSpeechRecognizer?
    private var nativeRecognizer: SFSpeechRecognizer?
    private var doneSegs: [CaptionSeg] = []          // 終わった認識の区切り（切り替えをまたいで積む）
    private var nativeSince: Date?
    private var nativeIdle: Task<Void, Never>?
    private var analyzerCaptions: AnyObject?          // AnalyzerCaptions（iOS 26 / macOS 26）。古い OS では nil
    private var wantCaptions = false

    struct Result {
        let audio: Data
        let transcript: String     // 字幕（端末の音声認識）。空のこともある
        let seconds: Int
    }

    enum Failure: Error { case micDenied, engine(String) }

    // MARK: - 開始・停止

    func start(captions: Bool, language: String, micUID: String = "") async throws {
        guard !isRecording else { return }
        guard await Platform.requestMicrophone() else { throw Failure.micDenied }
        try Platform.activateAudioSession()

        transcript = ""; interim = ""; seconds = 0; level = 0
        micSilent = false; lastSound = nil
        wantCaptions = captions

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hitorigoto-\(Int(Date().timeIntervalSince1970)).m4a")
        // 16kHz モノラル 32kbps の AAC。5 分で 1.2MB ほど
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        fileURL = url
        sink.open(file: file)

        if captions { startCaptions(language: language) }

        let sink = self.sink
        let onBuffer: (AVAudioPCMBuffer) -> Void = { [weak self] buffer in
            let lv = sink.handle(buffer)
            Task { @MainActor in
                guard let self else { return }
                self.level = lv
                if lv >= Self.soundThreshold {
                    self.lastSound = Date()
                    if self.micSilent { self.micSilent = false }
                }
            }
        }

        // 設定で選んだマイクがつながっていれば、それを名指しで掴む。無ければ Mac の既定（iPhone は OS が選ぶ）
        var named = false
        #if os(macOS)
        if let dev = Platform.resolveMic(micUID), let cap = DeviceCapture(uid: dev.uid, onBuffer: onBuffer) {
            cap.start()
            capture = cap
            inputName = dev.name
            named = true
        }
        #endif
        if !named {
            inputName = Platform.inputDeviceName
            engineNote = ""
            // Bluetooth へ切り替わる途中だと入力形式が 0 Hz のことがあるので、少し待って何度か試す
            var lastError: Error?
            for wait in [0.0, 0.3, 0.8, 1.5] {
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                do { try startEngine(onBuffer); lastError = nil; break } catch { lastError = error }
            }
            if let lastError { stopCaptions(); sink.close(); throw lastError }
            // **Bluetooth イヤホン（HFP）に切り替わると、エンジンの入力形式が変わってエンジンが止まる**
            // （iPhone 18 Pro＋WF-1000XM4 で実測: 音量ゼロのまま「音が入っていません」）。
            // 形式が変わったら、新しい形式でタップを張り直して動かし直す。失敗したら間を置いて何度か試す
            let restart: @Sendable (String) -> Void = { [weak self] why in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.restartTask?.cancel()
                    self.restartTask = Task { @MainActor in
                        for wait in [0.1, 0.4, 1.0, 2.0] {
                            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                            guard self.isRecording, !Task.isCancelled else { return }
                            self.engine.inputNode.removeTap(onBus: 0)
                            if self.engine.isRunning { self.engine.stop() }
                            self.inputName = Platform.inputDeviceName
                            do { try self.startEngine(onBuffer); self.engineNote = ""; return }
                            catch { self.engineNote = "\(why)のあと録音を張り直せていません: \(error.localizedDescription)" }
                        }
                    }
                }
            }
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in restart("入力の切り替え") }
            #if os(iOS)
            routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { n in
                // 新しい機器がつながった・外れたときだけ（それ以外の理由は AVAudioEngine 側の通知で足りる）
                let raw = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
                if raw == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue || raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    restart("イヤホンの付け外し")
                }
            }
            #endif
        }
        isRecording = true
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.started else { return }
                self.seconds = Int(Date().timeIntervalSince(s))
                self.micSilent = Date().timeIntervalSince(self.lastSound ?? s) >= Self.silentAfter
            }
        }
    }

    /// 今の入力形式でタップを張ってエンジンを動かす（開始時と、入力が切り替わったときの両方で使う）
    private func startEngine(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw Failure.engine(String(localized: "マイクの形式が取れませんでした")) }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in onBuffer(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw Failure.engine(error.localizedDescription)
        }
        inputDetail = "\(Int(inFormat.sampleRate)) Hz・\(inFormat.channelCount)ch"
    }

    func stop() async -> Result? {
        guard isRecording else { return nil }
        isRecording = false
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        if let o = routeObserver { NotificationCenter.default.removeObserver(o); routeObserver = nil }
        restartTask?.cancel(); restartTask = nil
        timer?.invalidate(); timer = nil
        var named = false
        #if os(macOS)
        if let cap = capture { cap.stop(); capture = nil; named = true }
        #endif
        if !named {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        let text = await finishCaptions()
        sink.close()
        Platform.deactivateAudioSession()
        level = 0; micSilent = false
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        fileURL = nil
        return Result(audio: data, transcript: text, seconds: seconds)
    }

    // MARK: - 字幕（端末の音声認識）
    //
    // 認識は**一度に 1 本**しか動かせない（端末内でもサーバーでも、2 本目を始めると 1 本目が
    // 「No speech detected」で落ち、交互に落ち続ける・2026-10-12 Mac で実測。test: scratchpad hgcap.log）。
    // そこで、ふだんは話す言語（例: 英語）の認識を動かし、学習者が「寅さん」と呼びかけたら
    // 母語（日本語）の認識に切り替え、間が空いたら（認識が区切りを返したら）話す言語に戻す。
    // 英語が出てこなくて日本語で言うときは「寅さん、〜って何て言う？」と呼びかける使い方なので、これで拾える。
    // 母語側はアプリの表示が日本語で、話す言語が日本語でないときだけ用意する。
    // 区切りには時刻を付け、切り替えをまたいでも一本の時間軸に並べて字幕にする（merge）

    private func startCaptions(language: String) {
        if #available(iOS 26.0, macOS 26.0, *) {
            // 新しい認識（SpeechAnalyzer）は 2 本同時に動かせる（2026-10-12 Mac で実測: scratchpad sa_test.swift）。
            // 話す言語と母語を同時に聞き、日本語に見えるかたまりだけ日本語を採る。呼びかけは要らない
            let nativeLocale: Locale? = (TargetLanguage.explanation == .ja && !language.hasPrefix("ja")) ? Locale(identifier: "ja-JP") : nil
            let ac = AnalyzerCaptions()
            ac.onChange = { [weak self] in self?.refreshCaptions() }
            analyzerCaptions = ac
            doneSegs = []
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor in
                    guard let self, self.wantCaptions else { return }
                    guard status == .authorized else { self.captionsAvailable = false; return }
                    do {
                        try await ac.start(primary: Locale(identifier: language), native: nativeLocale, sink: self.sink)
                        self.captionsAvailable = self.wantCaptions
                    } catch {
                        CapLog.write("HGCAP analyzer start failed: %@", String(describing: error))
                        // 新しい認識が使えなければ従来の認識に落ちる
                        self.analyzerCaptions = nil
                        self.startLegacyCaptions(language: language)
                    }
                }
            }
            return
        }
        startLegacyCaptions(language: language)
    }

    /// 従来の認識（SFSpeechRecognizer）。一度に 1 本なので「寅さん」の呼びかけで母語に切り替える
    private func startLegacyCaptions(language: String) {
        guard let primary = SFSpeechRecognizer(locale: Locale(identifier: language)), primary.isAvailable else {
            captionsAvailable = false; return
        }
        primaryRecognizer = primary
        nativeRecognizer = nil
        if TargetLanguage.explanation == .ja, !language.hasPrefix("ja"),
           let native = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), native.isAvailable {
            nativeRecognizer = native
        }
        doneSegs = []
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self, self.wantCaptions else { return }
                guard status == .authorized else { self.captionsAvailable = false; return }
                self.captionsAvailable = true
                self.runStream(native: false)
            }
        }
    }

    /// 話す言語（native=false）か母語（native=true）の認識を 1 本だけ動かす
    private func runStream(native: Bool) {
        guard wantCaptions else { return }
        guard let r = native ? nativeRecognizer : primaryRecognizer else { return }
        active?.stop()
        nativeIdle?.cancel(); nativeIdle = nil
        let st = CaptionStream(recognizer: r, native: native)
        let sink = self.sink
        st.attach = { req in sink.attach(req, slot: 0) }
        st.clock = { [weak self] in self?.started.map { Date().timeIntervalSince($0) } ?? 0 }
        st.onChange = { [weak self] in self?.captionsChanged() }
        st.onEnd = { [weak self] in self?.streamEnded() }
        active = st
        nativeSince = native ? Date() : nil
        st.start()
        CapLog.write("HGCAP run native=%d", native ? 1 : 0)
    }

    /// 途中結果が更新された。話す言語の認識中に「寅さん」の呼びかけが聞こえたら母語へ切り替える
    private func captionsChanged() {
        guard let st = active else { return }
        if !st.native, nativeRecognizer != nil {
            let tail = st.live.suffix(4)
            if let hit = Self.coachCall(in: tail.map(\.text)) {
                // 呼びかけの語そのものは字幕に残さない
                var segs = st.segments
                segs.removeLast(min(hit, segs.count))
                doneSegs += segs
                CapLog.write("HGCAP coach call -> native (drop %d)", hit)
                runStream(native: true)
                refreshCaptions()
                return
            }
        }
        if st.native {
            // 母語の認識は、英語に戻っても止まらずカタカナを吐き続ける（実測: "ドゥザBad"）。
            // いまの一文が日本語に見えなくなったら、そこで話す言語に戻す（その一文は捨てる）
            let liveText = st.live.map(\.text).joined()
            if liveText.count >= 2, !st.done.isEmpty || liveText.count >= 6, !Self.looksJapanese(liveText) {
                doneSegs += st.done
                CapLog.write("HGCAP native looks foreign -> primary: %@", liveText)
                runStream(native: false)
                refreshCaptions()
                return
            }
            // 1.5 秒なにも変わらなければ（言い終わって間が空いた）話す言語に戻す。20 秒を超えても戻す
            nativeIdle?.cancel()
            nativeIdle = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled, let st = self.active, st.native else { return }
                self.doneSegs += st.segments
                CapLog.write("HGCAP native idle -> primary")
                self.runStream(native: false)
                self.refreshCaptions()
            }
            if let since = nativeSince, Date().timeIntervalSince(since) > 20 {
                doneSegs += st.segments
                runStream(native: false)
            }
        }
        refreshCaptions()
    }

    /// 認識が終わった（確定・打ち切り・間が空いた）。母語なら話す言語へ戻し、話す言語なら張り直す
    private func streamEnded() {
        guard wantCaptions, let st = active else { return }
        doneSegs += st.segments
        active = nil
        refreshCaptions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.wantCaptions, self.active == nil else { return }
            self.runStream(native: false)
        }
    }

    /// 英語の認識が「寅さん」と聞いた形。該当したら、呼びかけに使われた区切りの数を返す
    /// （英語の認識は Tora-san を Torah son / tora san / tourists on などと書く）
    static func coachCall(in words: [String]) -> Int? {
        let joined = words.joined(separator: " ").lowercased()
        // Mac の実測: 合成音声の Tora-san は "Toran" と聞こえた。人の声では Torah son / tora san なども出る
        let patterns = ["\\b(tora|torah|thora|tola|toro|taura|tara)\\s*-?\\s*(san|son|sun|sign|sans|sang)\\b", "\\btourists?\\s*(on|an)\\b",
                        "\\btaurus\\s*(on|an)\\b", "\\btora-?san\\b", "\\b(toran|torasan|torah|tora)\\b"]
        for pat in patterns {
            if let re = try? NSRegularExpression(pattern: pat), let m = re.firstMatch(in: joined, range: NSRange(joined.startIndex..., in: joined)),
               let r = Range(m.range, in: joined) {
                // 一致した文字列に含まれる語の数ぶんの区切りを落とす（区切りはだいたい語ごと）
                let n = joined[r].split(separator: " ").count
                return max(1, min(n, words.count))
            }
        }
        return nil
    }

    private func refreshCaptions() {
        if #available(iOS 26.0, macOS 26.0, *), let ac = analyzerCaptions as? AnalyzerCaptions {
            transcript = Self.merge(primary: ac.segments(native: false), native: ac.segments(native: true))
            interim = ""
            return
        }
        transcript = Self.merge(primary: doneSegs.filter { !$0.native } + (active?.native == false ? active!.segments : []),
                                native: doneSegs.filter(\.native) + (active?.native == true ? active!.segments : []))
        interim = ""
    }

    /// 話す言語の区切りと母語の区切りを一本の時間軸に並べる。
    /// 母語側は「日本語に見えるかたまり」だけ採り、その時間帯の話す言語側は捨てる
    static func merge(primary: [CaptionSeg], native: [CaptionSeg]) -> String {
        var chosen = primary
        if !native.isEmpty {
            // 0.6 秒以内に続く、同じ文字種（日本語の文字を含む／含まない）の区切りをひとかたまりにして、
            // かたまりごとに日本語かどうかを見る。日本語の認識は英語を聞くとローマ字で書くので、文字種で切ると英語の部分が分かれる
            var groups: [[CaptionSeg]] = []
            for sg in native.sorted(by: { $0.t < $1.t }) {
                if var last = groups.last, let tail = last.last, sg.t - (tail.t + tail.d) < 0.6, hasJapaneseScript(tail.text) == hasJapaneseScript(sg.text) {
                    last.append(sg); groups[groups.count - 1] = last
                } else { groups.append([sg]) }
            }
            let jaGroups = groups.filter { looksJapanese($0.map(\.text).joined()) }
            let spans = jaGroups.map { g -> (Double, Double) in (g.first!.t, g.last!.t + g.last!.d) }
            chosen = primary.filter { e in !spans.contains { e.t < $0.1 && e.t + e.d > $0.0 } } + jaGroups.flatMap { $0 }
        }
        chosen.sort { $0.t < $1.t }
        var out = ""
        var prev: CaptionSeg?
        for sg in chosen {
            if let p = prev {
                if p.native != sg.native { out += "\n" }            // 言語が変わるところで行を分ける
                else if !sg.native { out += " " }                   // 英語などは語の間に空白、日本語は詰める
            }
            out += sg.text; prev = sg
        }
        return out
    }

    /// ひらがな・カタカナ・漢字を 1 文字でも含むか
    static func hasJapaneseScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { u in
            (0x3041...0x309F).contains(u.value) || (0x30A0...0x30FF).contains(u.value) || (0x4E00...0x9FFF).contains(u.value) || (0xFF66...0xFF9F).contains(u.value)
        }
    }

    /// 日本語の認識が返した文字列が「本当に日本語を話した」ものに見えるか。
    /// ひらがなか漢字が混ざっていて、カタカナが半分未満（英語を日本語で聞くとカタカナだらけになる）
    static func looksJapanese(_ text: String) -> Bool {
        var hira = 0, kana = 0, kanji = 0, total = 0
        for u in text.unicodeScalars {
            if u.properties.isWhitespace { continue }
            total += 1
            switch u.value {
            case 0x3041...0x309F: hira += 1
            case 0x30A0...0x30FF, 0xFF66...0xFF9F: kana += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: kanji += 1
            default: break
            }
        }
        guard total >= 2, hira + kanji > 0 else { return false }
        return Double(kana) / Double(total) < 0.5
    }

    /// 新しい途中結果が「前の続き」ではなく「頭から作り直し」に見えるか。
    /// 前の文の先頭 12 文字を引き継いでいなければ作り直しとみなす（短い言い直しは引き継ぐので誤判定しにくい）
    static func looksRestarted(prev: String, now: String) -> Bool {
        let head = String(prev.prefix(12))
        if head.count < 6 { return false }
        return !now.hasPrefix(head)
    }

    private func stopCaptions() {
        wantCaptions = false
        nativeIdle?.cancel(); nativeIdle = nil
        active?.stop(); active = nil
        if #available(iOS 26.0, macOS 26.0, *), let ac = analyzerCaptions as? AnalyzerCaptions { ac.cancel(); analyzerCaptions = nil }
    }

    /// 停止時：最後の未確定分を短く待って拾い、字幕の全文を返す
    private func finishCaptions() async -> String {
        guard wantCaptions else { return transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
        wantCaptions = false
        if #available(iOS 26.0, macOS 26.0, *), let ac = analyzerCaptions as? AnalyzerCaptions {
            await ac.finish()
            refreshCaptions()
            analyzerCaptions = nil
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        active?.endAudio()
        try? await Task.sleep(nanoseconds: 700_000_000)
        refreshCaptions()
        active?.stop(); active = nil
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 時刻つきの字幕の区切り。t と d は録音開始からの秒
struct CaptionSeg: Equatable {
    var t: Double
    var d: Double
    var text: String
    var native: Bool     // 母語（日本語）の認識が返したもの
}

/// 認識 1 本ぶん（1 タスク）。終わったら onEnd を呼ぶだけで、張り直しは Recorder が決める
@MainActor
private final class CaptionStream {
    let recognizer: SFSpeechRecognizer
    let native: Bool
    private(set) var done: [CaptionSeg] = []      // 確定した区切り（頭からの作り直しで押し出された分）
    private(set) var live: [CaptionSeg] = []      // いまの途中結果の区切り（結果が来るたびに丸ごと入れ替わる）
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var base: Double = 0                  // リクエストを作った時点の、録音開始からの秒
    private var liveText = ""                     // いまの途中結果の全文（作り直しの検知用）
    private var ended = false
    var attach: (SFSpeechAudioBufferRecognitionRequest?) -> Void = { _ in }
    var clock: () -> Double = { 0 }
    var onChange: () -> Void = {}
    var onEnd: () -> Void = {}

    init(recognizer: SFSpeechRecognizer, native: Bool) {
        self.recognizer = recognizer; self.native = native
    }

    var segments: [CaptionSeg] { done + live }

    func start() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        base = clock()
        attach(req)
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.request === req, !self.ended else { return }
                if let result {
                    self.take(result)
                    if result.isFinal { self.finish(); return }
                    self.onChange()
                }
                if let error {
                    CapLog.write("HGCAP native=%d error: %@", self.native ? 1 : 0, String(describing: error))
                    self.finish()
                }
            }
        }
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        attach(nil)
        request = nil; task = nil
        onEnd()
    }

    /// 途中結果を時刻つきの区切りに直す。
    /// iOS の認識は、文の切れ目で isFinal を出さずに本文を頭から作り直すことがある（前の文が画面から消える）。
    /// 新しい結果が前の結果より後ろの時刻から始まっていたら、その前の区切りは確定に回す
    private func take(_ result: SFSpeechRecognitionResult) {
        let raw = result.bestTranscription.segments
        let text = result.bestTranscription.formattedString
        // 「頭からの作り直し」は、前の文の先頭を引き継いでいないことで見る（区切りの時刻は作り直しごとに 0 に戻るので当てにしない）
        if !liveText.isEmpty, Recorder.looksRestarted(prev: liveText, now: text) {
            done += live
            // 作り直し後の区切りは「いま」から始まるものとして時刻を振る
            base = clock()
        }
        liveText = text
        var segs = raw.map { CaptionSeg(t: base + $0.timestamp, d: $0.duration, text: $0.substring, native: native) }
        if !raw.isEmpty, raw.allSatisfy({ $0.timestamp == 0 && $0.duration == 0 }) {
            segs = text.isEmpty ? [] : [CaptionSeg(t: base, d: max(0, clock() - base), text: text, native: native)]
        }
        live = segs
    }

    func endAudio() { request?.endAudio() }

    func stop() {
        ended = true
        attach(nil)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
    }
}

/// 新しい認識（SpeechAnalyzer）で、話す言語と母語の書き起こしを同時に動かす。
/// 結果は語ごとの時刻つきで、確定分（finals）と未確定分（volatile）を言語ごとに持つ
@available(iOS 26.0, macOS 26.0, *)
@MainActor
fileprivate final class AnalyzerCaptions {
    private struct Lane {
        let native: Bool
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        var finals: [CaptionSeg] = []
        var volatileSegs: [CaptionSeg] = []
        var reader: Task<Void, Never>?
    }
    private var lanes: [Lane] = []
    var onChange: () -> Void = {}

    func segments(native: Bool) -> [CaptionSeg] {
        guard let l = lanes.first(where: { $0.native == native }) else { return [] }
        return l.finals + l.volatileSegs
    }

    func start(primary: Locale, native: Locale?, sink: Sink) async throws {
        var specs: [(Locale, Bool)] = [(primary, false)]
        if let native { specs.append((native, true)) }
        var transcribers: [SpeechTranscriber] = []
        for (loc, _) in specs {
            let t = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
            // 言語の素材が入っていなければ取りに行く（初回だけ時間がかかる）
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) { try await req.downloadAndInstall() }
            transcribers.append(t)
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: transcribers)
        var feeds: [(AVAudioPCMBuffer) -> Void] = []
        for (i, (_, isNative)) in specs.enumerated() {
            let t = transcribers[i]
            let analyzer = SpeechAnalyzer(modules: [t])
            let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            var lane = Lane(native: isNative, transcriber: t, analyzer: analyzer, continuation: cont)
            lane.reader = Task { [weak self] in
                do {
                    for try await r in t.results {
                        await MainActor.run { self?.take(r, native: isNative) }
                    }
                } catch { CapLog.write("HGCAP analyzer native=%d results error: %@", isNative ? 1 : 0, String(describing: error)) }
            }
            lanes.append(lane)
            feeds.append { buf in cont.yield(AnalyzerInput(buffer: buf)) }
        }
        sink.setAnalyzer(format: format, feed: feeds)
        CapLog.write("HGCAP analyzer started lanes=%d format=%@", lanes.count, format?.description ?? "nil")
    }

    /// 結果を語ごとの区切りに直す。確定なら finals に積み、未確定なら volatile を丸ごと入れ替える
    private func take(_ r: SpeechTranscriber.Result, native: Bool) {
        guard let idx = lanes.firstIndex(where: { $0.native == native }) else { return }
        var segs: [CaptionSeg] = []
        for run in r.text.runs {
            let text = String(r.text[run.range].characters)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let tr = run.audioTimeRange {
                segs.append(CaptionSeg(t: CMTimeGetSeconds(tr.start), d: CMTimeGetSeconds(tr.duration), text: text.trimmingCharacters(in: .whitespaces), native: native))
            } else {
                segs.append(CaptionSeg(t: CMTimeGetSeconds(r.range.start), d: CMTimeGetSeconds(r.range.duration), text: text.trimmingCharacters(in: .whitespaces), native: native))
            }
        }
        if r.isFinal { lanes[idx].finals += segs; lanes[idx].volatileSegs = [] }
        else { lanes[idx].volatileSegs = segs }
        if r.isFinal { CapLog.write("HGCAP analyzer native=%d final text=%@", native ? 1 : 0, String(r.text.characters)) }
        onChange()
    }

    /// 停止時: 入力を閉じて、残りを確定させる（長くても 1.5 秒）
    func finish() async {
        for l in lanes { l.continuation.finish() }
        await withTaskGroup(of: Void.self) { group in
            for l in lanes {
                group.addTask { try? await l.analyzer.finalizeAndFinishThroughEndOfInput() }
            }
            group.addTask { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            await group.next()
            group.cancelAll()
        }
        for l in lanes { l.reader?.cancel() }
    }

    func cancel() {
        for l in lanes { l.continuation.finish(); l.reader?.cancel(); Task { try? await l.analyzer.cancelAndFinishNow() } }
        lanes = []
    }
}

/// 字幕の不具合を追うための記録（DEBUG だけ）。アプリの tmp に hgcap.log を書く
enum CapLog {
    static func write(_ format: String, _ args: CVarArg...) {
        #if DEBUG
        let line = "\(Date()) " + String(format: format, arguments: args) + "\n"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hgcap.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        #endif
    }
}
