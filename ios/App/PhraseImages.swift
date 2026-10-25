import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 表現カードに付ける「元のスクショ」の置き場。
///
/// - 端末の Application Support/Hitorigoto/phrase-images/ に JPEG で置く。記録（snapshot.json）には名前だけを持つ
/// - iCloud には表現カードのレコードに**添付ファイル（CKAsset）**として付けて送る（CloudSync）。
///   記録の JSON に画像を混ぜないので、同期の重さは変わらない（Anki の media と同じ考え方）
/// - 名前は中身の指紋から作る。同じ画像を 2 回入れても 1 枚、2 台で同じ名前になる
enum PhraseImages {

    /// 保存するときの長い辺（px）。スクショ（縦 2,796px）を 1,600px に縮め、文字は読めるまま 1 枚 150〜250KB ほど
    static let storeMaxPixel = 1600
    /// Gemini に渡すときの長い辺。読み取りの精度を落とさない大きさ
    static let sendMaxPixel = 2000

    static var directory: URL? {
        guard let dir = try? SnapshotStore.defaultURL().deletingLastPathComponent()
            .appendingPathComponent("phrase-images", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(_ name: String) -> URL? {
        // 名前は自分で作ったものだけを受け付ける（同期で届いた名前でフォルダの外を指させない）
        guard name.range(of: #"^img-[0-9a-f]{16,64}\.jpg$"#, options: .regularExpression) != nil else { return nil }
        return directory?.appendingPathComponent(name)
    }

    static func exists(_ name: String) -> Bool {
        guard let u = url(name) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    /// 画像（どの形式でも）を縮めて保存し、名前を返す
    static func store(_ data: Data) -> String? {
        guard let jpeg = jpeg(data, maxPixel: storeMaxPixel, quality: 0.7) else { return nil }
        let digest = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        let name = "img-\(digest.prefix(32)).jpg"
        guard let u = url(name) else { return nil }
        if !FileManager.default.fileExists(atPath: u.path) {
            guard (try? jpeg.write(to: u, options: .atomic)) != nil else { return nil }
        }
        return name
    }

    /// 同期で届いた添付ファイルを、決まった名前で置く
    static func adopt(_ file: URL, as name: String) {
        guard let u = url(name), !FileManager.default.fileExists(atPath: u.path) else { return }
        try? FileManager.default.copyItem(at: file, to: u)
    }

    /// どのカードからも指されなくなった画像を消す（表現を消したとき）
    static func prune(keeping names: Set<String>) {
        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for f in files where f.hasPrefix("img-") && !names.contains(f) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    /// 縮めて JPEG にする。ImageIO だけで済ませる（iPhone と Mac で同じ処理）。向きは EXIF のとおりに直す
    static func jpeg(_ data: Data, maxPixel: Int, quality: Double) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }

    /// 画面に出す Image。ファイルが無ければ nil（相手の端末からまだ届いていない）
    static func image(_ name: String) -> Image? {
        guard let u = url(name) else { return nil }
        return image(contentsOf: u)
    }

    static func image(contentsOf u: URL) -> Image? {
        #if os(iOS)
        guard let ui = UIImage(contentsOfFile: u.path) else { return nil }
        return Image(uiImage: ui)
        #else
        guard let ns = NSImage(contentsOf: u) else { return nil }
        return Image(nsImage: ns)
        #endif
    }

    static func image(data: Data) -> Image? {
        #if os(iOS)
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #else
        guard let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
        #endif
    }

    /// クリップボードの画像（スクショの「コピーして削除」のあとなど）
    static func pasteboardImage() -> Data? {
        #if os(iOS)
        if let d = UIPasteboard.general.data(forPasteboardType: UTType.png.identifier) { return d }
        if let d = UIPasteboard.general.data(forPasteboardType: UTType.jpeg.identifier) { return d }
        return UIPasteboard.general.image?.pngData()
        #else
        let pb = NSPasteboard.general
        if let d = pb.data(forType: .png) { return d }
        if let d = pb.data(forType: .tiff) { return d }
        return nil
        #endif
    }

    static var pasteboardHasImage: Bool {
        #if os(iOS)
        return UIPasteboard.general.hasImages
        #else
        return NSPasteboard.general.canReadItem(withDataConformingToTypes: [UTType.png.identifier, UTType.tiff.identifier])
        #endif
    }
}

/// 共有シート（HitorigotoShare）で受け取ったスクショの受け箱。
/// 共有拡張とアプリはプロセスが別なので、App Group の共有フォルダに置いて渡す。
/// **受け取った側では読み取りまでしない**（共有拡張は使える時間とメモリが短い）。アプリを開いたときにまとめて読む
enum ScreenshotInbox {
    static let groupID = "group.jp.nishira.hitorigoto"

    static var directory: URL? {
        #if os(iOS)
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        let dir = base.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
        #else
        return nil
        #endif
    }

    /// 届いた順（古い順）
    static func files() -> [URL] {
        guard let dir = directory,
              let list = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        return list.filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
