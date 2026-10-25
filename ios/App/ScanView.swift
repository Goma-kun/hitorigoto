import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ScanFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// スクショから表現を入れる画面。
///
/// 入り口は 3 つ: 共有シートで受け取った分（受け箱）／写真から選ぶ／貼り付け（Mac はファイルからも）。
/// 1 枚ずつ Gemini に読ませて候補を出し、**確かめてから**入れる（読み違いをそのまま表現集に入れない）。
/// 元のスクショは縮めて、そのスクショから入れたカードに付ける
struct ScanSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    struct Pick: Identifiable {
        var c: ScanCandidate
        var on: Bool
        let exists: Bool
        var id: String { c.id }
    }

    enum ReadState: Equatable { case waiting, reading, done, failed(String) }

    struct Shot: Identifiable {
        let id = UUID().uuidString
        let data: Data
        /// 受け箱から来たものは、入れ終わったら受け箱から消す
        let inbox: URL?
        var state: ReadState = .waiting
        var picks: [Pick] = []
    }

    @State private var shots: [Shot] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var reading = false
    @State private var zoomed: Shot?
    @State private var status = ""

    private var chosen: Int { shots.reduce(0) { $0 + $1.picks.filter(\.on).count } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                            Label("写真から選ぶ", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.bordered).tint(Theme.accent)
                        Button { paste() } label: { Label("貼り付け", systemImage: "doc.on.clipboard") }
                            .buttonStyle(.bordered).tint(Theme.accent)
                        #if os(macOS)
                        Button { importing = true } label: { Label("ファイルから", systemImage: "folder") }
                            .buttonStyle(.bordered).tint(Theme.accent)
                        #endif
                    }
                    Text(helpText).font(.caption).foregroundStyle(Theme.muted)
                }

                ForEach($shots) { $shot in
                    Section {
                        shotHeader(shot)
                        ForEach($shot.picks) { $p in pickRow($p) }
                    }
                }

                if !status.isEmpty { Text(status).font(.callout).foregroundStyle(Theme.accent) }
            }
            .formStyle(.grouped)
            .navigationTitle("スクショから表現").compactNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chosen > 0 ? String(localized: "\(chosen) 件を入れる") : String(localized: "入れる")) { addChosen() }
                        .disabled(chosen == 0 || reading)
                }
            }
            .onAppear(perform: loadInbox)
            .onChange(of: pickerItems) { _, items in loadPicked(items) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { r in
                guard case .success(let urls) = r else { return }
                for u in urls {
                    let ok = u.startAccessingSecurityScopedResource()
                    defer { if ok { u.stopAccessingSecurityScopedResource() } }
                    if let d = try? Data(contentsOf: u) { shots.append(Shot(data: d, inbox: nil)) }
                }
                readNext()
            }
            .sheet(item: $zoomed) { s in ZoomedShot(data: s.data) }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 600)
        #endif
    }

    private var helpText: String {
        #if os(iOS)
        return String(localized: "教材アプリや記事のスクショから、表現と意味・例文を読み取ります。ほかのアプリでスクショを撮って、共有から「独り言」を選んでも届きます。元のスクショはカードに付けて残ります。")
        #else
        return String(localized: "教材アプリや記事のスクショから、表現と意味・例文を読み取ります。元のスクショはカードに付けて残ります。")
        #endif
    }

    // MARK: - 1 枚ぶん

    @ViewBuilder
    private func shotHeader(_ shot: Shot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let img = PhraseImages.image(data: shot.data) {
                img.resizable().scaledToFit()
                    .frame(width: 56, height: 100, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                    .onTapGesture { zoomed = shot }
            }
            VStack(alignment: .leading, spacing: 6) {
                switch shot.state {
                case .waiting:
                    Text("順番を待っています").font(.callout).foregroundStyle(Theme.muted)
                case .reading:
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("読み取っています…").font(.callout).foregroundStyle(Theme.muted) }
                case .done:
                    Text(shot.picks.isEmpty ? String(localized: "表現が見つかりませんでした") : String(localized: "\(shot.picks.count) 件見つかりました。入れるものに印を付けてください"))
                        .font(.callout).foregroundStyle(Theme.muted)
                case .failed(let m):
                    Text(m).font(.callout).foregroundStyle(Theme.warn)
                    Button("もう一度読む") { retry(shot.id) }.buttonStyle(.bordered).controlSize(.small)
                }
                Button("このスクショは使わない", role: .destructive) { drop(shot.id) }
                    .buttonStyle(.borderless).controlSize(.small).font(.caption)
            }
            Spacer(minLength: 0)
        }
    }

    private func pickRow(_ p: Binding<Pick>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { p.wrappedValue.on.toggle() } label: {
                Image(systemName: p.wrappedValue.on ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(p.wrappedValue.on ? Theme.accent : Theme.faint)
            }
            .buttonStyle(.plain)
            .disabled(p.wrappedValue.exists)
            VStack(alignment: .leading, spacing: 4) {
                TextField("表現", text: p.c.phrase)
                    .font(.callout.weight(.bold))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if p.wrappedValue.exists {
                    Text("もう表現集に入っています").font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
                }
                TextField("意味", text: p.c.meaning, axis: .vertical)
                    .font(.callout).lineLimit(1...6)
                if !p.wrappedValue.c.example.isEmpty {
                    TextField("例文", text: p.c.example, axis: .vertical)
                        .font(.caption).foregroundStyle(Theme.muted).lineLimit(1...8)
                }
            }
        }
        .opacity(p.wrappedValue.exists ? 0.55 : 1)
    }

    // MARK: - 入れ方

    private func loadInbox() {
        let have = Set(shots.compactMap(\.inbox))
        for u in ScreenshotInbox.files() where !have.contains(u) {
            if let d = try? Data(contentsOf: u) { shots.append(Shot(data: d, inbox: u)) }
        }
        readNext()
    }

    private func loadPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for it in items {
                if let d = try? await it.loadTransferable(type: Data.self) { shots.append(Shot(data: d, inbox: nil)) }
            }
            pickerItems = []
            readNext()
        }
    }

    private func paste() {
        guard let d = PhraseImages.pasteboardImage() else { status = String(localized: "クリップボードに画像がありません"); return }
        status = ""
        shots.append(Shot(data: d, inbox: nil))
        readNext()
    }

    /// 待っている分を 1 枚ずつ順に読む（並べて投げると中継サーバーの回数をまとめて食うので、順番に）
    private func readNext() {
        guard !reading, let i = shots.firstIndex(where: { $0.state == .waiting }) else { return }
        reading = true
        let id = shots[i].id, data = shots[i].data
        shots[i].state = .reading
        Task {
            let r = await model.scanScreenshot(data)
            if let k = shots.firstIndex(where: { $0.id == id }) {
                switch r {
                case .success(let cands):
                    shots[k].picks = cands.map { c in
                        let exists = model.hasPhrase(c.phrase)
                        return Pick(c: c, on: !exists, exists: exists)
                    }
                    shots[k].state = .done
                case .failure(let f):
                    shots[k].state = .failed(f.message)
                }
            }
            reading = false
            readNext()
        }
    }

    private func retry(_ id: String) {
        guard let i = shots.firstIndex(where: { $0.id == id }) else { return }
        shots[i].state = .waiting
        readNext()
    }

    private func drop(_ id: String) {
        guard let i = shots.firstIndex(where: { $0.id == id }) else { return }
        if let u = shots[i].inbox { ScreenshotInbox.remove(u) }
        shots.remove(at: i)
        model.refreshInbox()
    }

    private func addChosen() {
        var added = 0
        for s in shots where s.state == .done {
            let items = s.picks.filter(\.on).map(\.c)
            if !items.isEmpty { added += model.addScanned(items, image: s.data) }
            // 読み終えて確かめた分は受け箱から消す（印を付けなかったものも、見たうえで入れなかったもの）
            if let u = s.inbox { ScreenshotInbox.remove(u) }
        }
        shots.removeAll { $0.state == .done }
        model.refreshInbox()
        status = String(localized: "\(added) 件入れました")
        if shots.isEmpty { dismiss() }
    }
}

/// スクショを大きく見る（指で拡大）
struct ZoomedShot: View {
    @Environment(\.dismiss) private var dismiss
    let image: Image?

    init(data: Data) { image = PhraseImages.image(data: data) }
    init(name: String) { image = PhraseImages.image(name) }

    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                if let image {
                    image.resizable().scaledToFit()
                        .frame(maxWidth: .infinity)
                        .scaleEffect(scale, anchor: .top)
                        .gesture(MagnifyGesture().onChanged { scale = min(4, max(1, $0.magnification)) })
                } else {
                    Text("スクショがまだこの端末に届いていません").foregroundStyle(Theme.muted).padding()
                }
            }
            .background(Theme.bg)
            .navigationTitle("元のスクショ").compactNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 640)
        #endif
    }
}
