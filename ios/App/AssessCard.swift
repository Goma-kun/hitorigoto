import SwiftUI

/// 話す力の推定のカード（履歴の一番上・2026-11-12 第 1 段階）。押すものではないので、矢印やボタンの見た目は付けない
struct AssessCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let goal = model.assessGoal
        if let sum = model.assessSummary {
            Card(title: String(localized: "話す力の推定（直近 \(sum.count) 回）")) {
                filled(sum, goal: goal)
            }
        } else {
            Card(title: String(localized: "話す力の推定")) {
                let left = max(0, AssessSummary.minCount - model.assessUsableCount)
                Text(String(localized: "あと \(left) 回話すと出ます"))
                    .font(.headline).foregroundStyle(Theme.text)
                Note(text: String(localized: "英語で 60 秒以上・100 語以上話した回を、添削のあとに裏で測ります。目標は「\(goal.label)」（設定で変えられます）。"))
                if model.assessing != nil { Note(text: String(localized: "いま、今回の分を測っています…")) }
            }
        }
    }

    @ViewBuilder
    private func filled(_ sum: AssessSummary, goal: AssessGoal) -> some View {
        let r = sum.cseRange(cap: goal.maxCSE)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(r.low == r.high ? "\(r.low)" : "\(r.low)〜\(r.high)")
                .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Theme.text)
            Text(String(localized: "CSE（Speaking）")).font(.caption).foregroundStyle(Theme.muted)
            Spacer()
            Text("CEFR \(CEFRScale.label(sum.center))").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
        }
        ScaleBar(low: r.low, high: r.high, pass: goal.passCSE, lower: goal.passCSE - 200, upper: goal.maxCSE)
            .frame(height: 22)
        Text(gap(r, goal: goal)).font(.subheadline).foregroundStyle(r.low >= goal.passCSE ? Theme.good : Theme.text)
        if let w = sum.weakest {
            Text(String(localized: "伸ばしどころ: \(Assess.axisLabel(w.key))（\(CEFRScale.label(w.value))）"))
                .font(.subheadline).foregroundStyle(Theme.text)
        }
        if !sum.hasAudio { Note(text: String(localized: "発音と流暢さは、まだ測れていません。")) }
        Note(text: String(localized: "独り言の録音からの推定です。面接のやりとり（質疑応答）は入っていません。本番の点の代わりにはなりません。"))
        if model.assessing != nil { Note(text: String(localized: "いま、今回の分を測っています…")) }
    }

    private func gap(_ r: (low: Int, high: Int), goal: AssessGoal) -> String {
        let line = String(localized: "\(goal.label)の合格ライン \(goal.passCSE)")
        if r.low >= goal.passCSE { return line + String(localized: "：届いています") }
        if r.high >= goal.passCSE { return line + String(localized: "：届くかどうかの境目です") }
        let a = goal.passCSE - r.high, b = goal.passCSE - r.low
        return line + (a == b ? String(localized: "：あと \(a)") : String(localized: "：あと \(a)〜\(b)"))
    }
}

/// 横棒: 推定の幅を塗り、合格ラインに縦線を引く
private struct ScaleBar: View {
    let low: Int, high: Int, pass: Int, lower: Int, upper: Int

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x = { (v: Int) -> CGFloat in
                CGFloat(min(max(v, lower), upper) - lower) / CGFloat(max(1, upper - lower)) * w
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line).frame(height: 8)
                Capsule().fill(Theme.accent)
                    .frame(width: max(8, x(high) - x(low)), height: 8)
                    .offset(x: min(x(low), w - 8))
                Rectangle().fill(Theme.text).frame(width: 2, height: 22).offset(x: x(pass) - 1)
            }
            .frame(height: 22)
        }
    }
}
