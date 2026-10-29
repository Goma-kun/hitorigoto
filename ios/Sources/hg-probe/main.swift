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
                                  asks: L["asks"] as? String ?? "", more: L["more"] as? String ?? "",
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
    case "dropEchoedAsks":
        return PhraseLogic.dropEchoedAsks(decode([Ask].self, c["asks"]) ?? [], cards: decode([PhraseCard].self, c["cards"]) ?? []).map(\.said)
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

// ---- 実 API（voice）----
// `hg-probe voice --lines lines.json --out out.wav` 三人で話すの 1 ターンぶんの行（TalkLine の JSON 配列）を AI の声にする。
// 読み上げる片（Voice.parts）と、かかった秒を出す。HG_RELAY=1 なら中継サーバーの /v1/voice を通る
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "voice" {
    var args = Array(CommandLine.arguments.dropFirst(2))
    func take(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
    }
    let env = ProcessInfo.processInfo.environment
    let lines: [TalkLine] = take("--lines").flatMap { FileManager.default.contents(atPath: $0) }.flatMap { try? JSONDecoder().decode([TalkLine].self, from: $0) } ?? []
    let out = take("--out") ?? "voice.wav"
    let lang = TargetLanguage(rawValue: env["HG_LANG"] ?? "en-US") ?? .enUS
    let client: GeminiClient
    if env["HG_RELAY"] == "1" {
        client = GeminiClient(transport: .relay(url: URL(string: env["HG_RELAY_URL"] ?? "https://hitorigoto-relay.jsphdn.workers.dev")!, deviceId: env["HG_DEVICE_ID"] ?? "0A1B2C3D-0000-4000-8000-0000000000AA", appKey: env["HG_RELAY_APPKEY"] ?? ""))
    } else {
        let key = (try? String(contentsOfFile: NSString(string: "~/.config/nishira/gemini_api_key").expandingTildeInPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        client = GeminiClient(key: key)
    }
    let partner = Partners.find(env["HG_PARTNER"] ?? "", language: lang)
    let clarity = Voice.Clarity(rawValue: ProcessInfo.processInfo.environment["HG_CLARITY"] ?? "") ?? .natural
    let parts = Voice.parts(for: lines, partner: partner, clarity: clarity)
    for p in parts { print("[\(p.speaker)] \(p.text)") }
    let sem = DispatchSemaphore(value: 0)
    Task {
        let t0 = Date()
        do {
            let voices = Voice.voices(partner: partner, tora: env["HG_TORA"] ?? Voice.defaultToraVoice)
            let collide = Voice.collideParts(for: lines, partner: partner, clarity: clarity)
            var pieces: [Data] = []
            if collide.count >= 2 {
                // アプリと同じ: 言いかけを別々に作って重ねる
                async let a = client.speech([collide[0]], voices: voices)
                async let b = client.speech([collide[1]], voices: voices)
                pieces.append(Voice.collide(try await a, try await b))
                print("collide: [\(collide[0].speaker)] \(collide[0].text) × [\(collide[1].speaker)] \(collide[1].text)")
            }
            if env["HG_SPLIT"] == "1", parts.count >= 2, parts[0].speaker == Voice.tora {
                // アプリと同じ: トラさん先行のターンはトラさんの分を別に作ってつなぐ（飛ばせるように）
                async let a = client.speech([parts[0]], voices: voices)
                async let b = client.speech(Array(parts.dropFirst()), voices: voices)
                let (ta, tb) = (try await a, try await b)
                print(String(format: "split: tora %.2fs / rest %.2fs", Voice.duration(ta), Voice.duration(tb)))
                pieces.append(ta); pieces.append(tb)
            } else if !parts.isEmpty { pieces.append(try await client.speech(parts, voices: voices)) }
            let wav = pieces.count == 1 ? pieces[0] : Voice.join(pieces)
            try wav.write(to: URL(fileURLWithPath: out))
            print(String(format: "ok %.1fs %d bytes → %@", Date().timeIntervalSince(t0), wav.count, out))
        } catch { print("error: \(error)") }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// ---- 実 API（clone）----
// `hg-probe clone --source talk.wav --consent consent.wav [--say "Hello"] [--out out.wav]`
// 自分の声を複製して鍵（voicekey_…）を出す。--say を付けると、その鍵で一言しゃべらせて WAV に書く。
// WAV は何 Hz でもよい（24kHz・モノラル・16bit に直してから送る: afconvert -f WAVE -d LEI16@24000 -c 1 in.wav out.wav）。
// 同意の文は Voice.consentStatement（--lang ja / en）を本人がそのまま読んだもの。HG_RELAY=1 なら中継の /v1/voice-clone・/v1/speak を通る
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "clone" {
    var args = Array(CommandLine.arguments.dropFirst(2))
    func take(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
    }
    let env = ProcessInfo.processInfo.environment
    if args.contains("--statement") { print(Voice.consentStatement(take("--lang") ?? "ja")); exit(0) }
    guard let sp = take("--source"), let cp = take("--consent"),
          let source = FileManager.default.contents(atPath: sp), let consent = FileManager.default.contents(atPath: cp) else {
        print("--source と --consent（どちらも WAV）が要ります。--statement で同意の文を出します"); exit(1)
    }
    let say = take("--say")
    let out = take("--out") ?? "clone.wav"
    let client: GeminiClient
    if env["HG_RELAY"] == "1" {
        client = GeminiClient(transport: .relay(url: URL(string: env["HG_RELAY_URL"] ?? "https://hitorigoto-relay.jsphdn.workers.dev")!, deviceId: env["HG_DEVICE_ID"] ?? "0A1B2C3D-0000-4000-8000-0000000000AA", appKey: env["HG_RELAY_APPKEY"] ?? ""))
    } else {
        let key = (try? String(contentsOfFile: NSString(string: "~/.config/nishira/gemini_api_key").expandingTildeInPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        client = GeminiClient(key: key)
    }
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let t0 = Date()
            let key: String
            if let k = env["HG_VOICEKEY"] { key = k } else { key = try await client.createVoice(source: source, consent: consent) }
            print(String(format: "voicekey (%d chars) %.1fs: %@", key.count, Date().timeIntervalSince(t0), key))
            if let say {
                let t1 = Date()
                let partner = Voice.customPartner(id: "probe", name: env["HG_NAME"] ?? "Me", female: env["HG_FEMALE"] == "1", blurb: "", voice: key)
                let part = VoicePart(speaker: Voice.native, text: say, style: Voice.nativeStyle(partner, clarity: .natural))
                let wav = try await client.speech([part], voices: Voice.voices(partner: partner))
                try wav.write(to: URL(fileURLWithPath: out))
                print(String(format: "ok %.1fs  %.1fs of audio → %@", Date().timeIntervalSince(t1), Double(Voice.pcm(wav).count) / Double(Voice.sampleRate), out))
            }
        } catch { print("error: \(error)") }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// ---- 実 API（recap）----
// `hg-probe recap --history h.json --out recap.wav` 会話の記録（TalkLine の JSON 配列）から復習の音声を作る。
// 台本だけ見たいときは --out を省く。HG_PARTNER / HG_TORA / HG_RELAY は voice と同じ
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "recap" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    func take(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let lines: [TalkLine] = take("--history").flatMap { FileManager.default.contents(atPath: $0) }.flatMap { try? JSONDecoder().decode([TalkLine].self, from: $0) } ?? []
    guard !lines.isEmpty else { print("--history が要ります"); exit(1) }
    let env = ProcessInfo.processInfo.environment
    let lang = TargetLanguage(rawValue: env["HG_LANG"] ?? "en-US") ?? .enUS
    let partner = Partners.find(env["HG_PARTNER"] ?? "", language: lang)
    let session = Talk.makeSession(id: "probe", lines: lines, good: env["HG_GOOD"] ?? "", engine: "probe")
    let client: GeminiClient
    if env["HG_RELAY"] == "1" {
        client = GeminiClient(transport: .relay(url: URL(string: env["HG_RELAY_URL"] ?? "https://hitorigoto-relay.jsphdn.workers.dev")!, deviceId: env["HG_DEVICE_ID"] ?? "0A1B2C3D-0000-4000-8000-0000000000AA", appKey: env["HG_RELAY_APPKEY"] ?? ""))
    } else {
        let key = (try? String(contentsOfFile: NSString(string: "~/.config/nishira/gemini_api_key").expandingTildeInPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        client = GeminiClient(key: key)
    }
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let t0 = Date()
            let script = try await client.recapScript(message: Recap.userMessage(session: session, partner: partner, language: lang),
                                                      system: Recap.system(language: lang, partner: partner, explanation: .ja))
            for l in script { print("[\(l.who == "tora" ? "Tora" : partner.name)] \(l.text)") }
            let words = script.map(\.text).joined(separator: " ").split(separator: " ").count
            print("lines \(script.count)  words \(words)  script \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            if let out = take("--out") {
                let voices = Voice.voices(partner: partner, tora: env["HG_TORA"] ?? Voice.defaultToraVoice)
                var pieces: [Data] = []
                for c in Recap.chunks(script, partner: partner) { pieces.append(try await client.speech(c, voices: voices)) }
                let wav = pieces.count == 1 ? pieces[0] : Voice.join(pieces, gap: 0.6)
                try wav.write(to: URL(fileURLWithPath: out))
                print("ok \(pieces.count) chunks  \(String(format: "%.1f", Double(Voice.pcm(wav).count) / Double(Voice.sampleRate)))s  \(String(format: "%.1f", Date().timeIntervalSince(t0)))s → \(out)")
            }
        } catch { print("error: \(error)") }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// ---- 実 API（talk）----
// `hg-probe talk --open "話題"` / `hg-probe talk --audio turn.m4a [--history h.json]` 三人で話すの 1 ターンを本物の Gemini に投げる。
// --history は TalkLine の JSON 配列（省略可）。--hint / --close も可。結果は JSON で返す
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "talk" {
    var args = Array(CommandLine.arguments.dropFirst(2))
    func take(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
    }
    let audioPath = take("--audio")
    let topic = take("--open")
    let historyPath = take("--history")
    let repeatWays = take("--repeat")?.components(separatedBy: " / ") ?? []
    let rerunPath = take("--rerun")          // さっきの会話（TalkLine の JSON 配列）→「もう一回」のはじまり
    let reviewPath = take("--review")        // 前回の会話の記録（Session の JSON）→ 翌日の Sam が振る
    let isHint = args.contains("--hint"), isClose = args.contains("--close")
    let cutLine = take("--cutin")            // 被り: 途中で遮った Sam の発言（全文）
    let cutHeard = Double(take("--cutin-heard") ?? "0.3") ?? 0.3
    let isDemo = args.contains("--demo")     // 譲り合いの見本のターン
    let env = ProcessInfo.processInfo.environment
    let client: GeminiClient
    if env["HG_RELAY"] == "1" {
        client = GeminiClient(transport: .relay(url: URL(string: env["HG_RELAY_URL"] ?? "https://hitorigoto-relay.jsphdn.workers.dev")!, deviceId: env["HG_DEVICE_ID"] ?? "0A1B2C3D-0000-4000-8000-0000000000AA", appKey: env["HG_RELAY_APPKEY"] ?? ""))
    } else {
        let key = (try? String(contentsOfFile: NSString(string: "~/.config/nishira/gemini_api_key").expandingTildeInPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        client = GeminiClient(key: key)
    }
    let history: [TalkLine] = historyPath.flatMap { FileManager.default.contents(atPath: $0) }.flatMap { try? JSONDecoder().decode([TalkLine].self, from: $0) } ?? []
    let rerun: [TalkLine] = rerunPath.flatMap { FileManager.default.contents(atPath: $0) }.flatMap { try? JSONDecoder().decode([TalkLine].self, from: $0) } ?? []
    let reviewSessions: [Session] = reviewPath.flatMap { FileManager.default.contents(atPath: $0) }.flatMap { try? JSONDecoder().decode([Session].self, from: $0) } ?? []
    let review = TalkReview.from(sessions: reviewSessions, today: Logic.todayStamp())
    let request: Talk.Request = topic.map { .open(topic: $0, rerun: rerun) } ?? (!repeatWays.isEmpty ? .repeat(ways: repeatWays) : (isHint ? .hint(wish: env["HG_WISH"] ?? "") : (isClose ? .close : .speak)))
    let audio = audioPath.flatMap { FileManager.default.contents(atPath: $0) }
    let lang = TargetLanguage(rawValue: env["HG_LANG"] ?? "en-US") ?? .enUS
    let message = Talk.userMessage(request: request, history: history, language: lang, targets: (env["HG_TARGETS"] ?? "").split(separator: ",").map(String.init), review: review, hasAudio: audio != nil,
                                   cutIn: cutLine.map { CutIn(line: $0, heard: cutHeard, first: !args.contains("--not-first")) }, overlapDemo: isDemo, explanation: .ja)
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let t = try await client.talk(audio: audio, mimeType: "audio/mp4", message: message, system: Talk.system(language: lang, explanation: .ja))
            let out: [String: Any] = ["heard": t.heard, "corrected": t.corrected, "reply": t.reply, "reply_sub": t.replySub, "help": t.help, "help_sub": t.helpSub,
                                      "asks": encode(t.asks), "fixes": encode(t.fixes), "good": t.good, "said_ok": t.saidOk, "stuck": t.stuck,
                                      "banter": t.banter.map { ["who": $0.who, "text": $0.text, "sub": $0.sub, "tag": $0.tag] }]
            let d = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .withoutEscapingSlashes])
            print(String(data: d, encoding: .utf8)!)
        } catch { print("{\"error\": \"\(error)\"}") }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// ---- 実 API（scan）----
// `hg-probe scan --image shot.png [--image shot2.jpg]` スクショから表現の候補を取り出す（画像はそのまま送る。4MB まで）
// HG_RELAY=1 なら中継サーバーの /v1/scan を通る
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "scan" {
    var paths: [String] = []
    var args = Array(CommandLine.arguments.dropFirst(2))
    while let i = args.firstIndex(of: "--image"), i + 1 < args.count { paths.append(args[i + 1]); args.removeSubrange(i...(i + 1)) }
    let env = ProcessInfo.processInfo.environment
    let client: GeminiClient
    if env["HG_RELAY"] == "1" {
        client = GeminiClient(transport: .relay(url: URL(string: env["HG_RELAY_URL"] ?? "https://hitorigoto-relay.jsphdn.workers.dev")!, deviceId: env["HG_DEVICE_ID"] ?? "0A1B2C3D-0000-4000-8000-0000000000AA", appKey: env["HG_RELAY_APPKEY"] ?? ""))
    } else {
        let key = (try? String(contentsOfFile: NSString(string: "~/.config/nishira/gemini_api_key").expandingTildeInPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        client = GeminiClient(key: key)
    }
    let sem = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    Task {
        for p in paths {
            guard let data = FileManager.default.contents(atPath: p) else { print("NG: 読めない \(p)"); exitCode = 1; continue }
            do {
                let started = Date()
                let items = try await client.scanImage(data, system: Scan.system(language: .enUS, explanation: .ja))
                print("== \(p)（\(data.count / 1024)KB・\(String(format: "%.1f", Date().timeIntervalSince(started)))秒）")
                for c in items { print("・[\(c.kind)] \(c.phrase)\n  意味: \(c.meaning)\n  例文: \(c.example.replacingOccurrences(of: "\n", with: " / "))") }
                if items.isEmpty { print("（候補なし）") }
            } catch { print("NG: \(p) \(error)"); exitCode = 1 }
        }
        sem.signal()
    }
    sem.wait()
    exit(exitCode)
}

// ---- 実 API（explain）----
// `hg-probe explain --original "..." --suggestion "..." [--reason "..."] [--question "..."] [--preset deeper|examples|grammar|compare]`
// HG_RELAY=1 なら中継サーバーの /v1/explain を通る
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "explain" {
    var args = Array(CommandLine.arguments.dropFirst(2))
    func opt(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
    }
    let topic = ExplainTopic(kind: opt("--kind") ?? "issue", original: opt("--original") ?? "", suggestion: opt("--suggestion") ?? "", reason: opt("--reason") ?? "")
    let preset = Explain.Preset(rawValue: opt("--preset") ?? "")
    let question = opt("--question") ?? preset?.label ?? Explain.Preset.deeper.label
    let context = opt("--context") ?? ""
    let env = ProcessInfo.processInfo.environment
    let client: GeminiClient
    if env["HG_RELAY"] == "1" {
        client = GeminiClient(transport: .relay(url: URL(string: "https://hitorigoto-relay.jsphdn.workers.dev")!, deviceId: env["HG_DEVICE_ID"] ?? "0A1B2C3D-0000-4000-8000-0000000000AA", appKey: env["HG_RELAY_APPKEY"] ?? ""))
    } else {
        let key = (try? String(contentsOfFile: NSString(string: "~/.config/nishira/gemini_api_key").expandingTildeInPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        client = GeminiClient(key: key)
    }
    let sem = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    Task {
        do {
            let t = try await client.explain(topic: topic, context: context, history: [], question: question,
                                             request: preset?.request, system: Explain.system(language: .enUS, explanation: .ja))
            print("Q: \(t.q)\n\n\(t.a)\n")
            for e in t.examples { print("・\(e.text)\n  \(e.ja)") }
            if case .relay = client.transport { print("\nquota:", await client.explainQuota().map { "\($0.used)/\($0.limit)" } ?? "?") }
        } catch { print("NG: \(error)"); exitCode = 1 }
        sem.signal()
    }
    sem.wait()
    exit(exitCode)
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
    let lang = TargetLanguage(rawValue: opt("--lang") ?? "") ?? .default
    let explain: TargetLanguage.Explanation = opt("--explain") == "en" ? .en : .ja
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
                fb = try await client.reviewEnglishAudio(data, mimeType: mime, asrTranscript: asr, recurring: [], extra: extra, system: lang.localize(Prompts.audio, explanation: explain))
            } else {
                fb = try await client.reviewEnglish(text ?? "", recurring: [], extra: extra, system: lang.localize(Prompts.system, explanation: explain))
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
