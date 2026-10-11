package jp.nishira.hitorigoto.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.LibraryBooks
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import jp.nishira.hitorigoto.AppModel
import jp.nishira.hitorigoto.PendingRecording
import jp.nishira.hitorigoto.R
import jp.nishira.hitorigoto.Recorder
import jp.nishira.hitorigoto.SilentFixes
import jp.nishira.hitorigoto.core.Ask
import jp.nishira.hitorigoto.core.Feedback
import jp.nishira.hitorigoto.core.Issue
import jp.nishira.hitorigoto.core.Judged
import jp.nishira.hitorigoto.core.Logic
import jp.nishira.hitorigoto.core.PhraseCard
import jp.nishira.hitorigoto.core.PhraseLogic
import jp.nishira.hitorigoto.core.Recurring
import jp.nishira.hitorigoto.core.Session
import jp.nishira.hitorigoto.core.TargetLanguage
import kotlinx.coroutines.delay
import java.text.DateFormat
import java.util.Calendar
import java.util.Date

/**
 * 話すタブ。拡張機能の「話す」パネル・iOS の SpeakView と同じ並び：
 * 話す前＝挨拶と今日の表現＋また出やがった点 → 録音中＝字幕 → 添削中 → 結果
 */
@Composable
fun SpeakScreen(model: AppModel, goPhrases: () -> Unit, onStart: () -> Unit, bottomInset: androidx.compose.ui.unit.Dp) {
    Column(Modifier.fillMaxSize().background(Hg.bg)) {
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            model.errorMessage?.let { e -> Card { Text(e, color = Hg.bad, fontSize = 15.sp) } }
            // 画面の文字はどこでも選んでコピーできるようにする（指摘・理由・褒め言葉も）
            SelectionContainer {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    when (model.phase) {
                        AppModel.Phase.IDLE -> IdleBody(model, goPhrases)
                        AppModel.Phase.RECORDING -> RecordingBody(model.recorder)
                        AppModel.Phase.REVIEWING -> Card {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                CircularProgressIndicator(Modifier.size(20.dp), color = Hg.accent, strokeWidth = 2.dp)
                                Text(stringResource(R.string.reviewing_body), color = Hg.muted, fontSize = 15.sp)
                            }
                        }
                        AppModel.Phase.RESULT -> ResultBody(model)
                    }
                }
            }
        }
        ActionBar(model, onStart, bottomInset)
    }
}

// ---- 話す前 ----

@Composable
private fun IdleBody(model: AppModel, goPhrases: () -> Unit) {
    var confirmDiscard by remember { mutableStateOf(false) }
    model.pending?.let { p ->
        Card(title = stringResource(R.string.pending_title)) {
            Text(pendingLabel(p), color = Hg.text, fontSize = 15.sp, fontWeight = FontWeight.Bold)
            if (p.transcript.isNotEmpty()) Text(p.transcript, color = Hg.muted, fontSize = 12.sp, maxLines = 3)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilledButton(stringResource(R.string.send_again), small = true) { model.review() }
                TintedButton(stringResource(R.string.discard), color = Hg.muted, small = false) { confirmDiscard = true }
            }
            Note(stringResource(R.string.pending_note))
        }
        if (confirmDiscard) AlertDialog(
            onDismissRequest = { confirmDiscard = false },
            text = { Text(stringResource(R.string.pending_discard_confirm), color = Hg.text) },
            confirmButton = { TextButton({ confirmDiscard = false; model.discardPending() }) { Text(stringResource(R.string.discard), color = Hg.bad) } },
            dismissButton = { TextButton({ confirmDiscard = false }) { Text(stringResource(R.string.cancel), color = Hg.muted) } },
        )
    }
    model.reviewBlocker?.let { why -> Card { Text(why, color = Hg.text, fontSize = 15.sp) } }
    Welcome(model)
    TodayCard(model, goPhrases)
    val recurring = Logic.topRecurring(model.snapshot.recurring, limit = 3)
    if (recurring.isNotEmpty()) {
        Card(title = stringResource(R.string.recurring_today)) { for (r in recurring) RecurringRow(r) }
    }
}

@Composable
fun pendingLabel(p: PendingRecording): String {
    val f = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
    val mmss = String.format("%d:%02d", p.seconds / 60, p.seconds % 60)
    return stringResource(R.string.pending_label, f.format(Date(p.date)), mmss)
}

/** 話す言語の短い名前（「英語で話すだけ」など） */
@Composable
fun languageName(l: TargetLanguage): String = when (l) {
    TargetLanguage.EN_US, TargetLanguage.EN_GB -> stringResource(R.string.name_english)
    TargetLanguage.ES_ES, TargetLanguage.ES_MX -> stringResource(R.string.name_spanish)
    TargetLanguage.JA_JP -> stringResource(R.string.name_japanese)
}

/** 話す前のいちばん上。挨拶と「話す → AI が聞く → 直しが届く」の絵。何が起きるアプリなのかを、読まなくても分かるようにする */
@Composable
private fun Welcome(model: AppModel) {
    val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
    val greeting = stringResource(when (hour) { in 5..10 -> R.string.greeting_morning; in 11..17 -> R.string.greeting_day; else -> R.string.greeting_evening })
    val n = model.snapshot.sessions.size
    val sub = if (n == 0) stringResource(R.string.sub_first, languageName(model.targetLanguage)) else pluralStringResource(R.plurals.sub_rounds, n, n)
    Column(Modifier.fillMaxWidth().padding(vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            // 誰が添削してくれるのかを顔で見せる。コーチの名前は寅吉（トラキチ）、呼ぶときは「トラさん」
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Image(
                    painterResource(R.drawable.coach), contentDescription = stringResource(R.string.coach_name), contentScale = ContentScale.Crop,
                    modifier = Modifier.size(76.dp).clip(CircleShape).border(2.dp, Hg.accent.copy(alpha = 0.6f), CircleShape),
                )
                Text(stringResource(R.string.coach_name), color = Hg.muted, fontSize = 11.sp, fontWeight = FontWeight.Bold)
            }
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(greeting, color = Hg.text, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                Text(sub, color = Hg.muted, fontSize = 15.sp)
            }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Step(Modifier.weight(1f), Icons.Filled.Mic, stringResource(R.string.step_speak), Hg.accent, Hg.accentBg)
            Arrow()
            Step(Modifier.weight(1f), Icons.Filled.AutoAwesome, stringResource(R.string.step_ai), Hg.warn, Hg.warnBg)
            Arrow()
            Step(Modifier.weight(1f), Icons.Outlined.CheckCircle, stringResource(R.string.step_fixes), Hg.good, Hg.goodBg)
        }
    }
}

@Composable
private fun Step(modifier: Modifier, icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, fg: Color, bg: Color) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(56.dp).clip(CircleShape).background(bg), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = fg, modifier = Modifier.size(26.dp))
        }
        Text(label, color = Hg.text, fontSize = 12.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
    }
}

@Composable
private fun Arrow() {
    Box(Modifier.height(56.dp), contentAlignment = Alignment.Center) {
        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = Hg.faint, modifier = Modifier.size(16.dp))
    }
}

/** 話す前の「今日の表現」 */
@Composable
private fun TodayCard(model: AppModel, goPhrases: () -> Unit) {
    val cards = model.todayCards()
    Card(title = stringResource(R.string.today_phrases)) {
        if (cards.isEmpty()) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.size(44.dp).clip(CircleShape).background(Hg.accentBg), contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.LibraryBooks, contentDescription = null, tint = Hg.accent, modifier = Modifier.size(22.dp))
                }
                Text(stringResource(if (model.snapshot.phrases.isEmpty()) R.string.today_empty_add else R.string.today_empty_none),
                    color = Hg.text, fontSize = 15.sp, modifier = Modifier.weight(1f))
                FilledButton(stringResource(R.string.add_short), small = true, onClick = goPhrases)
            }
        } else {
            cards.forEachIndexed { i, c ->
                if (i > 0) Line()
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(c.phrase, color = Hg.text, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                        if (c.meaning.isNotEmpty() || c.note.isNotEmpty())
                            Text(if (c.meaning.isEmpty()) "✗ ${c.note}" else c.meaning, color = Hg.muted, fontSize = 12.sp)
                        val marks = PhraseLogic.marks(c)
                        if (marks.isNotEmpty()) Text(marks, color = Hg.muted, fontSize = 12.sp, letterSpacing = 2.sp)
                    }
                    // 真似して口に出すための読み上げ（端末の声。通信もお金もかからない）
                    SpeakButton(model, c.phrase)
                    TodayTag(c)
                    TintedButton(stringResource(R.string.skip), color = Hg.muted) { model.skipToday(c.id) }
                }
            }
            Note(pluralStringResource(R.plurals.today_note, cards.size, cards.size))
        }
    }
}

@Composable
private fun TodayTag(c: PhraseCard) {
    val last = PhraseLogic.lastSpeechResult(c)
    when {
        PhraseLogic.isNew(c) -> Tag(stringResource(R.string.tag_new), Hg.good, Hg.goodBg)
        last == "miss" || last == "partial" -> Tag(stringResource(R.string.tag_retry), Hg.warn, Hg.warnBg)
        else -> Tag(stringResource(R.string.tag_again))
    }
}

/** 繰り返し指摘の 1 行。回数と、最後に出た日を添える */
@Composable
fun RecurringRow(item: Recurring) {
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Text("• ${item.text}", color = Hg.text, fontSize = 15.sp)
        Text(pluralStringResource(R.plurals.times_last, item.count, item.count, shortDate(item.lastSeen)), color = Hg.faint, fontSize = 12.sp, modifier = Modifier.padding(start = 12.dp))
    }
}

/** "2026-09-28" → "9/28" */
fun shortDate(ymd: String): String {
    val p = ymd.split("-")
    if (p.size != 3) return ymd
    val m = p[1].toIntOrNull() ?: return ymd; val d = p[2].toIntOrNull() ?: return ymd
    return "$m/$d"
}

// ---- 録音中 ----

@Composable
private fun RecordingBody(recorder: Recorder) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.size(10.dp).clip(CircleShape).background(Hg.rec))
        Text(String.format("%d:%02d", recorder.seconds / 60, recorder.seconds % 60), color = Hg.text, fontSize = 19.sp, fontWeight = FontWeight.Bold)
        LevelBar(recorder.level, Modifier.weight(1f))
    }
    val micDetail = recorder.inputName + (if (recorder.inputDetail.isEmpty()) "" else "・${recorder.inputDetail}")
    if (recorder.micSilent) {
        MicSilentWarning(micDetail)
    } else if (recorder.inputName.isNotEmpty()) {
        Note(stringResource(R.string.mic_label, recorder.inputName) + (if (recorder.inputDetail.isEmpty()) "" else "（${recorder.inputDetail}）"))
    }
    if (recorder.engineNote.isNotEmpty()) Text(recorder.engineNote, color = Hg.warn, fontSize = 12.sp)
    // 字幕は消さずに積む（全部残っていたほうが見返せる）
    val live = recorder.transcript + recorder.interim
    if (live.isEmpty()) {
        Note(stringResource(if (recorder.captionsAvailable) R.string.listening else R.string.recording_no_captions))
    } else {
        Text(live, color = Hg.text, fontSize = 16.sp, lineHeight = 24.sp, modifier = Modifier.fillMaxWidth())
    }
}

/** 音の大きさ。声が入っていることを見せるためだけ */
@Composable
private fun LevelBar(level: Float, modifier: Modifier = Modifier) {
    Box(modifier.height(6.dp).clip(CircleShape).background(Hg.line)) {
        Box(Modifier.fillMaxWidth(level.coerceIn(0.03f, 1f)).height(6.dp).clip(CircleShape).background(Hg.accent))
    }
}

/** マイクから音が来ていないときの知らせ。無音のまま最後まで話してしまうのを防ぐ */
@Composable
private fun MicSilentWarning(inputName: String) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(Hg.warnBg).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(stringResource(R.string.mic_silent_title), color = Hg.warn, fontSize = 16.sp, fontWeight = FontWeight.Bold)
        Text(if (inputName.isEmpty()) stringResource(R.string.mic_silent_body) else stringResource(R.string.mic_silent_body_named, inputName), color = Hg.text, fontSize = 14.sp)
    }
}

// ---- 結果 ----

@Composable
private fun ResultBody(model: AppModel) {
    val fb = model.latest ?: return
    val c = Hg
    if (fb.good.isNotEmpty()) Card(title = stringResource(R.string.good_title)) { Text(fb.good, color = Hg.good, fontSize = 15.sp) }
    // 結果を丸ごと持ち出す（チャットに貼って台本にする型）。履歴の「コピー（指摘つき）」と同じ本文
    CopyButton(Logic.buildSessionText(model.latestSession ?: Session(id = ""), sessionLabels()), label = stringResource(R.string.copy_all))
    if (model.latestJudged.isNotEmpty()) TodayResultCard(model, model.latestJudged)
    Card(title = stringResource(R.string.fix_these)) {
        if (fb.issues.isEmpty()) Note(stringResource(R.string.no_issues))
        else fb.issues.forEachIndexed { i, it -> if (i > 0) Line(); IssueRow(model, it) }
    }
    val silent = SilentFixes.find(fb.transcript, fb.correctedText, fb.issues, wordSpaces = !model.targetLanguage.hasNoWordSpaces, asks = fb.asks)
    if (silent.isNotEmpty()) {
        Card(title = stringResource(R.string.silent_fixes_title)) {
            for (f in silent) {
                Text(buildAnnotatedString {
                    withStyle(SpanStyle(color = c.bad, textDecoration = TextDecoration.LineThrough)) { append(f.from) }
                    withStyle(SpanStyle(color = c.faint)) { append("  →  ") }
                    withStyle(SpanStyle(color = c.good, fontWeight = FontWeight.Bold)) { append(f.to) }
                }, fontSize = 12.sp)
            }
            Note(stringResource(R.string.silent_fixes_note))
        }
    }
    if (fb.recurring.isNotEmpty()) Card(title = stringResource(R.string.recurring_short)) { for (r in fb.recurring) Text("• $r", color = Hg.text, fontSize = 15.sp) }
    if (fb.asks.isNotEmpty()) {
        // 日本語で言った分（英語が出てこなかったところ）→ 英語ならこう。友だちに聞いた答えなので叱る枠ではない
        Card(title = stringResource(R.string.asks_title)) {
            fb.asks.forEachIndexed { i, a ->
                if (i > 0) Line()
                AskRow(model, a)
            }
            Note(stringResource(R.string.asks_note))
        }
    }
    if (fb.pronunciation.isNotEmpty()) {
        Card(title = stringResource(R.string.pron_title)) {
            fb.pronunciation.forEachIndexed { i, p ->
                if (i > 0) Line()
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(p.said, color = Hg.good, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                        Text("→", color = Hg.faint)
                        Text(p.heardAs, color = Hg.warn, fontSize = 15.sp)
                    }
                    if (p.note.isNotEmpty()) Text(p.note, color = Hg.muted, fontSize = 12.sp)
                }
            }
            Note(stringResource(R.string.pron_note))
        }
    }
    if (fb.recognitionDoubt.isNotEmpty()) {
        Card(title = stringResource(R.string.doubt_title)) {
            for (d in fb.recognitionDoubt) Text("• $d", color = Hg.muted, fontSize = 15.sp)
            Note(stringResource(R.string.doubt_note))
        }
    }
    if (fb.correctedText.isNotEmpty()) {
        Card(title = stringResource(R.string.corrected_title)) {
            Row(verticalAlignment = Alignment.Top) {
                Text(fb.correctedText, color = Hg.text, fontSize = 16.sp, lineHeight = 24.sp, modifier = Modifier.weight(1f))
                SpeakButton(model, fb.correctedText)
            }
            CopyButton(fb.correctedText)
        }
    }
    if (fb.transcript.isNotEmpty()) {
        Card(title = stringResource(R.string.transcript_title)) { Text(fb.transcript, color = Hg.muted, fontSize = 15.sp, lineHeight = 22.sp) }
    }
    Note(stringResource(R.string.result_footnote))
}

/** 履歴・結果のコピー本文の見出し（表示言語に合わせる） */
@Composable
fun sessionLabels() = Logic.Labels(
    corrected = stringResource(R.string.label_corrected), issues = stringResource(R.string.fix_these), good = stringResource(R.string.good_title),
    said = stringResource(R.string.label_said), pron = stringResource(R.string.pron_title),
    asks = stringResource(R.string.asks_title),
    types = mapOf("phrasing" to stringResource(R.string.type_phrasing), "vocabulary" to stringResource(R.string.type_vocabulary), "grammar" to stringResource(R.string.type_grammar)),
)

/** 「日本語で言った分 → 英語ならこう」1 件。言い方ごとに読み上げと「表現集へ」 */
@Composable
fun AskRow(model: AppModel, ask: Ask) {
    val c = Hg
    var added by remember(ask) { mutableStateOf(setOf<String>()) }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(ask.said, color = c.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        ask.ways.forEachIndexed { i, w ->
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(if (i == 0) "→" else "　", color = c.faint)
                Text(w, color = c.good, fontSize = 15.sp, fontWeight = if (i == 0) FontWeight.Bold else FontWeight.Normal, modifier = Modifier.weight(1f))
                SpeakButton(model, w)
                val exists = w in added || model.hasPhrase(w)
                TextButton(onClick = { if (model.addFromAsk(ask, w)) added = added + w }, enabled = !exists) {
                    Text(stringResource(if (exists) R.string.added_check else R.string.add_to_phrases), fontSize = 12.sp)
                }
            }
        }
        if (ask.note.isNotEmpty()) Text(ask.note, color = c.muted, fontSize = 12.sp)
    }
}

/** 添削のあとの「今日の表現の結果」。記号をタップして直せる */
@Composable
private fun TodayResultCard(model: AppModel, judged: List<Judged>) {
    val c = Hg
    Card(title = stringResource(R.string.today_results)) {
        judged.forEachIndexed { i, j ->
            val card = model.snapshot.phrases.firstOrNull { it.id == j.id } ?: return@forEachIndexed
            if (i > 0) Line()
            val tr = model.todayResult(j.id)
            val r = tr?.r ?: j.result
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(
                    Modifier.size(34.dp).clip(RoundedCornerShape(8.dp)).background(Mark.bg(c, r))
                        .border(1.dp, Mark.color(c, r).copy(alpha = 0.5f), RoundedCornerShape(8.dp))
                        .clickable { model.cycleTodayResult(j.id) },
                    contentAlignment = Alignment.Center,
                ) { Text(Mark.symbol(r), color = Mark.color(c, r), fontSize = 19.sp, fontWeight = FontWeight.Bold) }
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(card.phrase, color = Hg.text, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                    val asSaid = tr?.asSaid ?: j.asSaid
                    val asSaidPrefix = stringResource(R.string.as_said_prefix)
                    if (asSaid.isNotEmpty() && PhraseLogic.phraseKey(asSaid) != PhraseLogic.phraseKey(card.phrase)) {
                        Text(buildAnnotatedString {
                            withStyle(SpanStyle(color = c.muted)) { append(asSaidPrefix) }
                            withStyle(SpanStyle(color = c.text, fontWeight = FontWeight.Bold)) { append(asSaid) }
                        }, fontSize = 12.sp)
                    }
                    val note = tr?.note ?: j.note
                    if (note.isNotEmpty()) Text(note, color = Hg.muted, fontSize = 12.sp)
                }
            }
        }
        Note(stringResource(R.string.today_results_note))
    }
}

/** 指摘 1 件（拡張の .en-issue） */
@Composable
fun IssueRow(model: AppModel, issue: Issue) {
    val c = Hg
    var added by remember(issue) { mutableStateOf(false) }
    val typeLabel = stringResource(when (issue.type) { "vocabulary" -> R.string.type_vocabulary; "grammar" -> R.string.type_grammar; else -> R.string.type_phrasing })
    val typeColor = when (issue.type) { "vocabulary" -> c.info; "grammar" -> c.warn; else -> c.muted }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Tag(typeLabel, typeColor, typeColor.copy(alpha = 0.15f))
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(buildAnnotatedString {
                withStyle(SpanStyle(color = c.bad, textDecoration = TextDecoration.LineThrough)) { append(issue.original ?: "") }
                withStyle(SpanStyle(color = c.faint)) { append("  →  ") }
                withStyle(SpanStyle(color = c.good, fontWeight = FontWeight.Bold)) { append(issue.suggestion) }
            }, fontSize = 15.sp, lineHeight = 22.sp, modifier = Modifier.weight(1f))
            // 読み上げるのは**直されたあとの形**だけ。間違えた形を耳に入れても仕方がない
            SpeakButton(model, issue.suggestion)
        }
        if (!issue.reason.isNullOrEmpty()) Text(issue.reason!!, color = Hg.muted, fontSize = 12.sp, lineHeight = 17.sp)
        val exists = added || model.hasPhrase(issue.suggestion)
        Row { TintedButton(stringResource(if (exists) R.string.added_check else R.string.add_to_phrases), color = if (exists) c.good else c.accent, enabled = !exists) { if (model.addFromIssue(issue)) added = true } }
    }
}

// ---- 下のボタン ----

/**
 * 画面の下の「開始／停止」。**録音アプリの定石どおり、大きな丸ひとつにしてある**。
 * 丸の周りは空けておく。ここだけが押す場所だと目で分かるのが大事なので、隣に何も置かない
 */
@Composable
private fun ActionBar(model: AppModel, onStart: () -> Unit, bottomInset: androidx.compose.ui.unit.Dp) {
    val c = Hg
    val phase = model.phase
    val color by animateColorAsState(when (phase) { AppModel.Phase.RECORDING -> c.rec; AppModel.Phase.REVIEWING -> c.faint; else -> c.accent }, label = "mic")
    val label = stringResource(when (phase) { AppModel.Phase.RECORDING -> R.string.mic_stop; AppModel.Phase.REVIEWING -> R.string.mic_reviewing; else -> R.string.mic_start })
    val hint = when (phase) {
        AppModel.Phase.RECORDING -> stringResource(R.string.hint_recording)
        AppModel.Phase.REVIEWING -> stringResource(R.string.hint_reviewing)
        else -> stringResource(R.string.hint_idle, languageName(model.targetLanguage))
    }
    val blocked = stringResource(R.string.pending_blocks_start)
    Column(Modifier.fillMaxWidth().background(Hg.bg)) {
        Line()
        Column(Modifier.fillMaxWidth().padding(top = 14.dp, bottom = 10.dp + bottomInset), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Box(
                Modifier.size(96.dp).shadow(if (phase == AppModel.Phase.RECORDING) 14.dp else 8.dp, CircleShape, ambientColor = color, spotColor = color)
                    .clip(CircleShape).background(color)
                    .clickable(enabled = phase != AppModel.Phase.REVIEWING) {
                        when (phase) {
                            AppModel.Phase.RECORDING -> model.stopAndReview()
                            AppModel.Phase.REVIEWING -> {}
                            else -> if (model.pending != null) model.errorMessage = blocked else onStart()
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Icon(if (phase == AppModel.Phase.RECORDING) Icons.Filled.Stop else Icons.Filled.Mic, contentDescription = label, tint = Color.White, modifier = Modifier.size(34.dp))
                    Text(label, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                }
            }
            Text(hint, color = Hg.muted, fontSize = 12.sp)
            if (phase == AppModel.Phase.IDLE || phase == AppModel.Phase.RESULT) {
                // 話す前に、どのマイクで録るかを見せる。イヤホンは後からつながるので、数秒おきに見直す
                var mic by remember { mutableStateOf(model.recorder.currentInputName()) }
                LaunchedEffect(Unit) { while (true) { delay(2000); mic = model.recorder.currentInputName() } }
                if (mic.isNotEmpty()) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(Icons.Outlined.Mic, contentDescription = null, tint = Hg.faint, modifier = Modifier.size(12.dp))
                    Text(mic, color = Hg.faint, fontSize = 11.sp)
                }
            }
        }
    }
}
