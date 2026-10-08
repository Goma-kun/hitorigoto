import Foundation
import HitorigotoCore

// JS 版と答えを突き合わせるための入口。標準入力に {"cases":[...]} を受け取り、
// 1 件ずつ Core を呼んで結果を JSON で返す。../test/parity_swift_test.mjs が使う。
//
// `hg-probe review --text "..."` / `hg-probe review --audio file.m4a [--asr "..."]` で
// 本物の Gemini に投げる（キーは ~/.config/nishira/gemini_api_key）。実 API の確認用

func decode<T: Decodable>(_ t: T.Type, _ v: Any?) -> T? {
    guard let v, let d = try? JSONSerialization.data(withJSONObject: v) else { return nil }
    return try? JSONDecoder().decode(t, from: d)
}

func encode<T: Encodable>(_ v: T) -> Any {
    let d = try! JSONEncoder().encode(v)
    return try! JSONSerialization.jsonObject(with: d)
}

func run(_ c: [String: Any]) -> Any {
    let fn = c["fn"] as? String ?? ""
    switch fn {
    case "prompts":
        return ["system": Prompts.system, "audio": Prompts.audio]
    case "parseFeedback":
        if let fb = Logic.parseFeedback(c["raw"] as? String) { return encode(fb) }
        return NSNull()
    case "promoteRecurring":
        let prev = decode([Recurring].self, c["prev"]) ?? []
        let issues = decode([Issue].self, c["issues"]) ?? []
        return encode(Logic.promoteRecurring(prev, issues: issues, today: c["today"] as? String ?? ""))
    case "topRecurring":
        let list = decode([Recurring].self, c["list"]) ?? []
        return encode(Logic.topRecurring(list, limit: c["limit"] as? Int ?? Logic.recurringSend, min: c["min"] as? Int ?? Logic.recurringMin))
    case "foldSessions":
        let list = decode([Session].self, c["sessions"]) ?? []
        return encode(Logic.foldSessions(list, keepFull: c["keepFull"] as? Int ?? Logic.keepFull, keepTotal: c["keepTotal"] as? Int ?? Logic.keepTotal))
    case "userMessage":
        let rec = decode([Recurring].self, c["recurring"]) ?? []
        let extra = c["extra"] as? String ?? ""
        if c["audio"] as? Bool == true { return Logic.buildEnglishAudioUserMessage(c["text"] as? String ?? "", recurring: rec, extra: extra) }
        return Logic.buildEnglishUserMessage(c["text"] as? String ?? "", recurring: rec, extra: extra)
    case "sessionText":
        let s = decode(Session.self, c["session"])!
        let L = c["labels"] as? [String: Any] ?? [:]
        let labels = Logic.Labels(corrected: L["corrected"] as? String ?? "", issues: L["issues"] as? String ?? "",
                                  good: L["good"] as? String ?? "", said: L["said"] as? String ?? "", pron: L["pron"] as? String ?? "",
                                  types: L["types"] as? [String: String] ?? [:])
        return Logic.buildSessionText(s, labels: labels)
    case "addDays":
        return PhraseLogic.addDays(c["date"] as? String ?? "", c["n"] as? Int ?? 0)
    case "daysBetween":
        return PhraseLogic.daysBetween(c["from"] as? String ?? "", c["to"] as? String ?? "")
    case "parsePhraseLine":
        if let r = PhraseLogic.parsePhraseLine(c["line"] as? String ?? "") { return ["phrase": r.phrase, "meaning": r.meaning] }
        return NSNull()
    case "detect":
        let d = PhraseLogic.detect(c["phrase"] as? String ?? "", in: c["text"] as? String ?? "")
        return ["used": d.used, "exact": d.exact, "asSaid": d.asSaid]
    case "rebuild":
        return encode(PhraseLogic.rebuild(decode(PhraseCard.self, c["card"])!))
    case "setSpeechResult":
        return encode(PhraseLogic.setSpeechResult(decode(PhraseCard.self, c["card"])!, today: c["today"] as? String ?? "",
                                                  result: c["result"] as? String ?? "", asSaid: c["asSaid"] as? String ?? ""))
    case "setRecallResult":
        return encode(PhraseLogic.setRecallResult(decode(PhraseCard.self, c["card"])!, today: c["today"] as? String ?? "", ok: c["ok"] as? Bool ?? false))
    case "setManualStatus":
        return encode(PhraseLogic.setManualStatus(decode(PhraseCard.self, c["card"])!, c["status"] as? String ?? "", today: c["today"] as? String ?? ""))
    case "pickToday":
        let list = decode([PhraseCard].self, c["list"]) ?? []
        let picked = PhraseLogic.pickToday(list, today: c["today"] as? String ?? "", total: c["total"] as? Int ?? PhraseLogic.defaultTotal,
                                           maxNew: c["maxNew"] as? Int ?? PhraseLogic.defaultNew, fixedIds: c["fixedIds"] as? [String] ?? [])
        return picked.map { $0.id }
    case "mergeAiTargets":
        let cards = decode([PhraseCard].self, c["cards"]) ?? []
        let ai = decode([Target].self, c["ai"]) ?? []
        let judged = PhraseLogic.mergeAiTargets(PhraseLogic.judge(cards, text: c["text"] as? String ?? ""), cards: cards, aiTargets: ai)
        // JS の judgePhrases は note を持たない（AI が触れたものだけ note が付く）
        return judged.map { j -> [String: Any] in
            var d: [String: Any] = ["id": j.id, "result": j.result, "asSaid": j.asSaid, "judge": j.judge]
            if j.judge == "ai" { d["note"] = j.note }
            return d
        }
    case "targetsSection":
        return PhraseLogic.targetsSection(decode([PhraseCard].self, c["cards"]) ?? [])
    case "stats":
        let s = PhraseLogic.stats(decode([PhraseCard].self, c["list"]) ?? [])
        return ["total": s.total, "active": s.active, "fresh": s.fresh, "graduated": s.graduated]
    case "marks":
        return PhraseLogic.marks(decode(PhraseCard.self, c["card"])!)
    case "importJson":
        let data = (c["json"] as? String ?? "").data(using: .utf8)!
        let snap = decode(Snapshot.self, c["snapshot"]) ?? Snapshot()
        do {
            let r = try Merge.importJson(data, into: snap)
            return ["sessions": r.addedSessions, "recurring": r.snapshot.recurring.count, "phrases": r.snapshot.phrases.count]
        } catch { return ["error": "\(error)"] }
    default:
        return ["error": "unknown fn \(fn)"]
    }
}

// ---- 実 API（review）----
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "review" {
    var args = Array(CommandLine.arguments.dropFirst(2))
    func opt(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
    }
    let text = opt("--text"), audio = opt("--audio"), asr = opt("--asr") ?? ""
    let targets = (opt("--targets") ?? "").split(separator: "|").map(String.init)
    let keyPath = NSString(string: "~/.config/nishira/gemini_api_key").expandingTildeInPath
    guard let key = try? String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
        FileHandle.standardError.write("NG: キーが読めません\n".data(using: .utf8)!); exit(1)
    }
    let cards = targets.compactMap { PhraseLogic.makePhrase(phrase: $0, today: Logic.todayStamp()) }
    let extra = PhraseLogic.targetsSection(cards)
    // HG_RELAY=1 なら開発者の中継サーバー経由（キー不要）。HG_RELAY_APPKEY と HG_RELAY_URL を環境変数で
    let env = ProcessInfo.processInfo.environment
    let client: GeminiClient
    if env["HG_RELAY"] == "1", let u = URL(string: env["HG_RELAY_URL"] ?? "https://hitorigoto-relay.jsphdn.workers.dev") {
        client = GeminiClient(transport: .relay(url: u, deviceId: env["HG_DEVICE_ID"] ?? "0A1B2C3D-0000-4000-8000-0000000000AA", appKey: env["HG_RELAY_APPKEY"] ?? ""))
    } else {
        client = GeminiClient(key: key)
    }
    let sem = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    Task {
        do {
            let t0 = Date()
            let fb: Feedback
            if let audio {
                let data = try Data(contentsOf: URL(fileURLWithPath: audio))
                let mime = audio.hasSuffix(".wav") ? "audio/wav" : audio.hasSuffix(".webm") ? "audio/webm" : "audio/mp4"
                fb = try await client.reviewEnglishAudio(data, mimeType: mime, asrTranscript: asr, recurring: [], extra: extra)
            } else {
                fb = try await client.reviewEnglish(text ?? "", recurring: [], extra: extra)
            }
            let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
            let out = try JSONSerialization.data(withJSONObject: ["seconds": secs, "feedback": encode(fb),
                "judged": PhraseLogic.mergeAiTargets(PhraseLogic.judge(cards, text: fb.transcript.isEmpty ? (text ?? "") : fb.transcript), cards: cards, aiTargets: fb.targets)
                    .map { j in ["phrase": cards.first { $0.id == j.id }?.phrase ?? "", "result": j.result, "judge": j.judge, "asSaid": j.asSaid, "note": j.note] }],
                options: [.prettyPrinted, .withoutEscapingSlashes])
            print(String(data: out, encoding: .utf8)!)
        } catch {
            print("NG: \(error)"); exitCode = 1
        }
        sem.signal()
    }
    sem.wait()
    exit(exitCode)
}

// ---- 突き合わせ（stdin → stdout）----
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
      let cases = obj["cases"] as? [[String: Any]] else {
    FileHandle.standardError.write("NG: 入力が読めません\n".data(using: .utf8)!); exit(1)
}
let results = cases.map(run)
let out = try! JSONSerialization.data(withJSONObject: ["results": results], options: [.withoutEscapingSlashes])
FileHandle.standardOutput.write(out)
