import Foundation

/// 記録の入れ物。**拡張機能の chrome.storage.local と同じ形のまま持つ。**
/// 書き出し／読み込み（hitorigoto-english-v1）が拡張機能とそのまま行き来できる
public struct Snapshot: Codable, Equatable, Sendable {
    public var sessions: [Session]
    public var recurring: [Recurring]
    public var phrases: [PhraseCard]
    public var today: Today?

    public init(sessions: [Session] = [], recurring: [Recurring] = [], phrases: [PhraseCard] = [], today: Today? = nil) {
        self.sessions = sessions; self.recurring = recurring; self.phrases = phrases; self.today = today
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        recurring = try c.decodeIfPresent([Recurring].self, forKey: .recurring) ?? []
        phrases = try c.decodeIfPresent([PhraseCard].self, forKey: .phrases) ?? []
        today = try c.decodeIfPresent(Today.self, forKey: .today)
    }
}

/// 書き出しファイル（拡張機能の exportEnglishJson と同じ形）
public struct ExportFile: Codable, Sendable {
    public var format: String
    public var exportedAt: String
    public var sessions: [Session]
    public var recurring: [Recurring]
    public var phrases: [PhraseCard]?

    enum CodingKeys: String, CodingKey { case format, exportedAt = "exported_at", sessions, recurring, phrases }

    public static let format = "hitorigoto-english-v1"
    public static let acceptedFormats = ["hitorigoto-english-v1", "mamorukun-english-v1"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        exportedAt = try c.decodeIfPresent(String.self, forKey: .exportedAt) ?? ""
        sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        recurring = try c.decodeIfPresent([Recurring].self, forKey: .recurring) ?? []
        phrases = try c.decodeIfPresent([PhraseCard].self, forKey: .phrases)
    }

    public init(snapshot: Snapshot, at date: Date = Date()) {
        format = Self.format
        exportedAt = ISO8601DateFormatter().string(from: date)
        sessions = snapshot.sessions
        recurring = snapshot.recurring
        phrases = snapshot.phrases
    }
}

public enum ImportError: Error { case notJson, badFormat }

public enum Merge {
    static func normKey(_ s: String) -> String { Logic.collapseSpaces(s.lowercased()) }

    /// 同じ id のセッションは二重に増やさない。新しい順を保つ
    public static func sessions(_ current: [Session], _ incoming: [Session]) -> [Session] {
        let seen = Set(current.map { $0.id })
        let added = incoming.filter { !$0.id.isEmpty && !seen.contains($0.id) }
        return (current + added).sorted { $0.id > $1.id }
    }

    /// 同じ文言なら回数の大きい方
    public static func recurring(_ current: [Recurring], _ incoming: [Recurring]) -> [Recurring] {
        var order: [String] = []
        var map: [String: Recurring] = [:]
        for r in current { let k = normKey(r.text); if map[k] == nil { order.append(k) }; map[k] = r }
        for r in incoming {
            if r.text.isEmpty { continue }
            let k = normKey(r.text)
            if var cur = map[k] {
                cur.count = max(cur.count, r.count)
                if r.lastSeen > cur.lastSeen { cur.lastSeen = r.lastSeen }
                map[k] = cur
            } else { order.append(k); map[k] = r }
        }
        return order.compactMap { map[$0] }
    }

    /// 同じ表現なら履歴の長い方
    public static func phrases(_ current: [PhraseCard], _ incoming: [PhraseCard]) -> [PhraseCard] {
        var order: [String] = []
        var map: [String: PhraseCard] = [:]
        for p in current { let k = normKey(p.phrase); if map[k] == nil { order.append(k) }; map[k] = p }
        for p in incoming {
            if p.phrase.isEmpty { continue }
            let k = normKey(p.phrase)
            if let cur = map[k] {
                if p.history.count > cur.history.count { map[k] = p }
            } else { order.append(k); map[k] = p }
        }
        return order.compactMap { map[$0] }.map(PhraseLogic.rebuild)
    }

    /// 読み込み。混ぜたあとの記録と、追加されたセッション数を返す
    public static func importJson(_ data: Data, into snapshot: Snapshot) throws -> (snapshot: Snapshot, addedSessions: Int) {
        guard let file = try? JSONDecoder().decode(ExportFile.self, from: data) else { throw ImportError.notJson }
        guard ExportFile.acceptedFormats.contains(file.format) else { throw ImportError.badFormat }
        var out = snapshot
        let before = out.sessions.count
        out.sessions = sessions(out.sessions, file.sessions)
        out.recurring = recurring(out.recurring, file.recurring)
        out.phrases = phrases(out.phrases, file.phrases ?? [])
        return (out, out.sessions.count - before)
    }
}

/// 端末のディスクに置く。Application Support の中の 1 ファイル
public final class SnapshotStore {
    private let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let dir = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true)
            .appendingPathComponent("Hitorigoto", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snapshot.json")
    }

    public func load() throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return Snapshot() }
        var s = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        // 読み込んだ表現は履歴から状態を組み立て直す（取り込んだ JSON の due や hits が古くても正しくなる）
        s.phrases = s.phrases.map(PhraseLogic.rebuild)
        return s
    }

    public func save(_ snapshot: Snapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        let tmp = url.deletingLastPathComponent().appendingPathComponent("snapshot.tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
