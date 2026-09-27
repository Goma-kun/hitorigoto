import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 拡張機能の sidepanel.html と同じ色（ダーク）。**同じ製品に見えることが大事。**
/// ライトはアプリ版だけの話。前景（tint）と背景（bg）を分けて持つ（うながすくんのダーク対応で学んだ型）
enum Theme {
    static let bg        = dynamic(light: 0xF4F4F8, dark: 0x0F172A)
    static let card      = dynamic(light: 0xFFFFFF, dark: 0x1E293B)
    static let line      = dynamic(light: 0xE2E4EC, dark: 0x334155)
    static let text      = dynamic(light: 0x1E2233, dark: 0xE2E8F0)
    static let muted     = dynamic(light: 0x6B7280, dark: 0x94A3B8)
    static let faint     = dynamic(light: 0x9CA3AF, dark: 0x64748B)
    /// 紫のアクセント（拡張の #a78bfa）。ライトでは少し濃く
    static let accent    = dynamic(light: 0x7C3AED, dark: 0xA78BFA)
    static let accentBg  = dynamic(light: 0xEDE9FE, dark: 0x2A2450)
    static let good      = dynamic(light: 0x15803D, dark: 0x4ADE80)
    static let goodBg    = dynamic(light: 0xDCFCE7, dark: 0x14301F)
    static let warn      = dynamic(light: 0xB45309, dark: 0xFBBF24)
    static let warnBg    = dynamic(light: 0xFEF3C7, dark: 0x3A2F0F)
    static let bad       = dynamic(light: 0xB91C1C, dark: 0xF87171)
    static let badBg     = dynamic(light: 0xFEE2E2, dark: 0x3B1414)
    static let info      = dynamic(light: 0x0369A1, dark: 0x38BDF8)
    static let rec       = dynamic(light: 0xDC2626, dark: 0xEF4444)

    static let tint = accent

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if os(iOS)
        return Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #endif
    }
}

#if os(iOS)
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// カード（拡張の .en-section / .history-card）
struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.caption.weight(.bold)).foregroundStyle(Theme.faint)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }
}

/// 小さなラベル（拡張の .en-badge / .ph-today-tag）
struct Tag: View {
    let text: String
    var fg: Color = Theme.muted
    var bg: Color = Theme.line.opacity(0.5)

    var body: some View {
        Text(text).font(.caption2.weight(.bold)).foregroundStyle(fg)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// 説明の小さな灰色の文（拡張の .en-note）
struct Note: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// ◎△✗− の色。画面のどこでも同じ色にする
enum Mark {
    static func symbol(_ r: String) -> String { ["hit": "◎", "partial": "△", "miss": "✗", "skip": "−", "rok": "○", "rng": "×"][r] ?? "" }
    static func color(_ r: String) -> Color {
        switch r {
        case "hit": return Theme.good
        case "partial": return Theme.warn
        case "miss": return Theme.bad
        default: return Theme.faint
        }
    }
    static func bg(_ r: String) -> Color {
        switch r {
        case "hit": return Theme.goodBg
        case "partial": return Theme.warnBg
        case "miss": return Theme.badBg
        default: return Theme.line.opacity(0.4)
        }
    }
}
