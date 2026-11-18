import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// 「三人で話す」の会話そのものの音声（学習者の声＋相手役＋トラさん）を、話した順に 1 本にためる。
///
/// 形はどこでも 24kHz・16bit・モノラルの PCM（Gemini の TTS と同じ）。会話中は頭なしの PCM を一時ファイルに書き足し、
/// 「終わる」で AAC の m4a に直す。音声は端末の中だけに置き、iCloud の同期には乗せない
public enum Tape {
    public static let sampleRate = Voice.sampleRate
    /// m4a のビットレート。10 分の会話で約 4.8MB
    public static let bitRate = 64000
    /// 発言と発言の間に入れる無音（秒）
    public static let gap = 0.35
    /// 途中で止められた声（被り・飛ばす）のあとの無音。すぐ次の人が話し出したように聞こえる長さ
    public static let gapAfterCut = 0.12

    /// 記録に添える音声ファイルの名前（記録の id から決まる。記録そのものには名前を持たせない）
    public static func fileName(for sessionId: String) -> String {
        "talk_" + sessionId.replacingOccurrences(of: ":", with: "-") + ".m4a"
    }

    /// その長さの会話が m4a で何 MB になるか（設定画面の目安用）
    public static func megabytes(seconds: Double) -> Double { seconds * Double(bitRate) / 8 / 1_000_000 }

    /// 鳴らした声のうち、**実際に鳴った区間だけ**を取り出す。
    /// 途中で止めた切り口は 30ms で小さくし（ぷつっと鳴らないように）、途中から始めた頭は 10ms で立ち上げる。
    /// cut は「最後まで鳴らずに止められた」か（次の無音を短くするのに使う）
    public static func played(_ pcm: [Int16], ranges: [(from: Double, to: Double)]) -> (pcm: [Int16], cut: Bool) {
        let rate = Double(sampleRate)
        var out: [Int16] = []
        var lastEnd = 0
        for r in ranges {
            let a = max(0, min(pcm.count, Int(r.from * rate))), b = max(0, min(pcm.count, Int(r.to * rate)))
            guard b > a else { continue }
            var piece = Array(pcm[a..<b])
            if a > 0 {
                let n = min(piece.count, Int(0.01 * rate))
                for i in 0..<n { piece[i] = Int16(Double(piece[i]) * Double(i) / Double(n)) }
            }
            if b < pcm.count {
                let n = min(piece.count, Int(0.03 * rate))
                for i in 0..<n { piece[piece.count - 1 - i] = Int16(Double(piece[piece.count - 1 - i]) * Double(i) / Double(n)) }
            }
            out += piece
            lastEnd = b
        }
        return (out, lastEnd < pcm.count - Int(0.05 * rate))
    }

    /// 学習者の録音の、頭と尻の無音を落とす（マイクを押してから話し出すまで・話し終えてから止めるまで）。
    /// 音がある所の前後 pad 秒は残す。全部が静かなら何もしない（小さな声を消さないため）
    public static func trimSilence(_ pcm: [Int16], threshold: Int16 = 400, pad: Double = 0.25) -> [Int16] {
        guard let first = pcm.firstIndex(where: { abs(Int32($0)) > Int32(threshold) }),
              let last = pcm.lastIndex(where: { abs(Int32($0)) > Int32(threshold) }) else { return pcm }
        let p = Int(pad * Double(sampleRate))
        return Array(pcm[max(0, first - p)...min(pcm.count - 1, last + p)])
    }

    /// 学習者の声が小さいとき、AI の声と並べて聞ける大きさまで上げる（最大 maxGain 倍・下げはしない）
    public static func level(_ pcm: [Int16], target: Double = 0.6, maxGain: Double = 4) -> [Int16] {
        let peak = pcm.reduce(Int32(0)) { max($0, abs(Int32($1))) }
        guard peak > 0 else { return pcm }
        let gain = min(maxGain, target * 32767 / Double(peak))
        guard gain > 1.05 else { return pcm }
        return pcm.map { Int16(clamping: Int(Double($0) * gain)) }
    }
}

/// 会話の音声を、話した順に一時ファイル（頭なしの PCM）へ書き足す
public final class TapeWriter {
    /// 誰がいつ話したか（秒）。who は "me"（学習者）か "ai"（相手役・トラさん）
    public struct Mark: Equatable, Codable, Sendable {
        public var who: String
        public var start: Double
        public var seconds: Double
    }

    public let url: URL
    public private(set) var marks: [Mark] = []
    private var handle: FileHandle?
    private var frames = 0
    private var lastCut = false

    public init?(url: URL) {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
    }

    /// ここまでにためた長さ（秒）
    public var seconds: Double { Double(frames) / Double(Tape.sampleRate) }

    /// 学習者の 1 ターン（録音そのまま）。頭と尻の無音を落とし、小さければ音量を上げて足す
    public func appendMine(_ pcm: [Int16]) {
        append(who: "me", pcm: Tape.level(Tape.trimSilence(pcm)), cut: false)
    }

    /// AI の声。鳴らした PCM と、実際に鳴った区間（秒）を渡す
    public func appendSpoken(_ pcm: [Int16], ranges: [(from: Double, to: Double)]) {
        let p = Tape.played(pcm, ranges: ranges)
        append(who: "ai", pcm: p.pcm, cut: p.cut)
    }

    /// 0.05 秒に満たない切れ端は足さない
    public func append(who: String, pcm: [Int16], cut: Bool) {
        guard let handle, pcm.count >= Tape.sampleRate / 20 else { return }
        var all: [Int16] = []
        if frames > 0 { all = [Int16](repeating: 0, count: Int((lastCut ? Tape.gapAfterCut : Tape.gap) * Double(Tape.sampleRate))) }
        let start = Double(frames + all.count) / Double(Tape.sampleRate)
        all += pcm
        handle.write(all.withUnsafeBufferPointer { Data(buffer: $0) })
        frames += all.count
        marks.append(Mark(who: who, start: start, seconds: Double(pcm.count) / Double(Tape.sampleRate)))
        lastCut = cut
    }

    /// 書き終える（このあと Tape.writeM4A に url を渡す）
    public func close() {
        try? handle?.close()
        handle = nil
    }

    /// 一時ファイルごと捨てる
    public func discard() {
        close()
        try? FileManager.default.removeItem(at: url)
    }
}

#if canImport(AVFoundation)
extension Tape {
    /// 頭なしの PCM（24kHz・16bit・モノラル）のファイルを AAC の m4a に書く。少しずつ読むので長い会話でもメモリを食わない
    public static func writeM4A(pcmFile: URL, to url: URL) throws {
        let input = try FileHandle(forReadingFrom: pcmFile)
        defer { try? input.close() }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        try? FileManager.default.removeItem(at: url)
        let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 16384
        guard let buf = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: AVAudioFrameCount(chunk)) else { throw CocoaError(.fileWriteUnknown) }
        while let d = try input.read(upToCount: chunk * 2), d.count >= 2 {
            let n = d.count / 2
            buf.frameLength = AVAudioFrameCount(n)
            let out = buf.floatChannelData![0]
            d.withUnsafeBytes { raw in
                for i in 0..<n { out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768 }
            }
            try output.write(from: buf)
        }
    }

    /// 音声ファイル（m4a・wav・aiff など）を 24kHz・モノラルの PCM に読む（できた音声の確かめと hg-probe 用）
    public static func readPCM(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url)
        let src = file.processingFormat
        guard file.length > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: inBuf)
        guard let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false) else { return [] }
        var mono = inBuf
        if src != dst {
            guard let conv = AVAudioConverter(from: src, to: dst),
                  let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * dst.sampleRate / src.sampleRate) + 4096) else { return [] }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true; status.pointee = .haveData; return inBuf
            }
            if let err { throw err }
            mono = out
        }
        guard let ch = mono.floatChannelData?[0] else { return [] }
        return (0..<Int(mono.frameLength)).map { Int16(clamping: Int((ch[$0] * 32767).rounded())) }
    }
}
#endif
