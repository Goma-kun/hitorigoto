import Foundation
import AVFoundation
import Speech

/// オーディオスレッドと画面側の橋渡し。マイクのタップは別スレッドから呼ばれるので、
/// 書き込み先と認識リクエストの差し替えをロックで守る（まもるくん iOS 版の AudioSink と同じ型）
private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var requests: [SFSpeechAudioBufferRecognitionRequest?] = [nil, nil]   // 0: 話す言語、1: 母語（日本語）

    func open(file: AVAudioFile) {
        lock.lock(); defer { lock.unlock() }
        self.file = file; self.converter = nil
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        file = nil; converter = nil; requests = [nil, nil]
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

    /// 認識は 2 本まで並走する: [0] 話す言語、[1] 母語（日本語）。詳しくは「字幕」の節
    private var streams: [CaptionStream] = []
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
    // 認識は 2 本並走させることがある: 話す言語（例: 英語）と、学習者の母語（日本語）。
    // 英語が出てこなくて日本語で言った箇所は、英語の認識だと英単語に化けて読めない（2026-10-11 本人）。
    // 両方の認識が返す区切り（時刻つき）を一本の時間軸に並べ、日本語側が「本当に日本語を話している」と
    // 見えるかたまり（ひらがな・漢字が混ざる。英語を日本語で聞くとカタカナばかりになる）だけ日本語を採り、
    // その時間帯の話す言語側の区切りは捨てる。母語側は、アプリの表示が日本語で、話す言語が日本語でないときだけ動かす

    private func startCaptions(language: String) {
        guard let primary = SFSpeechRecognizer(locale: Locale(identifier: language)), primary.isAvailable else {
            captionsAvailable = false; return
        }
        var list = [CaptionStream(recognizer: primary, native: false, slot: 0)]
        if TargetLanguage.explanation == .ja, !language.hasPrefix("ja"),
           let native = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), native.isAvailable {
            list.append(CaptionStream(recognizer: native, native: true, slot: 1))
        }
        let sink = self.sink
        for st in list {
            st.attach = { req, slot in sink.attach(req, slot: slot) }
            st.clock = { [weak self] in self?.started.map { Date().timeIntervalSince($0) } ?? 0 }
            st.onChange = { [weak self] in self?.refreshCaptions() }
        }
        streams = list
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self, self.wantCaptions else { return }
                guard status == .authorized else { self.captionsAvailable = false; return }
                self.captionsAvailable = true
                for st in self.streams { st.start() }
            }
        }
    }

    /// 2 本の認識の区切りを一本に並べて、字幕の文字列にする
    private func refreshCaptions() {
        transcript = Self.merge(primary: streams.first?.segments ?? [], native: streams.count > 1 ? streams[1].segments : [])
        interim = ""
    }

    /// 話す言語の区切りと母語の区切りを一本の時間軸に並べる。
    /// 母語側は「日本語に見えるかたまり」だけ採り、その時間帯の話す言語側は捨てる
    static func merge(primary: [CaptionSeg], native: [CaptionSeg]) -> String {
        var chosen = primary
        if !native.isEmpty {
            // 0.6 秒以内に続く区切りをひとかたまりにして、かたまりごとに日本語かどうかを見る
            var groups: [[CaptionSeg]] = []
            for sg in native.sorted(by: { $0.t < $1.t }) {
                if var last = groups.last, let tail = last.last, sg.t - (tail.t + tail.d) < 0.6 {
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
        for st in streams { st.stop() }
        streams = []
    }

    /// 停止時：最後の未確定分を短く待って拾い、字幕の全文を返す
    private func finishCaptions() async -> String {
        guard wantCaptions else { return transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
        wantCaptions = false
        for st in streams { st.endAudio() }
        try? await Task.sleep(nanoseconds: 700_000_000)
        refreshCaptions()
        for st in streams { st.stop() }
        streams = []
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

/// 認識 1 本ぶん。タスクは 1 分ほどで打ち切られるので、終わるたびに確定分を積んで張り直す
@MainActor
private final class CaptionStream {
    let recognizer: SFSpeechRecognizer
    let native: Bool
    let slot: Int
    private var done: [CaptionSeg] = []      // 確定した区切り
    private var live: [CaptionSeg] = []      // いまの途中結果の区切り（結果が来るたびに丸ごと入れ替わる）
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var base: Double = 0             // いまのリクエストを作った時点の、録音開始からの秒
    private var wantMore = true
    var attach: (SFSpeechAudioBufferRecognitionRequest?, Int) -> Void = { _, _ in }
    var clock: () -> Double = { 0 }
    var onChange: () -> Void = {}

    init(recognizer: SFSpeechRecognizer, native: Bool, slot: Int) {
        self.recognizer = recognizer; self.native = native; self.slot = slot
    }

    var segments: [CaptionSeg] { done + live }

    func start() { wantMore = true; newTask() }

    private func newTask() {
        guard wantMore else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        base = clock()
        attach(req, slot)
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.request === req else { return }
                if let result {
                    self.take(result)
                    if result.isFinal {
                        self.done += self.live; self.live = []
                        self.onChange()
                        if self.wantMore { self.newTask() }
                        return
                    }
                    self.onChange()
                }
                if error != nil {
                    // 打ち切り・一時的な失敗。未確定分を確定に回して張り直す
                    self.done += self.live; self.live = []
                    self.request = nil
                    self.attach(nil, self.slot)
                    self.onChange()
                    if self.wantMore {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.newTask() }
                    }
                }
            }
        }
    }

    /// 途中結果を時刻つきの区切りに直す。
    /// iOS の認識は、文の切れ目で isFinal を出さずに本文を頭から作り直すことがある（前の文が画面から消える）。
    /// 新しい結果が前の結果より後ろの時刻から始まっていたら、その前の区切りは確定に回す
    private func take(_ result: SFSpeechRecognitionResult) {
        let raw = result.bestTranscription.segments
        var segs = raw.map { CaptionSeg(t: base + $0.timestamp, d: $0.duration, text: $0.substring, native: native) }
        // 時刻が付かない認識（全部 0）のときは、結果全体を 1 つの区切りとして扱う
        if !raw.isEmpty, raw.allSatisfy({ $0.timestamp == 0 && $0.duration == 0 }) {
            let text = result.bestTranscription.formattedString
            segs = text.isEmpty ? [] : [CaptionSeg(t: base, d: max(0, clock() - base), text: text, native: native)]
        }
        if let first = segs.first, let oldFirst = live.first, first.t > oldFirst.t + 0.5 {
            done += live.filter { $0.t + $0.d <= first.t }
        }
        live = segs
    }

    func endAudio() { request?.endAudio() }

    func stop() {
        wantMore = false
        attach(nil, slot)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
    }
}
