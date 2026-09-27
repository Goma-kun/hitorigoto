// swift-tools-version: 5.9
import PackageDescription

// 独り言の iPhone / Mac アプリ用。拡張機能の extension/english-core.js と phrase-core.js を
// そのまま移した層。UI は持たない。ここが拡張と同じ答えを返すことを ../test/parity_swift_test.mjs で突き合わせる。
let package = Package(
    name: "HitorigotoCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HitorigotoCore", targets: ["HitorigotoCore"]),
    ],
    targets: [
        .target(name: "HitorigotoCore"),
        // JS 版と答えを突き合わせるための入口。JSON を受けて JSON を返すだけ。
        // `--review` を付けると本物の Gemini に音声かテキストを投げる（実 API の確認用）
        .executableTarget(name: "hg-probe", dependencies: ["HitorigotoCore"]),
        .testTarget(name: "HitorigotoCoreTests", dependencies: ["HitorigotoCore"]),
    ]
)
