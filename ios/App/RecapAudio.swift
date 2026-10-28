import AVFoundation
import Foundation
import SwiftUI

/// 復習の音声（m4a）の置き場所と、WAV → m4a の変換。
/// ファイルは記録のフォルダ（Application Support/Hitorigoto/recaps/）に置く。iCloud の同期には乗せない（大きいので）
enum RecapAudio {
    static var dir: URL? {
        guard let base = try? SnapshotStore.defaultURL().deletingLastPathComponent() else { return nil }
        let d = base.appendingPathComponent("recaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// その記録の音声。ファイルが無ければ nil（別の端末で作った記録など）
    static func url(for session: Session) -> URL? {
        guard let name = session.recap, let d = dir else { return nil }
        let u = d.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// WAV（24kHz・16bit・モノラル）を AAC の m4a に書く。1 本 3 分で 8MB ほどが 1.5MB くらいになる
    static func writeM4A(wav: Data, to url: URL) throws {
        let tmp = url.deletingPathExtension().appendingPathExtension("wav")
        try wav.write(to: tmp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let input = try AVAudioFile(forReading: tmp)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: input.processingFormat.sampleRate,
            AVNumberOfChannelsKey: input.processingFormat.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        try? FileManager.default.removeItem(at: url)
        let output = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(16384)
        guard let buf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: frames) else { throw CocoaError(.fileWriteUnknown) }
        while true {
            try input.read(into: buf, frameCount: frames)
            if buf.frameLength == 0 { break }
            try output.write(from: buf)
        }
    }
}

/// 履歴と「今日の会話」の下に出す、復習の音声の行（作っている最中・できた・再生・共有）
struct RecapRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var speaker = Speaker.shared
    let session: Session

    var body: some View {
        if model.recapMaking.contains(session.id) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("復習の音声を作っています（30 秒ほど）…").font(.caption).foregroundStyle(Theme.muted)
            }
        } else if let url = RecapAudio.url(for: session) {
            let playing = speaker.playingFile == url
            HStack(spacing: 8) {
                Button {
                    if playing { speaker.stop() } else { speaker.playFile(url) }
                } label: {
                    Label(playing ? String(localized: "止める") : String(localized: "復習の音声を聞く"), systemImage: playing ? "stop.fill" : "headphones")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered).controlSize(.small).tint(playing ? Theme.warn : Theme.accent)
                ShareLink(item: url) {
                    Label(String(localized: "共有"), systemImage: "square.and.arrow.up").font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small).tint(Theme.muted)
                .help("AirDrop・ファイル・ボイスメモなどへ")
                Spacer(minLength: 0)
            }
        } else if let why = model.recapFailed[session.id] {
            HStack(spacing: 8) {
                Text(why).font(.caption).foregroundStyle(Theme.muted)
                Button(String(localized: "もう一度")) { Task { await model.makeRecap(for: session.id) } }
                    .buttonStyle(.bordered).controlSize(.mini).tint(Theme.accent)
            }
        }
    }
}
