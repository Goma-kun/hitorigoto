import AVFoundation
import Foundation
import SwiftUI

// 自分や友人の声を「三人で話す」の相手役にする（本人の要望・2026-10-29「自分とか友人の声をアップロードして使えるようにしたい」）。
//
// 仕組み: Gemini の声の複製（Voices API）。10〜30 秒の話し声と、Google が定めた同意の文を読んだ声の 2 本を送ると、
// 端末だけが持つ鍵（voicekey_…）が返る。store=false なので Google 側には声を残さない。鍵は 7 日で切れるので、
// 録った 2 本は端末に置いておき（Application Support/Hitorigoto/voices/）、古くなったら作り直す。
// 同意の文は本人がそのまま読む必要がある（違うと弾かれる）ので、「友人の声」は友人にその文を読んでもらう＝本人の同意がそのまま仕組みになる。

/// 登録した声 1 人分
struct CustomVoice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var female: Bool
    var blurb: String
    /// Gemini の鍵（voicekey_…）。7 日で切れる
    var voiceKey: String
    var keyMadeAt: Date

    /// 相手役として
    var partner: Partner {
        Voice.customPartner(id: id, name: name, female: female, blurb: blurb.isEmpty ? String(localized: "自分や友人の声") : blurb, voice: voiceKey)
    }
    /// 鍵が古い（6 日を過ぎた）。7 日で切れるので 1 日前に作り直す
    var stale: Bool { Date().timeIntervalSince(keyMadeAt) > 6 * 86400 }
}

@MainActor
final class CustomVoices: ObservableObject {
    static let shared = CustomVoices()

    @Published private(set) var list: [CustomVoice] = []
    /// 鍵を作り直している声の id
    @Published private(set) var refreshing: Set<String> = []
    /// 作り直せなかった声の id → 理由
    @Published private(set) var refreshFailed: [String: String] = [:]

    var partners: [Partner] { list.map(\.partner) }

    /// 置き場所（記録と同じフォルダの voices/）。iCloud には乗せない（声は端末の中だけ）
    static var dir: URL? {
        guard let base = try? SnapshotStore.defaultURL().deletingLastPathComponent() else { return nil }
        let d = base.appendingPathComponent("voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var indexURL: URL? { dir?.appendingPathComponent("voices.json") }
    static func sourceURL(_ id: String) -> URL? { dir?.appendingPathComponent("\(id)-source.wav") }
    static func consentURL(_ id: String) -> URL? { dir?.appendingPathComponent("\(id)-consent.wav") }

    init() {
        if let u = Self.indexURL, let d = try? Data(contentsOf: u), let l = try? JSONDecoder().decode([CustomVoice].self, from: d) { list = l }
    }

    private func save() {
        guard let u = Self.indexURL, let d = try? JSONEncoder().encode(list) else { return }
        try? d.write(to: u, options: .atomic)
    }

    /// 登録する（鍵はもう作ってある）。録った 2 本も端末に置く（鍵の作り直し用）
    func add(name: String, female: Bool, blurb: String, source: Data, consent: Data, key: String) -> CustomVoice {
        let id = UUID().uuidString.lowercased()
        if let u = Self.sourceURL(id) { try? source.write(to: u, options: .atomic) }
        if let u = Self.consentURL(id) { try? consent.write(to: u, options: .atomic) }
        let v = CustomVoice(id: id, name: name, female: female, blurb: blurb, voiceKey: key, keyMadeAt: Date())
        list.append(v)
        save()
        return v
    }

    /// 消す（録った声のファイルも）
    func remove(_ id: String) {
        list.removeAll { $0.id == id }
        for u in [Self.sourceURL(id), Self.consentURL(id)].compactMap({ $0 }) { try? FileManager.default.removeItem(at: u) }
        save()
    }

    /// 相手役の id（custom:…）からこの声
    func voice(forPartner partnerId: String) -> CustomVoice? {
        guard partnerId.hasPrefix(Voice.customPrefix) else { return nil }
        let id = String(partnerId.dropFirst(Voice.customPrefix.count))
        return list.first { $0.id == id }
    }

    /// その相手役の鍵が古ければ、録ってある声から作り直して待つ（会話を始める前に呼ぶ）
    func ensureFresh(partnerId: String, client: GeminiClient?) async {
        guard let v = voice(forPartner: partnerId), v.stale else { return }
        await refresh(v, client: client)
    }

    /// 古い鍵をぜんぶ作り直す（シートを開いたときに裏で）
    func refreshStale(client: GeminiClient?) async {
        for v in list where v.stale { await refresh(v, client: client) }
    }

    private func refresh(_ v: CustomVoice, client: GeminiClient?) async {
        guard let client, !refreshing.contains(v.id) else { return }
        guard let su = Self.sourceURL(v.id), let cu = Self.consentURL(v.id),
              let source = try? Data(contentsOf: su), let consent = try? Data(contentsOf: cu) else {
            refreshFailed[v.id] = String(localized: "録った声が見つかりません。消して、もう一度登録してください。")
            return
        }
        refreshing.insert(v.id); refreshFailed[v.id] = nil
        defer { refreshing.remove(v.id) }
        do {
            let key = try await client.createVoice(source: source, consent: consent)
            if let i = list.firstIndex(where: { $0.id == v.id }) {
                list[i].voiceKey = key
                list[i].keyMadeAt = Date()
                save()
            }
        } catch {
            refreshFailed[v.id] = Self.describe(error)
        }
    }

    /// 声の複製の失敗を、画面に出す言葉に
    static func describe(_ error: Error) -> String {
        switch error as? GeminiClient.Failure {
        case .consentRejected:
            return String(localized: "同意の文が、画面のとおりに読めていないようです。静かな所で、文を一字も変えずにはっきり読んで、もう一度お試しください。")
        case .voiceRejected(let m):
            let short = m.count > 160 ? String(m.prefix(160)) + "…" : m
            return String(localized: "この声は登録できませんでした。話し声は 10〜30 秒、同じ人の声を同じマイクで録ってください。") + (short.isEmpty ? "" : "\n(\(short))")
        case .audio: return String(localized: "音が短すぎる、または大きすぎます。")
        case .quota: return String(localized: "今日の「声を足す」の回数を使い切りました。明日またどうぞ。")
        case .relayBusy: return String(localized: "今はアクセスが集中しています。しばらくしてからどうぞ。")
        case .noKey, .keyInvalid, .projectDenied: return String(localized: "AI の設定（おまかせか、自分のキー）を確かめてください。")
        case .network(let m): return String(localized: "通信できませんでした: \(m)")
        default: return String(localized: "登録できませんでした: \(String(describing: error))")
        }
    }
}

// MARK: - 短い声を録る（24kHz・16bit・モノラルの WAV）

/// オーディオスレッドで標本を溜める入れ物。Gemini が求める 24kHz・モノラル・16bit に変換して積む
private final class PCMBag: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var converter: AVAudioConverter?
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(Voice.sampleRate), channels: 1, interleaved: true)!

    func reset() { lock.lock(); samples = []; converter = nil; lock.unlock() }

    /// 1 バッファぶんを積む。返り値はピーク（0〜1・画面の音量バー用）
    func handle(_ buffer: AVAudioPCMBuffer) -> Float {
        lock.lock(); defer { lock.unlock() }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: Self.format) }
        guard let conv = converter else { return 0 }
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: cap) else { return 0 }
        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        if err == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] {
            samples.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
        }
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        var m: Float = 0
        for i in 0..<Int(buffer.frameLength) { m = max(m, abs(ch[i])) }
        return min(1, m * 3)
    }

    var seconds: Double { lock.lock(); defer { lock.unlock() }; return Double(samples.count) / Self.format.sampleRate }

    func wav() -> Data {
        lock.lock(); defer { lock.unlock() }
        return Voice.wav(pcm: samples.withUnsafeBufferPointer { Data(buffer: $0) }, sampleRate: Voice.sampleRate)
    }
}

/// 声を足すときの短い録音（話し声・同意の文）。本番の Recorder より単純で、WAV をそのまま返す
@MainActor
final class ClipRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var seconds = 0
    @Published private(set) var level: Float = 0
    @Published var error: String?

    private let engine = AVAudioEngine()
    private let bag = PCMBag()
    private var timer: Timer?
    private var started: Date?
    private var maxSeconds = Voice.sampleMaxSeconds
    private var onLimit: (() -> Void)?

    enum Failure: Error { case micDenied, engine(String) }

    /// 録り始める。maxSeconds に届いたら自動で止めて onLimit を呼ぶ
    func start(maxSeconds: Int, onLimit: @escaping () -> Void) async throws {
        guard !recording else { return }
        guard await Platform.requestMicrophone() else { throw Failure.micDenied }
        try Platform.activateAudioSession()
        Speaker.shared.stop()
        bag.reset()
        self.maxSeconds = maxSeconds
        self.onLimit = onLimit
        seconds = 0; level = 0; error = nil
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw Failure.engine(String(localized: "マイクの形式が取れませんでした")) }
        let bag = self.bag
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buffer, _ in
            let lv = bag.handle(buffer)
            Task { @MainActor in self?.level = lv }
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw Failure.engine(error.localizedDescription) }
        recording = true
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.started else { return }
                self.seconds = Int(Date().timeIntervalSince(s))
                if self.seconds >= self.maxSeconds { self.onLimit?() }
            }
        }
    }

    /// 止めて WAV を返す（24kHz・16bit・モノラル）
    func stop() -> Data? {
        guard recording else { return nil }
        recording = false
        timer?.invalidate(); timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Platform.deactivateAudioSession()
        level = 0
        onLimit = nil
        return bag.wav()
    }
}

/// 音声ファイル（m4a・mp3・wav 等）を読んで 24kHz・16bit・モノラルの WAV にする。maxSeconds を超えた分は切る
enum WavImport {
    enum Failure: Error { case unreadable }

    static func load(_ url: URL, maxSeconds: Int) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url)
        let src = file.processingFormat
        let frames = min(file.length, AVAudioFramePosition(Double(maxSeconds) * src.sampleRate))
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(frames)) else { throw Failure.unreadable }
        try file.read(into: inBuf, frameCount: AVAudioFrameCount(frames))
        let dst = PCMBag.format
        guard let conv = AVAudioConverter(from: src, to: dst),
              let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: AVAudioFrameCount(Double(frames) * dst.sampleRate / src.sampleRate) + 32) else { throw Failure.unreadable }
        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData; return inBuf
        }
        guard err == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { throw Failure.unreadable }
        let pcm = Data(buffer: UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
        return Voice.wav(pcm: pcm, sampleRate: Voice.sampleRate)
    }

    /// WAV の長さ（秒）
    static func seconds(_ wav: Data) -> Int { Voice.pcm(wav).count / Voice.sampleRate }
}
