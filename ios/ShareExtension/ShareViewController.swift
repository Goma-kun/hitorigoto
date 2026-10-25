import UIKit
import UniformTypeIdentifiers
import ImageIO

/// 共有シートの「独り言」。スクショ（画像）を受け取って App Group の受け箱に置くだけ。
///
/// **ここでは読み取らない。** 共有拡張は使えるメモリと時間が短く、通信の途中で閉じられることがある。
/// 受け取ったらすぐ元のアプリ（Distinction など）に戻れるようにし、読むのはアプリを開いたとき（ScanSheet）
final class ShareViewController: UIViewController {

    private static let groupID = "group.jp.nishira.hitorigoto"
    /// 受け箱に置く大きさ。アプリ側で読み取る前にもう一度縮めるので、ここは文字が潰れない大きさにとどめる
    private static let maxPixel = 2400

    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)

        let card = UIView()
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 16
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        label.text = String(localized: "受け取っています…")
        label.font = .preferredFont(forTextStyle: .body)
        label.numberOfLines = 0
        label.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        spinner.startAnimating()

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 280),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { @MainActor in
            let n = await receive()
            spinner.stopAnimating()
            spinner.isHidden = true
            if n > 0 {
                label.text = String(localized: "スクショを \(n) 枚受け取りました。\n独り言を開くと、表現の候補にします。")
            } else {
                label.text = String(localized: "画像を受け取れませんでした。")
            }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// 画像をすべて受け箱に置く。置けた枚数を返す
    private func receive() async -> Int {
        guard let inbox = Self.inbox() else { return 0 }
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        var saved = 0
        for (i, p) in providers.prefix(10).enumerated() {
            guard let data = await Self.load(p), let jpeg = Self.jpeg(data) else { continue }
            // 名前は届いた順に並ぶように（時刻＋連番）
            let name = String(format: "%.0f-%02d-%@.jpg", Date().timeIntervalSince1970 * 1000, i, UUID().uuidString.prefix(8) as CVarArg)
            if (try? jpeg.write(to: inbox.appendingPathComponent(name), options: .atomic)) != nil { saved += 1 }
        }
        return saved
    }

    private static func inbox() -> URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        let dir = base.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// スクショの編集画面から来ると UIImage、写真アプリからだとファイル、のように形が違うので全部受ける
    private static func load(_ p: NSItemProvider) async -> Data? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                switch item {
                case let url as URL: cont.resume(returning: try? Data(contentsOf: url))
                case let data as Data: cont.resume(returning: data)
                case let img as UIImage: cont.resume(returning: img.pngData())
                default: cont.resume(returning: nil)
                }
            }
        }
    }

    private static func jpeg(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }
}
