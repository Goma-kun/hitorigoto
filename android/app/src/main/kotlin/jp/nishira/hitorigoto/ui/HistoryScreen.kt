package jp.nishira.hitorigoto.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import jp.nishira.hitorigoto.AppModel
import jp.nishira.hitorigoto.R
import jp.nishira.hitorigoto.SilentFixes
import jp.nishira.hitorigoto.core.Issue
import jp.nishira.hitorigoto.core.Logic
import jp.nishira.hitorigoto.core.Session
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** 履歴タブ。拡張機能の履歴パネルと同じ（繰り返し → セッションのカード） */
@Composable
fun HistoryScreen(model: AppModel, bottomInset: Dp) {
    val recurring = Logic.topRecurring(model.snapshot.recurring)
    LazyColumn(
        Modifier.fillMaxSize().background(Hg.bg),
        contentPadding = PaddingValues(start = 12.dp, end = 12.dp, top = 12.dp, bottom = 12.dp + bottomInset),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (recurring.isNotEmpty()) item {
            // 何の一覧かと、いつのことかが分かるようにする
            Card(title = stringResource(R.string.recurring_history)) {
                for (r in recurring) RecurringRow(r)
                Note(stringResource(R.string.recurring_history_note))
            }
        }
        if (model.snapshot.sessions.isEmpty()) item { Note(stringResource(R.string.history_empty)) }
        items(model.snapshot.sessions, key = { it.id }) { s -> SelectionContainer { SessionCard(model, s) } }
    }
}

@Composable
private fun SessionCard(model: AppModel, session: Session) {
    var expanded by remember { mutableStateOf(false) }
    val labels = sessionLabels()
    Card {
        Text(dateLabel(session.id) + "　" + pluralStringResource(R.plurals.corrections_count, session.issues.size, session.issues.size),
            color = Hg.faint, fontSize = 12.sp, fontWeight = FontWeight.Bold)
        if (session.folded == true) {
            val lines = session.issues.map { it.suggestion }.filter { it.isNotEmpty() }
            Text(if (lines.isEmpty()) stringResource(R.string.old_record) else lines.joinToString(" / "), color = Hg.muted, fontSize = 15.sp)
        } else {
            val body = session.correctedText ?: session.transcript ?: ""
            Text(body, color = Hg.text, fontSize = 15.sp, lineHeight = 22.sp, maxLines = if (expanded) Int.MAX_VALUE else 4, overflow = TextOverflow.Ellipsis)
            if (body.length > 120) Row { TintedButton(stringResource(if (expanded) R.string.collapse else R.string.full_text)) { expanded = !expanded } }
            if (session.issues.isNotEmpty()) {
                Text(stringResource(R.string.fix_these), color = Hg.faint, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                for (it in session.issues) {
                    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("• ${it.original ?: ""} → ${it.suggestion}" + (if (it.reason.isNullOrEmpty()) "" else " — ${it.reason}"),
                            color = Hg.text, fontSize = 12.sp, lineHeight = 17.sp, modifier = Modifier.weight(1f))
                        AddIssueButton(model, it)
                    }
                }
            }
            val more = session.moreFixes
            if (!more.isNullOrEmpty()) {
                // コーチが理由つきで挙げた残りの直し（2026-10-17 から）
                Text(stringResource(R.string.more_fixes_title), color = Hg.faint, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                for (f in more) Text("• ${f.original} → ${f.suggestion}" + (if (f.note.isEmpty()) "" else " — ${f.note}"), color = Hg.text, fontSize = 12.sp, lineHeight = 17.sp)
            }
            val silent = SilentFixes.find(session.transcript ?: "", session.correctedText ?: "", session.issues + (session.moreFixes ?: emptyList()).map { it.asIssue }, wordSpaces = !model.targetLanguage.hasNoWordSpaces, asks = session.asks ?: emptyList())
            if (silent.isNotEmpty()) {
                Text(stringResource(R.string.silent_fixes_title), color = Hg.faint, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                for (f in silent) Text("• ${f.from} → ${f.to}", color = Hg.text, fontSize = 12.sp, lineHeight = 17.sp)
            }
            val pron = session.pronunciation
            if (!pron.isNullOrEmpty()) {
                Text(stringResource(R.string.pron_title), color = Hg.faint, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                for (p in pron) Text("• ${p.said} → ${p.heardAs}" + (if (p.note.isEmpty()) "" else " — ${p.note}"), color = Hg.text, fontSize = 12.sp, lineHeight = 17.sp)
            }
            val asks = session.asks
            if (!asks.isNullOrEmpty()) {
                Text(stringResource(R.string.asks_title), color = Hg.faint, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                for (a in asks) Text("• ${a.said} → ${a.ways.joinToString(" / ")}", color = Hg.text, fontSize = 12.sp, lineHeight = 17.sp)
            }
            val t = session.targets
            if (!t.isNullOrEmpty()) {
                Text(stringResource(R.string.today_results), color = Hg.faint, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                for (x in t) Text("${Mark.symbol(x.r)} ${x.phrase}" + (if (x.asSaid.isNotEmpty() && x.r != "hit") "（${x.asSaid}）" else ""), color = Hg.text, fontSize = 12.sp, lineHeight = 17.sp)
            }
        }
        CopyButton(Logic.buildSessionText(session, labels), label = stringResource(R.string.copy_with_issues))
    }
}

@Composable
private fun AddIssueButton(model: AppModel, issue: Issue) {
    var added by remember(issue) { mutableStateOf(false) }
    val exists = added || model.hasPhrase(issue.suggestion)
    TintedButton(if (exists) "✓" else "＋", color = if (exists) Hg.good else Hg.accent, enabled = !exists) { if (model.addFromIssue(issue)) added = true }
}

private val dateFmt = DateTimeFormatter.ofPattern("M/d HH:mm")

/** セッション id（ISO 日時・UTC）→ 端末の時刻で "9/28 21:05" */
fun dateLabel(id: String): String = try {
    dateFmt.format(Instant.parse(id).atZone(ZoneId.systemDefault()))
} catch (e: Exception) { id }
