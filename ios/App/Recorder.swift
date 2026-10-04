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

    func open(file: AVAudioFile, converter: AVAudioConverter?) {
        lock.lock(); defer { lock.unlock() }
        self.file = file; self.converter = converter
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
            if let conv = converter {
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
    private var fileURL: URL?
    private var timer: Timer?
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

    func start(captions: Bool, language: String) async throws {
        guard !isRecording else { return }
        guard await Platform.requestMicrophone() else { throw Failure.micDenied }
        try Platform.activateAudioSession()

        transcript = ""; interim = ""; seconds = 0; level = 0
        micSilent = false; lastSound = nil
        inputName = Platform.inputDeviceName
        wantCaptions = captions

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hitorigoto-\(Int(Date().timeIntervalSince1970)).m4a")
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw Failure.engine("マイクの形式が取れませんでした") }

        // 16kHz モノラル 32kbps の AAC。5 分で 1.2MB ほど
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        fileURL = url
        sink.open(file: file, converter: AVAudioConverter(from: inFormat, to: file.processingFormat))

        if captions { startCaptions(language: language) }

        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
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
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            stopCaptions()
            sink.close()
            throw Failure.engine(error.localizedDescription)
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

    func stop() async -> Result? {
        guard isRecording else { return nil }
        isRecording = false
        timer?.invalidate(); timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
