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
    @Published var language: String { didSet {
        UserDefaults.standard.set(language, forKey: "language"); Speaker.shared.language = language
        partnerId = UserDefaults.standard.string(forKey: "talkPartner." + language) ?? ""
    } }
    /// 録音に使うマイク（Mac）。空なら Mac の既定に合わせる
    @Published var micUID: String { didSet { UserDefaults.standard.set(micUID, forKey: "micUID") } }
    /// 添削のエンジン。"cloud"＝開発者の中継サーバー経由で Gemini（キー不要・1 日の回数制限あり・既定）
    /// ／"gemini"＝自分の API キーで Gemini に直接／"apple"＝端末内 AI（試験的）
    @Published var engine: String { didSet { UserDefaults.standard.set(engine, forKey: "engine") } }
    /// 中継サーバーの今日の回数（設定画面と話す画面に出す）
    @Published var quota: GeminiClient.Quota?
    /// 「トラさんに詳しく聞く」の今日の回数（添削とは別枠）
    @Published var explainQuota: GeminiClient.Quota?
    /// 「三人で話す」の今日の回数（1 ターン 1 回・添削とは別枠）
    @Published var talkQuota: GeminiClient.Quota?
    /// 「三人で話す」の相手役（言語ごとに覚える）とトラさんの声
    @Published var partnerId: String { didSet { UserDefaults.standard.set(partnerId, forKey: "talkPartner." + language) } }
    @Published var toraVoice: String { didSet { UserDefaults.standard.set(toraVoice, forKey: "talkToraVoice") } }
    /// ネイティブ役の聞き取りやすさ（はっきり／ふつう）
    @Published var clarity: Voice.Clarity { didSet { UserDefaults.standard.set(clarity.rawValue, forKey: "talkClarity") } }
    var partner: Partner { Partners.find(partnerId, language: targetLanguage) }
    /// 「三人で話す」で Sam とトラさんを AI の自然な声で話させる（既定で入）。切ると端末の声（通信なし）
    @Published var naturalVoice: Bool { didSet { UserDefaults.standard.set(naturalVoice, forKey: "talkNaturalVoice") } }
    /// iCloud で同じ Apple アカウントの iPhone・Mac と記録を揃える（既定で入）
    @Published var syncEnabled: Bool {
        didSet { UserDefaults.standard.set(syncEnabled, forKey: "iCloudSync"); updateSync() }
    }
    @Published var syncStatus: SyncStatus = .off
    private var sync: CloudSync?

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
        language = d.string(forKey: "language") ?? TargetLanguage.default.rawValue
        micUID = d.string(forKey: "micUID") ?? ""
        let saved = d.string(forKey: "engine") ?? (KeychainStore.hasKey ? "gemini" : "cloud")
        engine = saved == "apple" ? "cloud" : saved   // 端末内 AI は選択肢から外した（2026-10-09）
        syncEnabled = d.object(forKey: "iCloudSync") as? Bool ?? true
        naturalVoice = d.object(forKey: "talkNaturalVoice") as? Bool ?? true
        partnerId = d.string(forKey: "talkPartner." + (d.string(forKey: "language") ?? TargetLanguage.default.rawValue)) ?? ""
        toraVoice = d.string(forKey: "talkToraVoice") ?? Voice.defaultToraVoice
        clarity = Voice.Clarity(rawValue: d.string(forKey: "talkClarity") ?? "") ?? .natural
        Speaker.shared.language = language
        updateSync()
    }

    // MARK: - iCloud 同期

    private func updateSync() {
        if syncEnabled && !DevHooks.noSync {
            if sync == nil { sync = CloudSync(model: self) }
        } else if sync != nil || syncStatus != .off {
            sync = nil
            CloudSync.forget()
            syncStatus = .off
        }
    }

    /// アプリが前に出たとき
    func syncNow() { sync?.syncNow() }

    /// 相手の端末から届いた分を混ぜた記録に差し替える（CloudSync から呼ぶ）
    func applySynced(_ s: Snapshot) {
        if s != snapshot {
            snapshot = s
            if let id = latestSession?.id { latestSession = snapshot.sessions.first { $0.id == id } ?? latestSession }
            try? store?.save(snapshot)
        }
        sync?.localChanged(snapshot)
    }

    /// 話す言語（設定）。知らない値が入っていたら既定に
    var targetLanguage: TargetLanguage { TargetLanguage(rawValue: language) ?? .default }

    var usesOnDevice: Bool { engine == "apple" }
    var usesRelay: Bool { engine != "apple" && engine != "gemini" }
    /// 今の設定で添削できるか。できないときは理由
    var reviewBlocker: String? {
        if usesOnDevice {
            if case .unavailable(let why) = AppleReviewer.status { return why }
            return nil
        }
        if usesRelay {
            if let q = quota, q.remaining == 0 { return String(localized: "今日の無料の添削（\(q.limit) 回）を使い切りました。日付が変わると戻ります。自分の Gemini キーを「設定」で登録すると回数の制限なく使えます。") }
            return nil
        }
        return hasKey ? nil : String(localized: "添削には Google Gemini の API キーが必要です。「設定」で登録するか、「おまかせ（キー不要）」に切り替えてください。")
    }

    /// 中継サーバーの残り回数を取り直す
    func refreshQuota() async {
        guard usesRelay else { quota = nil; return }
        quota = await GeminiClient(transport: Relay.transport).quota()
    }

    private func save() {
        try? store?.save(snapshot)
        sync?.localChanged(snapshot)
    }

    // MARK: - トラさんに詳しく聞く

    /// その直しについて、これまでのやり取り（無ければ空）
    func explainTurns(sessionId: String, topic: ExplainTopic) -> [ExplainTurn] {
        snapshot.sessions.first { $0.id == sessionId }?.explains?.first { $0.key == topic.key }?.turns ?? []
    }

    func refreshExplainQuota() async {
        guard usesRelay else { explainQuota = nil; return }
        explainQuota = await GeminiClient(transport: Relay.transport).explainQuota()
    }

    /// 1 回聞く。答えはセッションに残す（履歴から開き直しても回数を使わない）。失敗したら利用者向けの文を返す
    func askExplain(sessionId: String, topic: ExplainTopic, question: String, preset: Explain.Preset? = nil) async -> String? {
        let client: GeminiClient
        if usesRelay {
            client = GeminiClient(transport: Relay.transport)
        } else if let key = KeychainStore.apiKey {
            client = GeminiClient(key: key)
        } else {
            return String(localized: "詳しく聞くには、「設定」で「おまかせ（キー不要）」を選ぶか、Gemini の API キーを登録してください。")
        }
        guard let idx = snapshot.sessions.firstIndex(where: { $0.id == sessionId }) else { return String(localized: "この記録が見つかりませんでした。") }
        let session = snapshot.sessions[idx]
        let history = explainTurns(sessionId: sessionId, topic: topic)
        do {
            let turn = try await client.explain(topic: topic, context: session.correctedText ?? session.transcript ?? "",
                                                history: history, question: question, request: preset?.request,
                                                system: Explain.system(language: targetLanguage))
            // 待っているあいだに記録が動いていることがあるので、id で引き直してから書く
            guard let i = snapshot.sessions.firstIndex(where: { $0.id == sessionId }) else { return nil }
            var threads = snapshot.sessions[i].explains ?? []
            if let k = threads.firstIndex(where: { $0.key == topic.key }) { threads[k].turns.append(turn) }
            else { threads.append(ExplainThread(key: topic.key, turns: [turn])) }
            snapshot.sessions[i].explains = threads
            if latestSession?.id == sessionId { latestSession = snapshot.sessions[i] }
            save()
            if usesRelay { await refreshExplainQuota() }
            return nil
        } catch let f as GeminiClient.Failure {
            if usesRelay { await refreshExplainQuota() }
            if case .quota(_, let limit) = f {
                return String(localized: "今日の「詳しく聞く」（\(limit) 回）を使い切りました。日付が変わると戻ります。自分の Gemini キーを登録すると回数の制限なく使えます。")
            }
            return Self.message(for: f)
        } catch {
            return error.localizedDescription
        }
    }

    var today: String { Logic.todayStamp() }

    // MARK: - 三人で話す

    /// 今の設定で使う Gemini の口。キーも中継も使えないときは nil（理由は talkBlocker）
    var talkClient: GeminiClient? {
        if usesRelay { return GeminiClient(transport: Relay.transport) }
        if let key = KeychainStore.apiKey { return GeminiClient(key: key) }
        return nil
    }

    var talkBlocker: String? {
        if usesRelay {
            if let q = talkQuota, q.remaining == 0 { return String(localized: "今日の「三人で話す」（\(q.limit) ターン）を使い切りました。日付が変わると戻ります。自分の Gemini キーを「設定」で登録すると回数の制限なく使えます。") }
            return nil
        }
        return hasKey ? nil : String(localized: "会話には、「設定」で「おまかせ（キー不要）」を選ぶか、Gemini の API キーを登録してください。")
    }

    func refreshTalkQuota() async {
        guard usesRelay else { talkQuota = nil; return }
        talkQuota = await GeminiClient(transport: Relay.transport).talkQuota()
    }

    /// 会話を終えたら 1 回の記録として残す。今日の表現が会話の中で出ていれば、独り言と同じように判定して記録する
    @discardableResult
    func finishTalk(lines: [TalkLine], good: String, startedAt: Date) -> Session? {
        guard lines.contains(where: { $0.who == "me" && !$0.text.isEmpty }) else { return nil }
        var session = Talk.makeSession(id: ISO8601DateFormatter.withMillis.string(from: startedAt), lines: lines, good: good,
                                       engine: usesRelay ? "talk-cloud" : "talk-gemini")
        let targetCards = todayCards()
        if !targetCards.isEmpty {
            let judged = PhraseLogic.judge(targetCards, text: session.transcript ?? "")
            // 出なかった表現は会話では責めない（独り言と違って話題を選べないので）。出たものだけ記録する
            let hits = judged.filter { $0.result == "hit" || $0.result == "partial" }
            if !hits.isEmpty {
                recordTodayResults(hits)
                session.targets = hits.map { j in SessionTarget(phrase: targetCards.first { $0.id == j.id }?.phrase ?? "", r: j.result, as: j.asSaid) }
            }
        }
        snapshot.sessions.insert(session, at: 0)
        snapshot.sessions.sort { $0.id > $1.id }
        snapshot.sessions = Logic.foldSessions(snapshot.sessions)
        snapshot.recurring = Logic.promoteRecurring(snapshot.recurring, issues: session.issues, today: today)
        save()
        return session
    }

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

    // MARK: - 前に言えなかった表現（候補）

    /// 話す前に出す候補。表現集に入っていない過去の直しから数個
    func candidateItems() -> [Candidates.Item] {
        Candidates.pick(Candidates.collect(snapshot.sessions, phrases: snapshot.phrases), today: today, states: snapshot.candidates)
    }

    /// 選んだ候補を表現集に入れ、今日の表現にも足す（あとは表現集の間隔反復で戻ってくる）
    func useCandidates(_ items: [Candidates.Item]) {
        _ = todayCards()   // 日をまたいでいたら今日の分を先に決めておく（足した分が選び直しで消えないように）
        for it in items {
            let meaning = it.origin == "ask" ? PhraseLogic.cleanMeaning(it.said) : ""
            let note = it.origin == "ask" ? "" : it.said
            addPhrase(it.phrase, meaning: meaning, kind: it.kind, source: "issue", note: note)
            if let card = PhraseLogic.findPhrase(snapshot.phrases, it.phrase), snapshot.today?.ids.contains(card.id) == false {
                snapshot.today?.ids.append(card.id)
            }
        }
        save()
        objectWillChange.send()
    }

    /// 「今日は使わない」: 責めずにしばらく寝かせる（3 日 → 7 日 → 21 日）
    func snoozeCandidates(_ items: [Candidates.Item]) {
        for it in items { snapshot.candidates[it.key] = Candidates.snooze(snapshot.candidates[it.key], today: today) }
        save()
        objectWillChange.send()
    }

    func dismissCandidate(_ item: Candidates.Item) {
        snapshot.candidates[item.key] = Candidates.dismiss(snapshot.candidates[item.key])
        save()
        objectWillChange.send()
    }

    #if DEBUG
    /// スクショ用: 記録の先頭を「いま添削が終わった」ように見せる（-HGShot result）
    func showLatestSessionAsResult() {
        guard let s = snapshot.sessions.first else { return }
        latest = Feedback(correctedText: s.correctedText ?? "", issues: s.issues, recurring: [], recognitionDoubt: [],
                          good: s.good ?? "", transcript: s.transcript ?? "", pronunciation: s.pronunciation ?? [], targets: [], asks: s.asks ?? [])
        latest?.moreFixes = s.moreFixes ?? []
        latestSession = s
        latestJudged = (s.targets ?? []).compactMap { t in
            guard let c = snapshot.phrases.first(where: { $0.phrase == t.phrase }) else { return nil }
            return Judged(id: c.id, result: t.r, asSaid: t.as, note: "", judge: "ai")
        }
        phase = .result
    }
    #endif

    // MARK: - 録音と添削

    func startRecording() async {
        errorMessage = nil
        latest = nil; latestJudged = []
        do {
            // 端末内 AI は字幕の文字を添削するので、字幕は必ず取る
            try await recorder.start(captions: captionsOn || usesOnDevice, language: language, micUID: micUID)
            phase = .recording
        } catch Recorder.Failure.micDenied {
            errorMessage = String(localized: "マイクの使用が許可されていません。設定で「独り言」のマイクをオンにしてください。")
        } catch {
            errorMessage = String(localized: "録音を始められませんでした: \(error.localizedDescription)")
        }
    }

    func stopAndReview() async {
        guard phase == .recording else { return }
        let result = await recorder.stop()
        guard let result else { phase = .idle; errorMessage = String(localized: "録音が取れませんでした"); return }
        guard result.seconds >= 2 else { phase = .idle; errorMessage = String(localized: "短すぎました。もう少し話してから止めてください"); return }
        // まず手元に残す。ここから先で何が起きても、話した内容は消えない
        let p = PendingRecording(audio: result.audio, transcript: result.transcript, seconds: result.seconds, date: Date())
        p.save()
        pending = p
        await review()
    }

    /// 手元に残っている録音を添削に出す（Gemini か端末内 AI）。「もう一度送る」もここを通る
    func review() async {
        guard let p = pending else { return }
        if usesOnDevice {
            await reviewOnDevice(p); return
        }
        let client: GeminiClient
        if usesRelay {
            client = GeminiClient(transport: Relay.transport)
        } else if let key = KeychainStore.apiKey {
            client = GeminiClient(key: key)
        } else {
            phase = .idle
            errorMessage = String(localized: "添削には Google Gemini の API キーが必要です。設定から登録してください。録音は残してあります。")
            return
        }
        phase = .reviewing
        errorMessage = nil
        let targetCards = todayCards()
        let extra = PhraseLogic.targetsSection(targetCards)
        do {
            let fb = try await client.reviewEnglishAudio(p.audio, mimeType: Recorder.mimeType, asrTranscript: p.transcript,
                                                         recurring: Logic.topRecurring(snapshot.recurring), extra: extra,
                                                         system: targetLanguage.audioPrompt)
            finish(p, fb: fb, engine: usesRelay ? "cloud" : "gemini", targetCards: targetCards)
            if usesRelay { await refreshQuota() }
        } catch let f as GeminiClient.Failure {
            phase = .idle
            errorMessage = Self.message(for: f, mic: recorder.inputName) + String(localized: "\n録音は残してあります。「もう一度送る」でやり直せます。")
            if usesRelay { await refreshQuota() }
        } catch {
            phase = .idle
            errorMessage = error.localizedDescription + String(localized: "\n録音は残してあります。「もう一度送る」でやり直せます。")
        }
    }

    /// 端末内 AI で添削する。音声は送れないので、録音中に取った字幕の文字を使う
    private func reviewOnDevice(_ p: PendingRecording) async {
        if case .unavailable(let why) = AppleReviewer.status {
            phase = .idle
            errorMessage = String(localized: "端末内の AI が使えません: \(why)。録音は残してあります。")
            return
        }
        guard !p.transcript.trimmingCharacters(in: .whitespaces).isEmpty else {
            phase = .idle
            errorMessage = String(localized: "聞き取れる発話がありませんでした。端末内の AI は音声認識の文字を添削するので、字幕が出ていないと添削できません。") + (recorder.inputName.isEmpty ? "" : String(localized: "今のマイクは「\(recorder.inputName)」です。")) + String(localized: "録音は残してあります。")
            return
        }
        phase = .reviewing
        errorMessage = nil
        let targetCards = todayCards()
        do {
            let fb = try await AppleReviewer.review(transcript: p.transcript, targets: targetCards.map(\.phrase),
                                                    recurring: Logic.topRecurring(snapshot.recurring).map(\.text))
            finish(p, fb: fb, engine: "apple", targetCards: targetCards)
        } catch AppleReviewer.Failure.model(let m) {
            phase = .idle
            errorMessage = String(localized: "端末内の AI が添削を返せませんでした: \(m)\n録音は残してあります。「もう一度送る」でやり直せます。")
        } catch {
            phase = .idle
            errorMessage = error.localizedDescription + String(localized: "\n録音は残してあります。")
        }
    }

    /// 添削の結果を記録に入れて画面に出す（エンジン共通）
    private func finish(_ p: PendingRecording, fb feedback: Feedback, engine: String, targetCards: [PhraseCard]) {
        var fb = feedback
        // 言った形と直した形が同じ「指摘」は指摘ではない（コーチが褒め言葉を指摘の枠に入れることがある・2026-10-10 実機）
        fb.issues = fb.issues.filter { i in
            let a = (i.original ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
            let b = i.suggestion.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
            return a.isEmpty || a != b
        }
        // 「ほかに直したところ」から、指摘と同じ箇所を外す
        let covered = Set(fb.issues.compactMap { $0.original?.lowercased() })
        fb.moreFixes = fb.moreFixes.filter { !covered.contains($0.original.lowercased()) }
        do {
            var session = Session(id: ISO8601DateFormatter.withMillis.string(from: p.date), transcript: fb.transcript,
                                  correctedText: fb.correctedText, issues: fb.issues, good: fb.good, engine: engine)
            if !p.transcript.isEmpty, p.transcript != fb.transcript { session.asrTranscript = p.transcript }
            if !fb.pronunciation.isEmpty { session.pronunciation = fb.pronunciation }
            fb.asks = PhraseLogic.dropEchoedAsks(fb.asks, cards: targetCards)
            if !fb.asks.isEmpty { session.asks = fb.asks }
            if !fb.moreFixes.isEmpty { session.moreFixes = fb.moreFixes }

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
        case .noKey: return String(localized: "添削には Google Gemini の API キーが必要です。設定から登録してください。")
        case .keyInvalid: return String(localized: "API キーが正しくないようです。設定で確かめてください。")
        case .projectDenied: return String(localized: "この API キーのプロジェクトは Google 側で利用が許可されていません。Google AI Studio で「請求階層」を確認してください。")
        case .rateLimited: return String(localized: "アクセスが集中しています。少し待ってからもう一度どうぞ。")
        case .server(let m): return String(localized: "AI の応答でエラーが起きました: \(m)")
        case .network(let m): return String(localized: "通信に失敗しました: \(m)")
        case .parse: return String(localized: "AI の応答を読めませんでした。もう一度お試しください。")
        case .audio: return String(localized: "音声が空か大きすぎます。")
        case .quota(_, let limit): return String(localized: "今日の無料の添削（\(limit) 回）を使い切りました。日付が変わると戻ります。自分の Gemini キーを登録すると回数の制限なく使えます。")
        case .relayBusy: return String(localized: "今日はアクセスが集中しています。明日またどうぞ。")
        case .silent:
            // 実際に録ったマイクの名前を出す（Mac の既定とは限らない）
            let name = mic.isEmpty ? Platform.inputDeviceName : mic
            return String(localized: "聞き取れる発話がありませんでした。マイクから音が入っていなかったかもしれません。")
                + (name.isEmpty ? "" : String(localized: "今のマイクは「\(name)」です。")) + String(localized: "マイクを確かめて、もう一度どうぞ。")
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

    /// 「日本語で言った分 → 英語ならこう」から表現集へ。意味の欄に日本語で言ったことを残す
    func addFromAsk(_ ask: Ask, way: String) -> Bool {
        addPhrase(way, meaning: PhraseLogic.cleanMeaning(ask.said), kind: "phrase", source: "issue")
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
        PhraseImages.prune(keeping: Set(snapshot.phrases.compactMap(\.image)))
    }

    /// 表現の中身（意味・前に言ってしまった形・例文）を直す。表現そのものは同期の鍵なので変えない
    func updatePhrase(_ id: String, meaning: String, note: String, example: String? = nil) {
        guard let i = snapshot.phrases.firstIndex(where: { $0.id == id }) else { return }
        snapshot.phrases[i].meaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.phrases[i].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let example {
            let e = example.trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot.phrases[i].example = e.isEmpty ? nil : e
        }
        save()
    }

    // MARK: - スクショから表現

    /// 共有シートで受け取って、まだ表現にしていないスクショの枚数（表現タブに出す）
    @Published private(set) var inboxCount = 0

    func refreshInbox() { inboxCount = ScreenshotInbox.files().count }

    /// スクショ 1 枚を読んで候補にする。失敗したら利用者向けの文を返す
    func scanScreenshot(_ data: Data) async -> Result<[ScanCandidate], ScanFailure> {
        if DevHooks.fakeScan {
            try? await Task.sleep(nanoseconds: 800_000_000)
            return .success(Scan.parse(#"{"items":[{"phrase":"get the hang of","meaning":"〜のコツをつかむ・慣れる","example":"You'll get the hang of it in no time.\nすぐにコツをつかめるよ。\n\nI'm finally getting the hang of driving on the left.\nやっと左側通行に慣れてきた。","kind":"phrase"},{"phrase":"learn the ropes","meaning":"仕事などの要領を覚える","example":"","kind":"phrase"}]}"#))
        }
        let client: GeminiClient
        if usesRelay {
            client = GeminiClient(transport: Relay.transport)
        } else if let key = KeychainStore.apiKey {
            client = GeminiClient(key: key)
        } else {
            return .failure(ScanFailure(String(localized: "スクショを読むには、「設定」で「おまかせ（キー不要）」を選ぶか、Gemini の API キーを登録してください。")))
        }
        guard let jpeg = PhraseImages.jpeg(data, maxPixel: PhraseImages.sendMaxPixel, quality: 0.8) else {
            return .failure(ScanFailure(String(localized: "画像を開けませんでした。")))
        }
        do {
            return .success(try await client.scanImage(jpeg, system: Scan.system(language: targetLanguage)))
        } catch let f as GeminiClient.Failure {
            if case .quota(_, let limit) = f {
                return .failure(ScanFailure(String(localized: "今日の「スクショから表現」（\(limit) 回）を使い切りました。日付が変わると戻ります。自分の Gemini キーを登録すると回数の制限なく使えます。")))
            }
            return .failure(ScanFailure(Self.message(for: f)))
        } catch {
            return .failure(ScanFailure(error.localizedDescription))
        }
    }

    /// 選んだ候補を表現集に入れる。元のスクショは縮めて 1 枚だけ保存し、入れたカードすべてに付ける。入れた件数を返す
    func addScanned(_ items: [ScanCandidate], image: Data?) -> Int {
        let name = image.flatMap(PhraseImages.store)
        let cards = items.compactMap { c -> PhraseCard? in
            guard var card = PhraseLogic.makePhrase(phrase: c.phrase, meaning: c.meaning, kind: c.kind, today: today) else { return nil }
            let e = c.example.trimmingCharacters(in: .whitespacesAndNewlines)
            card.example = e.isEmpty ? nil : e
            card.image = name
            return card
        }
        let r = PhraseLogic.addPhrases(snapshot.phrases, cards)
        snapshot.phrases = PhraseLogic.trim(r.list)
        save()
        return r.added
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
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate("Md HHmm")
        let mmss = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return String(localized: "\(f.string(from: date)) に録音（\(mmss)）")
    }
}
