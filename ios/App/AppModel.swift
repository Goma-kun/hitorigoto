import Foundation
import SwiftUI

/// 画面が見ている状態のぜんぶ。記録を持ち、変わるたびに保存する。
/// 純ロジックは HitorigotoCore（拡張機能と同じ答えを返す）。ここは画面と保存とマイクの段取りだけ
@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var snapshot: Snapshot
    @Published private(set) var hasKey = KeychainStore.hasKey

    /// 話すタブの状態
    enum Phase: Equatable {
        case idle
        case recording
        case reviewing          // Gemini に送って待っている
        case result             // latest を表示中
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latest: Feedback?
    @Published private(set) var latestJudged: [Judged] = []
    /// 直近の結果を履歴と同じ形で持つ（まとめてコピー用）
    @Published private(set) var latestSession: Session?
    @Published var errorMessage: String?
    /// 送れていない録音。**結果が出るまで消さない**（通信に失敗しても話した内容を失わせない）。
    /// ディスクにも置くので、アプリを閉じても残る
    @Published private(set) var pending: PendingRecording?

    // 設定（UserDefaults）
    @Published var dailyTotal: Int { didSet { UserDefaults.standard.set(dailyTotal, forKey: "dailyTotal") } }
    @Published var dailyNew: Int { didSet { UserDefaults.standard.set(dailyNew, forKey: "dailyNew") } }
    @Published var captionsOn: Bool { didSet { UserDefaults.standard.set(captionsOn, forKey: "captionsOn") } }
    @Published var language: String { didSet { UserDefaults.standard.set(language, forKey: "language") } }
    /// 録音に使うマイク（Mac）。空なら Mac の既定に合わせる
    @Published var micUID: String { didSet { UserDefaults.standard.set(micUID, forKey: "micUID") } }

    let recorder = Recorder()
    private let store: SnapshotStore?

    init(store: SnapshotStore? = try? SnapshotStore(url: SnapshotStore.defaultURL())) {
        self.store = store
        self.snapshot = (try? store?.load()).flatMap { $0 } ?? Snapshot()
        self.pending = PendingRecording.load()
        let d = UserDefaults.standard
        dailyTotal = d.object(forKey: "dailyTotal") as? Int ?? PhraseLogic.defaultTotal
        dailyNew = d.object(forKey: "dailyNew") as? Int ?? PhraseLogic.defaultNew
        captionsOn = d.object(forKey: "captionsOn") as? Bool ?? true
        language = d.string(forKey: "language") ?? "en-US"
        micUID = d.string(forKey: "micUID") ?? ""
    }

    private func save() { try? store?.save(snapshot) }

    var today: String { Logic.todayStamp() }

    // MARK: - 今日の表現

    /// 日をまたいでいたら選び直し、決めてある分は保つ。見送りや削除で空いた枠は埋める
    func todayCards() -> [PhraseCard] {
        let t = today
        let fixed = snapshot.today?.date == t ? (snapshot.today?.ids ?? []) : []
        let cards = PhraseLogic.pickToday(snapshot.phrases, today: t, total: dailyTotal, maxNew: dailyNew, fixedIds: fixed)
        let ids = cards.map { $0.id }
        if snapshot.today?.date != t || snapshot.today?.ids != ids {
            let results = snapshot.today?.date == t ? (snapshot.today?.results ?? [:]) : [:]
            snapshot.today = Today(date: t, ids: ids, results: results)
            save()
        }
        return cards
    }

    func todayResult(_ id: String) -> TodayResult? {
        guard snapshot.today?.date == today else { return nil }
        return snapshot.today?.results[id]
    }

    private func applyPhraseResult(_ id: String, _ result: String, asSaid: String) {
        guard let i = snapshot.phrases.firstIndex(where: { $0.id == id }) else { return }
        snapshot.phrases[i] = PhraseLogic.setSpeechResult(snapshot.phrases[i], today: today, result: result, asSaid: asSaid)
    }

    /// 判定結果を今日の記録と表現集の両方に入れる。同じ日に 2 回話したときは良い方を残す。手で直したものは上書きしない
    private func recordTodayResults(_ judged: [Judged]) {
        let t = today
        if snapshot.today?.date != t { snapshot.today = Today(date: t) }
        let rank = ["hit": 3, "partial": 2, "miss": 1, "skip": 0]
        for j in judged {
            let cur = snapshot.today?.results[j.id]
            if cur?.judge == "manual" { continue }
            if let cur, (rank[cur.r] ?? 0) > (rank[j.result] ?? 0) { continue }
            snapshot.today?.results[j.id] = TodayResult(r: j.result, as: j.asSaid, note: j.note, judge: j.judge)
            applyPhraseResult(j.id, j.result, asSaid: j.asSaid)
        }
    }

    static let cycle = ["hit", "partial", "miss", "skip"]

    /// 結果の記号をタップして直す（◎→△→✗→−→◎）
    func cycleTodayResult(_ id: String) {
        let cur = todayResult(id)
        let next = Self.cycle[(Self.cycle.firstIndex(of: cur?.r ?? "skip")! + 1) % Self.cycle.count]
        if snapshot.today?.date != today { snapshot.today = Today(date: today) }
        snapshot.today?.results[id] = TodayResult(r: next, as: cur?.as ?? "", note: cur?.note ?? "", judge: "manual")
        applyPhraseResult(id, next, asSaid: cur?.as ?? "")
        if let k = latestJudged.firstIndex(where: { $0.id == id }) { latestJudged[k].result = next; latestJudged[k].judge = "manual" }
        // 履歴の最新セッションにも反映（見返したときに画面と食い違わないように）
        if let card = snapshot.phrases.first(where: { $0.id == id }), !snapshot.sessions.isEmpty,
           var targets = snapshot.sessions[0].targets, let k = targets.firstIndex(where: { $0.phrase == card.phrase }) {
            targets[k].r = next
            snapshot.sessions[0].targets = targets
        }
        save()
    }

    /// 見送り：今日の話に合わない表現を外す。回数に数えず、2 日あけて戻る
    func skipToday(_ id: String) {
        applyPhraseResult(id, "skip", asSaid: "")
        snapshot.today?.ids.removeAll { $0 == id }
        snapshot.today?.results.removeValue(forKey: id)
        save()
        objectWillChange.send()
    }

    // MARK: - 録音と添削

    func startRecording() async {
        errorMessage = nil
        latest = nil; latestJudged = []
        do {
            try await recorder.start(captions: captionsOn, language: language, micUID: micUID)
            phase = .recording
        } catch Recorder.Failure.micDenied {
            errorMessage = "マイクの使用が許可されていません。設定で「独り言」のマイクをオンにしてください。"
        } catch {
            errorMessage = "録音を始められませんでした: \(error.localizedDescription)"
        }
    }

    func stopAndReview() async {
        guard phase == .recording else { return }
        let result = await recorder.stop()
        guard let result else { phase = .idle; errorMessage = "録音が取れませんでした"; return }
        guard result.seconds >= 2 else { phase = .idle; errorMessage = "短すぎました。もう少し話してから止めてください"; return }
        // まず手元に残す。ここから先で何が起きても、話した内容は消えない
        let p = PendingRecording(audio: result.audio, transcript: result.transcript, seconds: result.seconds, date: Date())
        p.save()
        pending = p
        await review()
    }

    /// 手元に残っている録音を Gemini に送る。「もう一度送る」もここを通る
    func review() async {
        guard let p = pending else { return }
        guard let key = KeychainStore.apiKey else {
            phase = .idle
            errorMessage = "添削には Google Gemini の API キーが必要です。設定から登録してください。録音は残してあります。"
            return
        }
        phase = .reviewing
        errorMessage = nil
        let targetCards = todayCards()
        let extra = PhraseLogic.targetsSection(targetCards)
        let client = GeminiClient(key: key)
        do {
            let fb = try await client.reviewEnglishAudio(p.audio, mimeType: Recorder.mimeType, asrTranscript: p.transcript,
                                                         recurring: Logic.topRecurring(snapshot.recurring), extra: extra)
            var session = Session(id: ISO8601DateFormatter.withMillis.string(from: p.date), transcript: fb.transcript,
                                  correctedText: fb.correctedText, issues: fb.issues, good: fb.good, engine: "gemini")
            if !p.transcript.isEmpty, p.transcript != fb.transcript { session.asrTranscript = p.transcript }
            if !fb.pronunciation.isEmpty { session.pronunciation = fb.pronunciation }

            var judged: [Judged] = []
            if !targetCards.isEmpty {
                judged = PhraseLogic.mergeAiTargets(PhraseLogic.judge(targetCards, text: fb.transcript), cards: targetCards, aiTargets: fb.targets)
                recordTodayResults(judged)
                session.targets = judged.map { j in
                    SessionTarget(phrase: targetCards.first { $0.id == j.id }?.phrase ?? "", r: j.result, as: j.asSaid)
                }
            }
            snapshot.sessions.insert(session, at: 0)
            snapshot.sessions = Logic.foldSessions(snapshot.sessions)
            snapshot.recurring = Logic.promoteRecurring(snapshot.recurring, issues: fb.issues, today: today)
            save()
            // ここで初めて録音を手放す
            p.discard()
            pending = nil
            latest = fb
            latestJudged = judged
            latestSession = session
            phase = .result
        } catch let f as GeminiClient.Failure {
            phase = .idle
            errorMessage = Self.message(for: f, mic: recorder.inputName) + "\n録音は残してあります。「もう一度送る」でやり直せます。"
        } catch {
            phase = .idle
            errorMessage = error.localizedDescription + "\n録音は残してあります。「もう一度送る」でやり直せます。"
        }
    }

    /// 残っている録音を捨てる（本人が押したときだけ）
    func discardPending() {
        pending?.discard()
        pending = nil
        errorMessage = nil
    }

    static func message(for f: GeminiClient.Failure, mic: String = "") -> String {
        switch f {
        case .noKey: return "添削には Google Gemini の API キーが必要です。設定から登録してください。"
        case .keyInvalid: return "API キーが正しくないようです。設定で確かめてください。"
        case .projectDenied: return "この API キーのプロジェクトは Google 側で利用が許可されていません。Google AI Studio で「請求階層」を確認してください。"
        case .rateLimited: return "アクセスが集中しています。少し待ってからもう一度どうぞ。"
        case .server(let m): return "AI の応答でエラーが起きました: \(m)"
        case .network(let m): return "通信に失敗しました: \(m)"
        case .parse: return "AI の応答を読めませんでした。もう一度お試しください。"
        case .audio: return "音声が空か大きすぎます。"
        case .silent:
            // 実際に録ったマイクの名前を出す（Mac の既定とは限らない）
            let name = mic.isEmpty ? Platform.inputDeviceName : mic
            return "聞き取れる英語がありませんでした。マイクから音が入っていなかったかもしれません。"
                + (name.isEmpty ? "" : "今のマイクは「\(name)」です。") + "マイクを確かめて、もう一度どうぞ。"
        }
    }

    func clearResult() {
        latest = nil; latestJudged = []; latestSession = nil; errorMessage = nil
        if phase == .result { phase = .idle }
    }

    // MARK: - 表現集

    @discardableResult
    func addPhrase(_ phrase: String, meaning: String, kind: String, source: String = "manual", note: String = "") -> Bool {
        guard let card = PhraseLogic.makePhrase(phrase: phrase, meaning: meaning, kind: kind, source: source, today: today, note: note) else { return false }
        let r = PhraseLogic.addPhrases(snapshot.phrases, [card])
        guard r.added > 0 else { return false }
        snapshot.phrases = PhraseLogic.trim(r.list)
        save()
        return true
    }

    func addFromIssue(_ issue: Issue) -> Bool {
        addPhrase(issue.suggestion, meaning: "", kind: issue.type == "vocabulary" ? "word" : "phrase", source: "issue", note: issue.original ?? "")
    }

    func hasPhrase(_ text: String) -> Bool { PhraseLogic.findPhrase(snapshot.phrases, text) != nil }

    func addBulk(_ text: String, kind: String) -> Int {
        let items = PhraseLogic.parsePhraseLines(text).compactMap {
            PhraseLogic.makePhrase(phrase: $0.phrase, meaning: $0.meaning, kind: kind, today: today)
        }
        let r = PhraseLogic.addPhrases(snapshot.phrases, items)
        snapshot.phrases = PhraseLogic.trim(r.list)
        save()
        return r.added
    }

    func deletePhrase(_ id: String) {
        snapshot.phrases.removeAll { $0.id == id }
        snapshot.today?.ids.removeAll { $0 == id }
        snapshot.today?.results.removeValue(forKey: id)
        save()
    }

    func toggleGraduate(_ id: String) {
        guard let i = snapshot.phrases.firstIndex(where: { $0.id == id }) else { return }
        let p = snapshot.phrases[i]
        snapshot.phrases[i] = PhraseLogic.setManualStatus(p, p.status == "graduated" ? "active" : "graduated", today: today)
        save()
    }

    func recall(_ id: String, ok: Bool) {
        guard let i = snapshot.phrases.firstIndex(where: { $0.id == id }) else { return }
        snapshot.phrases[i] = PhraseLogic.setRecallResult(snapshot.phrases[i], today: today, ok: ok)
        save()
    }

    // MARK: - キーと記録の出し入れ

    func setKey(_ key: String?) {
        KeychainStore.apiKey = key
        hasKey = KeychainStore.hasKey
    }

    func testKey(_ key: String) async -> String? {
        do { try await GeminiClient(key: key).testConnection(); return nil }
        catch let f as GeminiClient.Failure { return Self.message(for: f) }
        catch { return error.localizedDescription }
    }

    func exportData() -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return (try? enc.encode(ExportFile(snapshot: snapshot))) ?? Data()
    }

    func importData(_ data: Data) throws -> Int {
        let r = try Merge.importJson(data, into: snapshot)
        snapshot = r.snapshot
        save()
        return r.addedSessions
    }
}

extension ISO8601DateFormatter {
    /// JS の `new Date().toISOString()` と同じ形（ミリ秒つき・UTC）
    static let withMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// 送れていない録音。音声とメモを Application Support に置き、送れたら消す
struct PendingRecording: Equatable {
    let audio: Data
    let transcript: String
    let seconds: Int
    let date: Date

    private static var dir: URL? { try? SnapshotStore.defaultURL().deletingLastPathComponent() }
    private static var audioURL: URL? { dir?.appendingPathComponent("pending.m4a") }
    private static var metaURL: URL? { dir?.appendingPathComponent("pending.json") }

    struct Meta: Codable { var transcript: String; var seconds: Int; var date: Date }

    func save() {
        guard let a = Self.audioURL, let m = Self.metaURL else { return }
        try? audio.write(to: a, options: .atomic)
        try? JSONEncoder().encode(Meta(transcript: transcript, seconds: seconds, date: date)).write(to: m, options: .atomic)
    }

    func discard() {
        if let a = Self.audioURL { try? FileManager.default.removeItem(at: a) }
        if let m = Self.metaURL { try? FileManager.default.removeItem(at: m) }
    }

    static func load() -> PendingRecording? {
        guard let a = audioURL, let m = metaURL,
              let audio = try? Data(contentsOf: a), !audio.isEmpty,
              let meta = try? JSONDecoder().decode(Meta.self, from: Data(contentsOf: m)) else { return nil }
        return PendingRecording(audio: audio, transcript: meta.transcript, seconds: meta.seconds, date: meta.date)
    }

    var label: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "M/d HH:mm"
        return "\(f.string(from: date)) に録音（\(seconds / 60):\(String(format: "%02d", seconds % 60))）"
    }
}
