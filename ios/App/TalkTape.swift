import Foundation
import SwiftUI

/// 「三人で話す」の会話そのものの音声を、会話のあいだ、ためておく（設定「会話の音声を残す」がオンのときだけ作る）。
/// 学習者の各ターンの録音と、実際に鳴った AI の声を、話した順に一時ファイルへ書き足す（Core の TapeWriter）。
/// 「終わる」のあと、締めの声が鳴り終わるのを待ってから 1 本の m4a にする（AppModel.finishTape）
@MainActor
final class TalkTape {
    private let writer: TapeWriter
    /// まだ鳴っている最中の声の数（締めの声が鳴り終わる前に m4a を作り始めないために数える）
    private var open = 0

    init?() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hitorigoto-talktape-\(UUID().uuidString).pcm")
        guard let w = TapeWriter(url: url) else { return nil }
        writer = w
    }

    var seconds: Double { writer.seconds }

    /// 学習者の 1 ターン（Recorder の劣化なしの写し）。返事が取れたターンだけ足す（送り直した分を二重に入れない）
    func appendMine(wav: Data?) {
        guard let wav else { return }
        writer.appendMine(Voice.pcm(wav))
    }

    /// これから鳴らす声 1 つぶんの受け口。Speaker が「実際に鳴った分」を 1 回だけ渡してくる。
    /// 鳴らせなかったときは、呼び出し側が空で呼んで数を戻す
    func expect() -> Speaker.Spoken {
        open += 1
        var done = false
        return { [weak self] pcm, ranges in
            guard let self, !done else { return }
            done = true
            self.open -= 1
            self.writer.appendSpoken(pcm, ranges: ranges)
        }
    }

    /// いくつかの声を順に鳴らすあいだ、まとめて「まだ途中」にしておく（声と声の継ぎ目で 0 に見えないように）
    func hold() { open += 1 }
    func release() { open -= 1 }

    /// 鳴っている声が全部終わる（か止められる）まで待つ。念のため上限つき
    func settled(limit: TimeInterval = 180) async {
        let until = Date().addingTimeInterval(limit)
        while open > 0, Date() < until { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    /// 書き終えて、ためた PCM のファイルを返す
    func close() -> URL { writer.close(); return writer.url }
    func discard() { writer.discard() }
}

/// 会話の音声（m4a）の置き場所。復習の音声と同じフォルダに `talk_<記録の id>.m4a` で置く。
/// 名前は記録の id から決まるので、記録には何も持たせない（同期の混ぜ合わせで名前が落ちる心配が無い・復習の音声の前例）。
/// iCloud の同期にもバックアップにも乗せない
enum TapeAudio {
    static func url(for session: Session) -> URL? {
        guard session.talk != nil, let d = RecapAudio.dir else { return nil }
        let u = d.appendingPathComponent(Tape.fileName(for: session.id))
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// いま端末に残っている会話の音声
    static func all() -> [URL] {
        guard let d = RecapAudio.dir, let items = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return items.filter { $0.lastPathComponent.hasPrefix("talk_") && $0.pathExtension == "m4a" }
    }

    static func bytes(_ urls: [URL]) -> Int {
        urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// 端末のバックアップ（iCloud バックアップなど）に入れない。「端末の中だけに残る」を言葉どおりにする
    static func excludeFromBackup(_ url: URL) {
        var u = url
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    /// 途中で落ちたときなどに残った一時ファイルを片づける（1 日より古いものだけ）
    static func sweepTemporary() {
        let tmp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let old = Date().addingTimeInterval(-86400)
        for u in items where u.lastPathComponent.hasPrefix("hitorigoto-talktape-") || u.lastPathComponent.hasPrefix("hitorigoto-tape-") {
            if let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m < old {
                try? FileManager.default.removeItem(at: u)
            }
        }
    }
}

/// 履歴と「今日の会話」に出す、会話の音声の行（まとめている最中・再生・共有・消す）。復習の音声の行と同じ並び
struct TapeRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var speaker = Speaker.shared
    let session: Session
    @State private var confirmDelete = false

    var body: some View {
        if model.tapeMaking.contains(session.id) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("会話の音声をまとめています…").font(.caption).foregroundStyle(Theme.muted)
            }
        } else if let url = TapeAudio.url(for: session) {
            let playing = speaker.playingFile == url
            HStack(spacing: 8) {
                Button {
                    if playing { speaker.stop() } else { speaker.playFile(url) }
                } label: {
                    Label(playing ? String(localized: "止める") : String(localized: "会話の音声を聞く"), systemImage: playing ? "stop.fill" : "waveform")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered).controlSize(.small).tint(playing ? Theme.warn : Theme.accent)
                ShareLink(item: url) {
                    Label(String(localized: "共有"), systemImage: "square.and.arrow.up").font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small).tint(Theme.muted)
                .help("AirDrop・ファイル・ボイスメモなどへ")
                Button { confirmDelete = true } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small).tint(Theme.muted)
                .help("この会話の音声を消します")
                .accessibilityLabel(Text("この会話の音声を消す"))
                .confirmationDialog("この会話の音声を消しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("消す", role: .destructive) { model.deleteTape(for: session.id) }
                    Button("やめる", role: .cancel) {}
                } message: {
                    Text("音声だけが消えます。会話の文字の記録は残ります。")
                }
                Spacer(minLength: 0)
            }
        }
    }
}
