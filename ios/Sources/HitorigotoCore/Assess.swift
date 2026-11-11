import Foundation

// 話した英語のレベルの推定（2026-11-12 第 1 段階）。設計は Obsidian 01_Projects/Hitorigoto/独り言_設計_試験レベル判定_20261112.md
// - 添削とは別に、採点だけを裏で 1 回呼ぶ（添削の質を落とさない・待ち時間を増やさない）
// - 5 観点を CEFR の段（A2〜C2・+ つき）で採点させ、観点ごとに本人の文の引用を必須にする（引用の無い観点は捨てる）
// - 機械で数えられる数字（1 分あたりの語数・100 語あたりの直しの数など）と食い違う回は「不安定」として平均から外す
// - 表示は 1 回の点ではなく、直近 5 回の幅。目標の試験の物差し（英検の Speaking の CSE）に置き換えて出す
// 指示文はアプリ版だけの機能なので、ここが正本（Prompts.swift の機械生成とは別）。英語のときだけ測る

// MARK: - CEFR の段

public enum CEFRScale {
    /// 段と数値。+ は半段
    public static let steps: [(label: String, value: Double)] = [
        ("A1", 1.0), ("A2", 2.0), ("B1", 3.0), ("B1+", 3.5), ("B2", 4.0), ("B2+", 4.5), ("C1", 5.0), ("C1+", 5.5), ("C2", 6.0),
    ]

    public static func value(_ label: String) -> Double? {
        let l = label.trimmingCharacters(in: .whitespaces).uppercased()
        return steps.first { $0.label == l }?.value
    }

    /// 数値をいちばん近い段の名前に（半段刻み）
    public static func label(_ v: Double) -> String {
        steps.min { abs($0.value - v) < abs($1.value - v) }!.label
    }

    /// 英検の Speaking の CSE の目盛りとの対応（段の入口の点）。英検公式の CEFR 対応表（技能別 Speaking・https://www.eiken.or.jp/cse/ 2026-11-12 確認）
    /// A1 362／A2 404／B1 467／B2 519／C1 613。C2 の行は公式表に無いので、C1 からの伸びで置いた仮の値（1 級の満点 850 より下）
    /// 段の間は直線でつなぐ。+ の段は前後の中間
    static let cseAnchors: [(value: Double, cse: Double)] = [
        (1.0, 362), (2.0, 404), (3.0, 467), (4.0, 519), (5.0, 613), (6.0, 720),
    ]

    public static func cse(_ v: Double) -> Int {
        let a = cseAnchors
        if v <= a.first!.value { return Int(a.first!.cse) }
        if v >= a.last!.value { return Int(a.last!.cse) }
        for i in 0..<(a.count - 1) where v >= a[i].value && v <= a[i + 1].value {
            let t = (v - a[i].value) / (a[i + 1].value - a[i].value)
            return Int((a[i].cse + t * (a[i + 1].cse - a[i].cse)).rounded())
        }
        return Int(a.last!.cse)
    }
}

// MARK: - 保存する形

/// 観点 1 つの採点
public struct AssessAxis: Codable, Equatable, Sendable {
    /// range（語彙・表現の幅）| accuracy（文法の正確さ）| fluency（流暢さ）| coherence（話の組み立て）| pronunciation（発音）
    public var key: String
    /// CEFR の段（"B2+" など）
    public var level: String
    /// 根拠にした本人の言葉（短い引用）
    public var evidence: String

    public init(key: String, level: String, evidence: String) { self.key = key; self.level = level; self.evidence = evidence }

    public var value: Double? { CEFRScale.value(level) }
}

/// 機械で数えた数字
public struct AssessMetrics: Codable, Equatable, Sendable {
    public var words: Int
    /// 録音の長さ（秒）。文字だけで測った回は nil
    public var seconds: Double?
    /// 100 語あたりの直しの数（指摘＋ほかに直したところ）
    public var fixesPer100: Double
    /// 語彙の多様さ（50 語の窓で数えた異なり語の割合の平均・0〜1）
    public var mattr: Double
    /// え・あー（um, uh, er など）の数
    public var fillers: Int

    public init(words: Int, seconds: Double?, fixesPer100: Double, mattr: Double, fillers: Int) {
        self.words = words; self.seconds = seconds; self.fixesPer100 = fixesPer100; self.mattr = mattr; self.fillers = fillers
    }

    /// 1 分あたりの語数
    public var wpm: Double? {
        guard let s = seconds, s > 0 else { return nil }
        return Double(words) / s * 60
    }
}

/// 1 回分の推定。Session に付けて保存する（畳んだ古い記録にも残す）
public struct Assessment: Codable, Equatable, Sendable {
    /// 採点のやり方の版。指示文を大きく変えたら上げる（古い版の回は混ぜない）
    public var v: Int
    public var axes: [AssessAxis]
    public var metrics: AssessMetrics
    /// audio（音声で採点）| text（文字だけ・発音と流暢さは測らない）
    public var mode: String
    /// 平均から外した理由。空なら使える回
    public var unstable: String?

    public init(v: Int = Assess.version, axes: [AssessAxis], metrics: AssessMetrics, mode: String, unstable: String? = nil) {
        self.v = v; self.axes = axes; self.metrics = metrics; self.mode = mode; self.unstable = unstable
    }

    /// 観点の平均（CEFR の数値）。測れた観点が 3 つ未満なら nil
    public var overall: Double? {
        let vs = axes.compactMap(\.value)
        guard vs.count >= 3 else { return nil }
        return vs.reduce(0, +) / Double(vs.count)
    }

    public var usable: Bool { (unstable ?? "").isEmpty && overall != nil && v == Assess.version }
}

// MARK: - 目標

/// 目標にする試験。英検は二次（Speaking）の合格基準の CSE と、その級の Speaking の満点
public enum AssessGoal: String, CaseIterable, Sendable {
    case g1, gp1, g2, cefrB2, cefrC1

    public var label: String {
        switch self {
        case .g1: return String(localized: "1 級 2 次")
        case .gp1: return String(localized: "準 1 級 2 次")
        case .g2: return String(localized: "2 級 2 次")
        case .cefrB2: return "CEFR B2"
        case .cefrC1: return "CEFR C1"
        }
    }

    /// 合格ライン（CSE）。CEFR の目標は段の入口の点
    public var passCSE: Int {
        switch self {
        case .g1: return 602
        case .gp1: return 512
        case .g2: return 460
        case .cefrB2: return CEFRScale.cse(4.0)
        case .cefrC1: return CEFRScale.cse(5.0)
        }
    }

    /// その級の Speaking の満点（英検はこれより上を出さない）。CEFR の目標は目盛りの上端
    public var maxCSE: Int {
        switch self {
        case .g1: return 850
        case .gp1: return 750
        case .g2: return 650
        case .cefrB2, .cefrC1: return 850
        }
    }

    public var isEiken: Bool { self == .g1 || self == .gp1 || self == .g2 }
}

// MARK: - いまの推定（直近の回をまとめる）

public struct AssessSummary: Equatable, Sendable {
    public static let window = 5
    public static let minCount = 3
    public static let maxAgeDays = 30

    /// 使えた回の数
    public var count: Int
    /// 中央の値と幅（CEFR の数値）
    public var center: Double
    public var low: Double
    public var high: Double
    /// 観点ごとの中央値（測れた観点だけ）
    public var axes: [(key: String, value: Double)]
    /// 音声で測った回があるか（無ければ発音・流暢さは「まだ測れていない」）
    public var hasAudio: Bool

    public static func == (a: AssessSummary, b: AssessSummary) -> Bool {
        a.count == b.count && a.center == b.center && a.low == b.low && a.high == b.high && a.hasAudio == b.hasAudio
            && a.axes.map(\.key) == b.axes.map(\.key) && a.axes.map(\.value) == b.axes.map(\.value)
    }

    /// いちばん低い観点
    public var weakest: (key: String, value: Double)? { axes.min { $0.value < $1.value } }

    public func cseRange(cap: Int) -> (low: Int, high: Int) {
        (min(cap, CEFRScale.cse(low)), min(cap, CEFRScale.cse(high)))
    }
}

// MARK: - 採点

public enum Assess {
    public static let version = 1
    /// これより短い回は測らない（呼びもしない）
    public static let minWords = 100
    public static let minSeconds: Double = 60

    public static let axisKeys = ["range", "accuracy", "fluency", "coherence", "pronunciation"]

    public static func axisLabel(_ key: String) -> String {
        switch key {
        case "range": return String(localized: "語彙・表現の幅")
        case "accuracy": return String(localized: "文法の正確さ")
        case "fluency": return String(localized: "流暢さ")
        case "coherence": return String(localized: "話の組み立て")
        case "pronunciation": return String(localized: "発音")
        default: return key
        }
    }

    /// 測れる長さか
    public static func measurable(words: Int, seconds: Double?) -> Bool {
        words >= minWords && (seconds == nil || seconds! >= minSeconds)
    }

    // MARK: 機械で数える

    static let fillerWords: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "eh", "hmm", "mm"]

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init).filter { !$0.isEmpty }
    }

    public static func metrics(transcript: String, seconds: Double?, fixes: Int) -> AssessMetrics {
        let all = tokens(transcript)
        let fillers = all.filter { fillerWords.contains($0) }.count
        let words = all.filter { !fillerWords.contains($0) }
        let n = words.count
        let per100 = n > 0 ? Double(fixes) / Double(n) * 100 : 0
        return AssessMetrics(words: n, seconds: seconds, fixesPer100: (per100 * 10).rounded() / 10,
                             mattr: (mattr(words) * 1000).rounded() / 1000, fillers: fillers)
    }

    /// 長さに左右されにくい語彙の多様さ（Moving-Average Type-Token Ratio）
    static func mattr(_ words: [String], window: Int = 50) -> Double {
        guard !words.isEmpty else { return 0 }
        guard words.count > window else { return Double(Set(words).count) / Double(words.count) }
        var sum = 0.0
        var counts: [String: Int] = [:]
        for w in words.prefix(window) { counts[w, default: 0] += 1 }
        sum += Double(counts.count) / Double(window)
        for i in window..<words.count {
            let out = words[i - window]
            counts[out]! -= 1
            if counts[out]! == 0 { counts[out] = nil }
            counts[words[i], default: 0] += 1
            sum += Double(counts.count) / Double(window)
        }
        return sum / Double(words.count - window + 1)
    }

    /// 100 語あたりの直しの数から見た、正確さのおおよその段（AI の採点と大きく食い違っていないかの見張り）
    static func accuracyHint(fixesPer100: Double) -> Double {
        switch fixesPer100 {
        case ..<1.5: return 5.0
        case ..<3.5: return 4.5
        case ..<6: return 4.0
        case ..<9: return 3.5
        default: return 3.0
        }
    }

    /// 機械の数字と食い違っていないか。食い違っていれば理由（平均から外す）
    public static func check(axes: [AssessAxis], metrics m: AssessMetrics) -> String? {
        if let acc = axes.first(where: { $0.key == "accuracy" })?.value {
            // 甘い方（直しが多いのに高い段）は厳しく、辛い方は緩く見る。直しの数は AI が拾い漏らすと少なく出るため
            // （2026-11-12 過去の記録 12 回で点検: 10-17 より前は more_fixes が無く直しの数が少なく出て、両側で見ると 5 回が外れた）
            let hint = accuracyHint(fixesPer100: m.fixesPer100)
            if acc - hint > 1.0 || hint - acc > 1.5 { return "accuracy \(CEFRScale.label(acc)) vs fixes/100 \(m.fixesPer100)" }
        }
        if let flu = axes.first(where: { $0.key == "fluency" })?.value, let wpm = m.wpm {
            if flu >= 5.0 && wpm < 80 { return "fluency \(CEFRScale.label(flu)) vs wpm \(Int(wpm))" }
            if flu <= 3.0 && wpm > 150 { return "fluency \(CEFRScale.label(flu)) vs wpm \(Int(wpm))" }
        }
        return nil
    }

    // MARK: 指示文

    /// システム指示。採点は温度 0・根拠の引用を必須にする
    public static func system(audio: Bool) -> String {
        var s = """
あなたは CEFR の話す力（spoken production）の採点に慣れた、厳格で公平な試験官です。
日本語を母語とする学習者が、英語で 1 人で話した録音（独り言・モノローグ）を採点します。やりとり（質疑応答）は含まれないので採点しません。

## 観点と段の目安（自分の言葉でまとめた CEFR の記述）
- range（語彙・表現の幅）: B1＝身近な話題なら言い換えながら話せるが語彙が限られる／B2＝幅広い話題で意見を述べ、言い換えの手持ちがある／C1＝広い語彙で抽象的な話題も表現でき、言葉探しがほとんど目立たない／C2＝細かいニュアンスまで正確に言い分ける
- accuracy（文法の正確さ）: B1＝よく使う型はおおむね正しいが誤りは目立つ／B2＝誤解を生む誤りはほぼ無く、自分で直せることも多い／C1＝高い正確さを保ち、誤りはまれで見つけにくい／C2＝複雑な文でも一貫して正確
- fluency（流暢さ）: B1＝言葉探しや言い直しで止まりがちだが話し続けられる／B2＝ほぼ一定の速さで話せ、長い間はあまり無い／C1＝すらすら自然に話せ、難しい話題でだけ流れが少し落ちる／C2＝言葉探しで止まることがほぼ無い
- coherence（話の組み立て）: B1＝短い要素を順につなげる／B2＝つなぎの言葉で論点をはっきり結ぶが、ややぎこちない所もある／C1＝構成がはっきりし、つなぎの表現を幅広く使いこなす／C2＝聞き手が要点を追いやすい、まとまった話を組み立てる
- pronunciation（発音）: B1＝訛りははっきりあるが概ね聞き取れる／B2＝はっきり自然で、訛りがあっても理解に支障がない／C1＝抑揚・強勢で細かい意味まで伝えられる／C2＝意図どおりに音を使い分ける

## 採点のきまり
- 段は A1, A2, B1, B1+, B2, B2+, C1, C1+, C2 のどれか。+ は「その段の上半分（次の段の手前）」
- 観点ごとに独立して判断する。1 つの観点の印象を他に引きずらない。励ましのために甘くしない
- 各観点に、根拠になった学習者の言葉を evidence に短く引用する（英語のまま 1〜2 か所・必要なら「…」で略す）。引用できないなら、その観点は level を空にする
- 書き起こしには聞き取りの誤りが混じることがある。明らかな聞き違いは減点しない
- 話題が身近すぎる・短すぎるなどで上の段の力を示す機会が無かった観点は、示された範囲で採点する（推測で上げない）
"""
        if audio {
            s += """
- 発音と流暢さは、添えた録音そのものを聞いて判断する（書き起こしからではなく）
"""
        } else {
            s += """
- 今回は文字だけで、録音はない。fluency と pronunciation は測れないので level を空にする
"""
        }
        s += """

## 出力
次の JSON だけを返す。前後に説明や ``` を付けない。
{"axes": [{"key": "range", "level": "B2+", "evidence": "（必須・空にしない）"}, {"key": "accuracy", ...}, {"key": "fluency", ...}, {"key": "coherence", ...}, {"key": "pronunciation", ...}]}
"""
        return s
    }

    public static func userMessage(transcript: String, seconds: Double?, fixes: Int) -> String {
        var lines = ["## 学習者の独り言（書き起こし）", transcript.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        if let s = seconds { lines.append("録音の長さ: \(Int(s)) 秒") }
        lines.append("参考: 添削で直した箇所の数 \(fixes)（直しの数は目安。大小で段を決めず、誤りの重さと頻度で判断する）")
        return lines.joined(separator: "\n")
    }

    /// 応答を読む。段が読めない観点・引用の無い観点は捨てる。文字だけの回は発音・流暢さを捨てる
    public static func parse(_ raw: String, audio: Bool) -> [AssessAxis]? {
        guard let json = Logic.extractJsonObject(raw), let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = obj["axes"] as? [Any] else { return nil }
        var out: [AssessAxis] = []
        for e in arr {
            guard let d = e as? [String: Any] else { continue }
            let key = Logic.asText(d["key"]), level = Logic.asText(d["level"]), ev = Logic.asText(d["evidence"])
            guard axisKeys.contains(key), CEFRScale.value(level) != nil, !ev.isEmpty else { continue }
            if !audio && (key == "fluency" || key == "pronunciation") { continue }
            if out.contains(where: { $0.key == key }) { continue }
            out.append(AssessAxis(key: key, level: CEFRScale.label(CEFRScale.value(level)!), evidence: ev))
        }
        return out.isEmpty ? nil : out
    }

    /// 採点の結果と数字から 1 回分の推定を作る
    public static func make(axes: [AssessAxis], metrics: AssessMetrics, audio: Bool) -> Assessment {
        var a = Assessment(axes: axes, metrics: metrics, mode: audio ? "audio" : "text")
        a.unstable = check(axes: axes, metrics: metrics)
        if a.overall == nil && a.unstable == nil { a.unstable = "too few axes" }
        return a
    }

    // MARK: まとめ

    /// 直近の使える回（新しい順・最大 5 回・30 日以内）から、いまの推定を出す。足りなければ nil
    public static func summary(_ sessions: [Session], now: Date = Date()) -> AssessSummary? {
        let recent = usableRecent(sessions, now: now)
        guard recent.count >= AssessSummary.minCount else { return nil }
        let overall = recent.compactMap(\.overall).sorted()
        let center = median(overall)
        // 5 回そろったら両端を 1 つずつ外した幅（1 回だけのぶれで幅が広がらないように）
        let trimmed = overall.count >= 5 ? Array(overall.dropFirst().dropLast()) : overall
        var axes: [(String, Double)] = []
        for k in axisKeys {
            let vs = recent.compactMap { a in a.axes.first { $0.key == k }?.value }
            if !vs.isEmpty { axes.append((k, median(vs.sorted()))) }
        }
        return AssessSummary(count: recent.count, center: center, low: trimmed.first!, high: trimmed.last!,
                             axes: axes, hasAudio: recent.contains { $0.mode == "audio" })
    }

    /// まとめに使える回の数（「あと何回で出るか」に使う）
    public static func usableCount(_ sessions: [Session], now: Date = Date()) -> Int { usableRecent(sessions, now: now).count }

    static func usableRecent(_ sessions: [Session], now: Date) -> [Assessment] {
        let cutoff = now.addingTimeInterval(-Double(AssessSummary.maxAgeDays) * 86400)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var out: [Assessment] = []
        for s in sessions.sorted(by: { $0.id > $1.id }) {
            guard let a = s.assessment, a.usable else { continue }
            if let d = iso.date(from: s.id) ?? plain.date(from: s.id), d < cutoff { continue }
            out.append(a)
            if out.count == AssessSummary.window { break }
        }
        return out
    }

    static func median(_ sorted: [Double]) -> Double {
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
