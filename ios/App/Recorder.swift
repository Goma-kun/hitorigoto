import Foundation
import AVFoundation
import Speech

/// オーディオスレッドと画面側の橋渡し。マイクのタップは別スレッドから呼ばれるので、
/// 書き込み先と認識リクエストの差し替えをロックで守る（まもるくん iOS 版の AudioSink と同じ型）
private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func open(file: AVAudioFile) {
        lock.lock(); defer { lock.unlock() }
        self.file = file; self.converter = nil
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        file = nil; converter = nil; request = nil
    }

    func attach(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }
        self.request = request
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
        request?.append(buffer)
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
    private var started: Date?

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
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
        if let name = Platform.inputName(uid: micUID), let cap = DeviceCapture(uid: micUID, onBuffer: onBuffer) {
            cap.start()
            capture = cap
            inputName = name
            named = true
        }
        #endif
        if !named {
            inputName = Platform.inputDeviceName
            do { try startEngine(onBuffer) } catch {
                stopCaptions(); sink.close()
                throw error
            }
            // **Bluetooth イヤホン（HFP）に切り替わると、エンジンの入力形式が変わってエンジンが止まる**
            // （iPhone 18 Pro＋WF-1000XM4 で実測: 音量ゼロのまま「音が入っていません」）。
            // 形式が変わったら、新しい形式でタップを張り直して動かし直す
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self, self.isRecording else { return }
                self.engine.inputNode.removeTap(onBus: 0)
                self.inputName = Platform.inputDeviceName
                try? self.startEngine(onBuffer)
            }
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
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw Failure.engine("マイクの形式が取れませんでした") }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in onBuffer(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw Failure.engine(error.localizedDescription)
        }
    }

    func stop() async -> Result? {
        guard isRecording else { return nil }
        isRecording = false
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        timer?.invalidate(); timer = nil
        var named = false
        #if os(macOS)
        if let cap = capture { cap.stop(); capture = nil; named = true }
        #endif
        if !named {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        let tail = await finishCaptions()
        sink.close()
        Platform.deactivateAudioSession()
        level = 0; micSilent = false
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        fileURL = nil
        let text = (transcript + (tail.isEmpty ? "" : tail + "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(audio: data, transcript: text, seconds: seconds)
    }

    // MARK: - 字幕（端末の音声認識）

    private func startCaptions(language: String) {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: language)), r.isAvailable else {
            captionsAvailable = false; return
        }
        recognizer = r
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self, self.wantCaptions else { return }
                guard status == .authorized else { self.captionsAvailable = false; return }
                self.captionsAvailable = true
                self.newCaptionTask()
            }
        }
    }

    /// 認識タスクは 1 分ほどで打ち切られるので、終わるたびに確定分を積んで張り直す
    private func newCaptionTask() {
        guard let r = recognizer, wantCaptions else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        sink.attach(req)
        task = r.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.request === req else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        if !text.isEmpty { self.transcript += text + "\n" }
                        self.interim = ""
                        if self.wantCaptions { self.newCaptionTask() }
                    } else {
                        // iOS の認識は、文の切れ目で isFinal を出さずに本文を頭から作り直すことがある
                        // （前の文が画面から消えて次の文だけになる・2026-10-09 本人指摘）。
                        // 作り直しに気づいたら、それまでの文を確定分へ積んでから続ける
                        let prev = self.interim
                        if !prev.isEmpty, Self.looksRestarted(prev: prev, now: text) {
                            self.transcript += prev + "\n"
                        }
                        self.interim = text
                    }
                }
                if error != nil {
                    // 打ち切り・一時的な失敗。未確定分を確定に回して張り直す
                    if !self.interim.isEmpty { self.transcript += self.interim + "\n"; self.interim = "" }
                    self.request = nil
                    self.sink.attach(nil)
                    if self.wantCaptions && self.isRecording {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.newCaptionTask() }
                    }
                }
            }
        }
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
        sink.attach(nil)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
    }

    /// 停止時：最後の未確定分を短く待って拾う
    private func finishCaptions() async -> String {
        guard wantCaptions else { return "" }
        wantCaptions = false
        sink.attach(nil)
        request?.endAudio()
        try? await Task.sleep(nanoseconds: 700_000_000)
        let tail = interim
        interim = ""
        task?.cancel()
        request = nil; task = nil
        return tail
    }
}
