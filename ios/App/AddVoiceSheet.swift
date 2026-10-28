import SwiftUI
import UniformTypeIdentifiers

/// 「声を足す」: 自分や友人の声を録って（またはファイルから）、相手役として登録するシート。
/// 1. 名前 → 2. 10〜30 秒の話し声 → 3. 同意の文を読む → 登録。登録できたら相手役に選んで試聴する
struct AddVoiceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var talk: TalkModel
    @ObservedObject private var voices = CustomVoices.shared

    @State private var name = ""
    @State private var female = false
    @State private var blurb = ""
    @State private var source: Data?
    @State private var consent: Data?
    @State private var consentLocale = TargetLanguage.explanation == .ja ? "ja-JP" : "en-US"
    @State private var busy = false
    @State private var error: String?
    @StateObject private var rec1 = ClipRecorder()
    @StateObject private var rec2 = ClipRecorder()

    private var statement: String { Voice.consentStatement(consentLocale) }
    private var canRegister: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && source != nil && consent != nil && !rec1.recording && !rec2.recording && !busy
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Card {
                        Text("自分や友人の声で、相手役に話してもらえます。声は端末の中に置き、Google 側には残しません（話すための鍵だけを作り、7 日ごとに作り直します）。")
                            .font(.callout).foregroundStyle(Theme.text)
                        Text("いまはまだ声の似せ方が粗いことがあります。静かな部屋で、いつもの調子で録ると近づきます。")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    Card(title: String(localized: "だれの声？")) {
                        TextField(String(localized: "名前（例: 自分、ヒロ）"), text: $name).textFieldStyle(.roundedBorder)
                        HStack(spacing: 8) {
                            Picker("", selection: $female) {
                                Text("男性").tag(false)
                                Text("女性").tag(true)
                            }
                            .pickerStyle(.segmented).frame(maxWidth: 180)
                            TextField(String(localized: "一言（例: 大学の友人）"), text: $blurb).textFieldStyle(.roundedBorder)
                        }
                    }
                    Card(title: String(localized: "1. ふだんの話し声（\(Voice.sampleMinSeconds)〜\(Voice.sampleMaxSeconds) 秒）")) {
                        Text("内容は何でも。今日あったことなどを、いつもの調子で話してください。")
                            .font(.caption).foregroundStyle(Theme.muted)
                        ClipRow(clip: $source, recorder: rec1, otherRecording: rec2.recording,
                                minSeconds: Voice.sampleMinSeconds, maxSeconds: Voice.sampleMaxSeconds)
                    }
                    Card(title: String(localized: "2. 同意の文を読む")) {
                        Text(statement)
                            .font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).background(Theme.accentBg, in: RoundedRectangle(cornerRadius: 10))
                            .textSelection(.enabled)
                        Picker("", selection: $consentLocale) {
                            Text("日本語で読む").tag("ja-JP")
                            Text("English").tag("en-US")
                        }
                        .pickerStyle(.segmented).frame(maxWidth: 260)
                        Text("Google の声の複製には、声の本人がこの文をそのまま読んだ声が要ります。一字も変えずに、はっきり読んでください。友人の声を足すときは、その人に読んでもらってください。")
                            .font(.caption).foregroundStyle(Theme.muted)
                        ClipRow(clip: $consent, recorder: rec2, otherRecording: rec1.recording,
                                minSeconds: 3, maxSeconds: Voice.consentMaxSeconds)
                    }
                    if let error { Card { Text(error).font(.callout).foregroundStyle(Theme.bad) } }
                    Button {
                        Task { await register() }
                    } label: {
                        HStack {
                            if busy { ProgressView().controlSize(.small) }
                            Text(busy ? String(localized: "声を作っています…") : String(localized: "この声を登録する"))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(!canRegister)
                    if let q = model.cloneQuota {
                        Note(text: String(localized: "今日はあと \(q.remaining) 回登録できます（\(q.limit) 回まで）。登録には 10 秒ほどかかります。"))
                    }
                }
                .padding(12)
            }
            .background(Theme.bg)
            .navigationTitle("声を足す").compactNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { close() }.disabled(busy)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 640, idealHeight: 760)
        #endif
        .interactiveDismissDisabled(busy)
        .task { await model.refreshCloneQuota() }
        .onDisappear { _ = rec1.stop(); _ = rec2.stop() }
    }

    private func close() {
        _ = rec1.stop(); _ = rec2.stop()
        Speaker.shared.stop()
        dismiss()
    }

    private func register() async {
        guard let source, let consent, let client = model.talkClient else {
            error = String(localized: "AI の設定（おまかせか、自分のキー）を確かめてください。")
            return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            let key = try await client.createVoice(source: source, consent: consent)
            let v = voices.add(name: name.trimmingCharacters(in: .whitespaces), female: female, blurb: blurb.trimmingCharacters(in: .whitespaces),
                               source: source, consent: consent, key: key)
            model.partnerId = v.partner.id
            await model.refreshCloneQuota()
            dismiss()
            // 登録できた声を、さっそく一言しゃべらせる
            await talk.preview(partner: v.partner)
        } catch {
            self.error = CustomVoices.describe(error)
        }
    }
}

/// 1 本の声を録る行: 録音する／ファイルから → 録音中（秒・音量・止める）→ 録れた（秒・聞く・録り直す）
struct ClipRow: View {
    @Binding var clip: Data?
    @ObservedObject var recorder: ClipRecorder
    /// もう一方の行が録音中（マイクは一度に 1 本）
    let otherRecording: Bool
    let minSeconds: Int
    let maxSeconds: Int
    @State private var importing = false
    @State private var playing = false
    @ObservedObject private var speaker = Speaker.shared

    private var seconds: Int { clip.map { WavImport.seconds($0) } ?? 0 }
    private var tooShort: Bool { clip != nil && seconds < minSeconds }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if recorder.recording {
                HStack(spacing: 10) {
                    Circle().fill(Theme.rec).frame(width: 10, height: 10)
                    Text(String(format: "%d:%02d", recorder.seconds / 60, recorder.seconds % 60))
                        .font(.title3.monospacedDigit().weight(.bold)).foregroundStyle(Theme.text)
                    LevelBar(level: recorder.level)
                    Button {
                        finish()
                    } label: { Label("止める", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).tint(Theme.rec)
                }
                Text(String(localized: "\(maxSeconds) 秒で自動的に止まります"))
                    .font(.caption2).foregroundStyle(Theme.faint)
            } else if clip != nil {
                HStack(spacing: 10) {
                    Image(systemName: tooShort ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(tooShort ? Theme.warn : Theme.good)
                    Text(String(localized: "\(seconds) 秒"))
                        .font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                    Button {
                        if speaker.isPlaying, playing { Speaker.shared.stop(); playing = false }
                        else if let clip { playing = Speaker.shared.play(clip, epoch: Speaker.shared.begin()) }
                    } label: { Label("聞く", systemImage: "play.fill") }
                    .buttonStyle(.bordered)
                    Button {
                        clip = nil
                        Task { await begin() }
                    } label: { Label("録り直す", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.bordered)
                    .disabled(otherRecording)
                }
                if tooShort {
                    Text(String(localized: "短すぎます。\(minSeconds) 秒以上話してください。")).font(.caption).foregroundStyle(Theme.warn)
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        Task { await begin() }
                    } label: { Label("録音する", systemImage: "mic.fill") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(otherRecording)
                    Button {
                        importing = true
                    } label: { Label("ファイルから", systemImage: "folder") }
                    .buttonStyle(.bordered)
                    .disabled(otherRecording)
                }
            }
            if let e = recorder.error { Text(e).font(.caption).foregroundStyle(Theme.bad) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .mpeg4Audio, .wav, .mp3]) { r in
            guard case .success(let url) = r else { return }
            do { clip = try WavImport.load(url, maxSeconds: maxSeconds) }
            catch { recorder.error = String(localized: "この音声ファイルは読めませんでした。") }
        }
    }

    private func begin() async {
        Speaker.shared.stop()
        do {
            try await recorder.start(maxSeconds: maxSeconds) { finish() }
        } catch ClipRecorder.Failure.micDenied {
            recorder.error = String(localized: "マイクの使用が許可されていません。設定で許可してください。")
        } catch {
            recorder.error = String(localized: "録音を始められませんでした: \(error.localizedDescription)")
        }
    }

    private func finish() {
        guard let wav = recorder.stop() else { return }
        clip = wav
    }
}
