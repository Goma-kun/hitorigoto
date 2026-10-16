import Foundation
import CloudKit

/// iCloud 同期の状態（設定画面に出す）
enum SyncStatus: Equatable {
    case off                  // 設定で切っている
    case starting
    case noAccount            // iCloud にサインインしていない
    case syncing
    case synced(Date)
    case failed(String)
}

/// iCloud（CloudKit の非公開データベース）で、同じ Apple アカウントの iPhone と Mac の記録を揃える。
///
/// - データは利用者自身の iCloud に入る。開発者からは見えず、サーバー代もかからない
/// - 記録の分け方と混ぜ方は HitorigotoCore の `Sync`（テストあり）。ここは CloudKit とのやり取りだけ
/// - 送るかどうかは「サーバーにあると分かっている中身の指紋（known）」と今の記録を比べて決める。
///   届いたものを混ぜた結果が届いたものと違えば、混ぜた結果を送り返す（2 台が同じ記録に落ち着く）
/// - **iCloud が使えなくても記録は端末に残る**。同期は上乗せで、失敗しても練習は止めない
final class CloudSync: CKSyncEngineDelegate, @unchecked Sendable {

    static let containerID = "iCloud.jp.nishira.hitorigoto"
    static let zone = CKRecordZone(zoneName: "Hitorigoto")
    static let field = "json"

    /// 端末に残す同期の控え（記録そのものとは別ファイル）
    private struct State: Codable {
        var engine: CKSyncEngine.State.Serialization?
        /// レコード名 → サーバーにある中身の指紋
        var known: [String: String] = [:]
        /// レコード名 → CloudKit の管理情報（次に送るときに「どの版を書き換えるか」を伝えるため）
        var fields: [String: Data] = [:]
    }

    private weak var model: AppModel?
    private var state: State
    private let stateURL: URL?
    private let container: CKContainer
    private var engine: CKSyncEngine!

    @MainActor
    init(model: AppModel) {
        self.model = model
        stateURL = try? SnapshotStore.defaultURL().deletingLastPathComponent().appendingPathComponent("sync.json")
        state = stateURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        container = CKContainer(identifier: Self.containerID)
        var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                stateSerialization: state.engine, delegate: self)
        config.automaticallySync = true
        engine = CKSyncEngine(config)
        if state.engine == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(Self.zone)])
        }
        model.syncStatus = .starting
        localChanged(model.snapshot)
        Task { await self.checkAccount() }
    }

    // MARK: - 端末の記録が変わった

    /// 端末で記録が変わるたびに呼ぶ。サーバーと違うものだけを送る予定に入れる
    @MainActor
    func localChanged(_ snapshot: Snapshot) {
        let items = Sync.items(snapshot)
        let pending = Set(engine.state.pendingRecordZoneChanges)
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for (name, item) in items where state.known[name] != item.hash {
            let c = CKSyncEngine.PendingRecordZoneChange.saveRecord(Self.recordID(name))
            if !pending.contains(c) { changes.append(c) }
        }
        for name in state.known.keys where items[name] == nil {
            let c = CKSyncEngine.PendingRecordZoneChange.deleteRecord(Self.recordID(name))
            if !pending.contains(c) { changes.append(c) }
        }
        if !changes.isEmpty { engine.state.add(pendingRecordZoneChanges: changes) }
    }

    /// アプリが前に出たとき。相手の端末の変更を取りに行き、溜まっている分を送る
    func syncNow() {
        Task {
            try? await engine.fetchChanges()
            try? await engine.sendChanges()
        }
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let e):
            await MainActor.run { state.engine = e.stateSerialization; persist() }

        case .accountChange(let e):
            await MainActor.run {
                switch e.changeType {
                case .signIn, .switchAccounts:
                    // 新しいアカウントには何も無いものとして、手元の記録を全部送り直す
                    resetAndResend()
                case .signOut:
                    // サインアウトしても手元の記録は消さない（同期の控えだけ捨てる）
                    state.known = [:]; state.fields = [:]; persist()
                    model?.syncStatus = .noAccount
                @unknown default:
                    break
                }
            }

        case .fetchedDatabaseChanges(let e):
            // 利用者が iCloud の設定から独り言のデータを消した。手元の記録から作り直す
            if e.deletions.contains(where: { $0.zoneID == Self.zone.zoneID }) {
                await MainActor.run { resetAndResend() }
            }

        case .fetchedRecordZoneChanges(let e):
            await MainActor.run {
                applyRemote(records: e.modifications.map(\.record), deletions: e.deletions.map(\.recordID.recordName))
            }

        case .sentRecordZoneChanges(let e):
            await MainActor.run { handleSent(e) }

        case .willFetchChanges, .willSendChanges:
            await MainActor.run { if model?.syncStatus != .noAccount { model?.syncStatus = .syncing } }

        case .didFetchChanges, .didSendChanges:
            await MainActor.run {
                guard let m = model else { return }
                if case .failed = m.syncStatus { return }
                if m.syncStatus != .noAccount { m.syncStatus = .synced(Date()) }
            }

        case .sentDatabaseChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break
        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        if changes.isEmpty { return nil }
        let records: [CKRecord.ID: CKRecord] = await MainActor.run {
            guard let snapshot = model?.snapshot else { return [:] }
            let items = Sync.items(snapshot)
            var out: [CKRecord.ID: CKRecord] = [:]
            for case .saveRecord(let id) in changes {
                guard let item = items[id.recordName] else { continue }
                out[id] = record(for: item, id: id)
            }
            return out
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { records[$0] }
    }

    // MARK: - 中身

    @MainActor
    private func record(for item: Sync.Item, id: CKRecord.ID) -> CKRecord {
        let r = state.fields[item.name].flatMap(Self.restore) ?? CKRecord(recordType: item.kind.rawValue, recordID: id)
        r[Self.field] = item.data as NSData
        return r
    }

    /// 相手の端末から届いたものを混ぜる。今日の表現は最後に（表現カードの id を揃えてから）
    @MainActor
    private func applyRemote(records: [CKRecord], deletions: [String]) {
        guard let model else { return }
        var s = model.snapshot
        let sorted = records.sorted { ($0.recordType == Sync.Kind.today.rawValue ? 1 : 0) < ($1.recordType == Sync.Kind.today.rawValue ? 1 : 0) }
        for r in sorted {
            guard let kind = Sync.Kind(rawValue: r.recordType), let data = r[Self.field] as? Data else { continue }
            let name = r.recordID.recordName
            state.fields[name] = Self.archive(r)
            state.known[name] = Sync.hash(data)
            s = Sync.merge(s, Sync.Item(name: name, kind: kind, data: data))
        }
        for name in deletions {
            state.known.removeValue(forKey: name); state.fields.removeValue(forKey: name)
            s = Sync.remove(s, name: name)
        }
        persist()
        // 混ぜた結果が届いたものと違えば、localChanged が送り返す予定に入れる
        model.applySynced(s)
    }

    @MainActor
    private func handleSent(_ e: CKSyncEngine.Event.SentRecordZoneChanges) {
        for r in e.savedRecords {
            let name = r.recordID.recordName
            state.fields[name] = Self.archive(r)
            if let data = r[Self.field] as? Data { state.known[name] = Sync.hash(data) }
        }
        for id in e.deletedRecordIDs {
            state.known.removeValue(forKey: id.recordName); state.fields.removeValue(forKey: id.recordName)
        }
        var conflicts: [CKRecord] = []
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        var needZone = false
        for f in e.failedRecordSaves {
            let id = f.record.recordID
            switch f.error.code {
            case .serverRecordChanged:
                // 相手の端末が先に書いていた。サーバーの中身と混ぜて送り直す
                if let server = f.error.serverRecord { conflicts.append(server) }
                retry.append(.saveRecord(id))
            case .zoneNotFound:
                needZone = true
                state.fields.removeValue(forKey: id.recordName)
                retry.append(.saveRecord(id))
            case .unknownItem:
                // サーバーで消えていた。新しく作り直す
                state.fields.removeValue(forKey: id.recordName)
                state.known.removeValue(forKey: id.recordName)
                retry.append(.saveRecord(id))
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated,
                 .operationCancelled, .requestRateLimited:
                break   // CKSyncEngine がまた送る
            case .quotaExceeded:
                model?.syncStatus = .failed(String(localized: "iCloud の容量がいっぱいで同期できません。記録はこの端末に残っています。"))
            default:
                model?.syncStatus = .failed(f.error.localizedDescription)
            }
        }
        if needZone { engine.state.add(pendingDatabaseChanges: [.saveZone(Self.zone)]) }
        if !retry.isEmpty { engine.state.add(pendingRecordZoneChanges: retry) }
        persist()
        if !conflicts.isEmpty { applyRemote(records: conflicts, deletions: []) }
    }

    @MainActor
    private func resetAndResend() {
        state.known = [:]; state.fields = [:]
        engine.state.add(pendingDatabaseChanges: [.saveZone(Self.zone)])
        persist()
        if let m = model { localChanged(m.snapshot) }
    }

    private func checkAccount() async {
        let status = try? await container.accountStatus()
        await MainActor.run {
            if status != .available { model?.syncStatus = .noAccount }
        }
        if status == .available { syncNow() }
    }

    @MainActor
    private func persist() {
        guard let url = stateURL, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 同期の控えを捨てる（設定で同期を切ったとき。次に入れたら全部を突き合わせ直す）
    @MainActor
    static func forget() {
        guard let url = try? SnapshotStore.defaultURL().deletingLastPathComponent().appendingPathComponent("sync.json") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zone.zoneID) }

    static func archive(_ r: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        r.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func restore(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
