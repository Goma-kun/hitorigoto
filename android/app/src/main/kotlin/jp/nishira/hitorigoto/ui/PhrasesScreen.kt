package jp.nishira.hitorigoto.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import jp.nishira.hitorigoto.AppModel
import jp.nishira.hitorigoto.R
import jp.nishira.hitorigoto.core.PhraseCard
import jp.nishira.hitorigoto.core.PhraseLogic

/** 表現タブ。覚えたい表現・単語の一覧と、追加・カードで復習 */
@Composable
fun PhrasesScreen(model: AppModel, bottomInset: Dp) {
    var filter by remember { mutableStateOf("all") }
    var adding by remember { mutableStateOf(false) }
    var flashing by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf<PhraseCard?>(null) }

    val today = model.today
    val todayIds = model.todayCards().map { it.id }.toSet()
    val st = PhraseLogic.stats(model.snapshot.phrases)
    val filters = listOf("all" to R.string.filter_all, "today" to R.string.filter_today, "active" to R.string.filter_active,
        "fresh" to R.string.filter_fresh, "graduated" to R.string.filter_graduated, "word" to R.string.filter_word)
    val shown = model.snapshot.phrases.filter { p ->
        when (filter) {
            "today" -> p.id in todayIds
            "active" -> p.status == "active" && !PhraseLogic.isNew(p)
            "fresh" -> p.status == "active" && PhraseLogic.isNew(p)
            "graduated" -> p.status == "graduated"
            "word" -> p.kind == "word"
            else -> true
        }
    }.sortedWith(Comparator { a, b ->
        val ga = a.status == "graduated"; val gb = b.status == "graduated"
        if (ga != gb) return@Comparator if (ga) 1 else -1
        if (ga) return@Comparator b.added.compareTo(a.added)
        val da = a.due ?: ""; val db = b.due ?: ""
        if (da != db) return@Comparator da.compareTo(db)
        b.added.compareTo(a.added)
    })

    LazyColumn(
        Modifier.fillMaxSize().background(Hg.bg),
        contentPadding = PaddingValues(start = 12.dp, end = 12.dp, top = 12.dp, bottom = 12.dp + bottomInset),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Stat(stringResource(R.string.in_training), st.active); Stat(stringResource(R.string.untried), st.fresh); Stat(stringResource(R.string.graduated), st.graduated)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilledButton(stringResource(R.string.add_button)) { adding = true }
                    TintedButton(stringResource(R.string.flash_button), small = false) { flashing = true }
                }
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for ((key, label) in filters) ChoiceChip(stringResource(label), filter == key) { filter = key }
                }
                if (model.snapshot.phrases.isEmpty()) Note(stringResource(R.string.phrases_empty))
                else if (shown.isEmpty()) Note(stringResource(R.string.phrases_no_match))
            }
        }
        items(shown, key = { it.id }) { p ->
            PhraseRow(p, today, p.id in todayIds, onToggle = { model.toggleGraduate(p.id) }, onDelete = { confirmDelete = p })
        }
        item { Note(stringResource(R.string.phrases_rule)) }
    }

    if (adding) AddPhraseSheet(model) { adding = false }
    if (flashing) FlashSheet(model) { flashing = false }
    confirmDelete?.let { c ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            text = { Text(stringResource(R.string.delete_phrase_confirm, c.phrase), color = Hg.text) },
            confirmButton = { TextButton({ model.deletePhrase(c.id); confirmDelete = null }) { Text(stringResource(R.string.delete), color = Hg.bad) } },
            dismissButton = { TextButton({ confirmDelete = null }) { Text(stringResource(R.string.cancel), color = Hg.muted) } },
        )
    }
}

@Composable
private fun Stat(label: String, n: Int) {
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(label, color = Hg.muted, fontSize = 12.sp, fontWeight = FontWeight.Bold)
        Text("$n", color = Hg.text, fontSize = 12.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun PhraseRow(card: PhraseCard, today: String, isToday: Boolean, onToggle: () -> Unit, onDelete: () -> Unit) {
    val c = Hg
    val shape = RoundedCornerShape(10.dp)
    Column(
        Modifier.fillMaxWidth().alpha(if (card.status == "graduated") 0.65f else 1f).clip(shape).background(c.card)
            .border(1.dp, if (isToday) c.accent.copy(alpha = 0.6f) else c.line, shape).padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(card.phrase, color = c.text, fontSize = 15.sp, fontWeight = FontWeight.Bold)
            if (card.kind == "word") Tag(stringResource(R.string.word), c.info, c.info.copy(alpha = 0.15f))
        }
        if (card.meaning.isNotEmpty() || card.note.isNotEmpty())
            Text(if (card.meaning.isEmpty()) "✗ ${card.note}" else card.meaning, color = c.muted, fontSize = 12.sp)
        Row(verticalAlignment = Alignment.CenterVertically) {
            val marks = PhraseLogic.marks(card)
            Text(if (marks.isEmpty()) stringResource(R.string.untried) else marks, color = c.muted, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                letterSpacing = if (marks.isEmpty()) 0.sp else 2.sp)
            Spacer(Modifier.weight(1f))
            val (text, color) = dueLabel(card, today)
            Text(text, color = color, fontSize = 12.sp, fontWeight = FontWeight.Bold)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.End)) {
            TintedButton(stringResource(if (card.status == "graduated") R.string.back_to_training else R.string.mark_graduated), color = c.muted, onClick = onToggle)
            TintedButton(stringResource(R.string.delete), color = c.muted, onClick = onDelete)
        }
    }
}

@Composable
private fun dueLabel(card: PhraseCard, today: String): Pair<String, Color> {
    val c = Hg
    if (card.status == "graduated") return stringResource(R.string.graduated) to c.good
    val due = card.due ?: return "" to c.faint
    val n = PhraseLogic.daysBetween(today, due)
    return when {
        n < 0 -> pluralStringResource(R.plurals.due_overdue, -n, -n) to c.warn
        n == 0 -> stringResource(R.string.due_today) to c.accent
        n == 1 -> stringResource(R.string.due_tomorrow) to c.faint
        else -> pluralStringResource(R.plurals.due_days, n, n) to c.faint
    }
}

@Composable
fun hgFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = Hg.accent, unfocusedBorderColor = Hg.line, cursorColor = Hg.accent,
    focusedTextColor = Hg.text, unfocusedTextColor = Hg.text, focusedLabelColor = Hg.accent, unfocusedLabelColor = Hg.muted,
    focusedPlaceholderColor = Hg.faint, unfocusedPlaceholderColor = Hg.faint, focusedContainerColor = Hg.card, unfocusedContainerColor = Hg.card,
)

/** 追加（1 件ずつ／まとめて） */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddPhraseSheet(model: AppModel, onClose: () -> Unit) {
    var phrase by remember { mutableStateOf("") }
    var meaning by remember { mutableStateOf("") }
    var kind by remember { mutableStateOf("phrase") }
    var bulk by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("") }
    val addedMsg = stringResource(R.string.added); val enterMsg = stringResource(R.string.enter_phrase); val dupMsg = stringResource(R.string.already_in)
    val res = LocalContext.current.resources
    ModalBottomSheet(onDismissRequest = onClose, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = Hg.bg) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).navigationBarsPadding().padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.add_phrase_title), color = Hg.text, fontSize = 17.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                TextButton(onClose) { Text(stringResource(R.string.close), color = Hg.accent) }
            }
            SettingsSection(header = stringResource(R.string.one_at_a_time)) {
                OutlinedTextField(phrase, { phrase = it }, label = { Text(stringResource(R.string.phrase)) }, placeholder = { Text(stringResource(R.string.phrase_example)) },
                    singleLine = true, colors = hgFieldColors(), modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false))
                OutlinedTextField(meaning, { meaning = it }, label = { Text(stringResource(R.string.meaning)) }, placeholder = { Text(stringResource(R.string.meaning_example)) },
                    singleLine = true, colors = hgFieldColors(), modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp))
                Row(Modifier.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.kind), color = Hg.text, fontSize = 15.sp)
                    Spacer(Modifier.width(4.dp))
                    ChoiceChip(stringResource(R.string.kind_phrase), kind == "phrase") { kind = "phrase" }
                    ChoiceChip(stringResource(R.string.kind_word), kind == "word") { kind = "word" }
                }
                Row(Modifier.padding(vertical = 6.dp)) {
                    FilledButton(stringResource(R.string.add_short), enabled = phrase.isNotBlank()) {
                        if (model.addPhrase(phrase, meaning, kind)) { status = addedMsg; phrase = ""; meaning = "" }
                        else status = if (phrase.isBlank()) enterMsg else dupMsg
                    }
                }
            }
            SettingsSection(header = stringResource(R.string.add_several), footer = stringResource(R.string.add_several_hint)) {
                OutlinedTextField(bulk, { bulk = it }, colors = hgFieldColors(), minLines = 4, modifier = Modifier.fillMaxWidth().heightIn(min = 110.dp).padding(vertical = 4.dp),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false))
                Row(Modifier.padding(vertical = 6.dp)) {
                    FilledButton(stringResource(R.string.add_several), enabled = bulk.isNotBlank()) {
                        val n = model.addBulk(bulk, kind)
                        status = res.getQuantityString(R.plurals.added_n, n, n); bulk = ""
                    }
                }
            }
            if (status.isNotEmpty()) Text(status, color = Hg.accent, fontSize = 15.sp)
        }
    }
}

/** カードで復習（意味を見て、英語で言えるか自分で確かめる） */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FlashSheet(model: AppModel, onClose: () -> Unit) {
    val cards = remember { model.snapshot.phrases.filter { it.status == "active" && it.meaning.isNotEmpty() }.sortedBy { it.due ?: "" } }
    var i by remember { mutableIntStateOf(0) }
    var open by remember { mutableStateOf(false) }
    var ok by remember { mutableIntStateOf(0) }
    var ng by remember { mutableIntStateOf(0) }
    ModalBottomSheet(onDismissRequest = onClose, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = Hg.bg) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).navigationBarsPadding().padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.flash_title), color = Hg.text, fontSize = 17.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                TextButton(onClose) { Text(stringResource(R.string.cancel), color = Hg.accent) }
            }
            if (cards.isEmpty()) {
                Text(stringResource(R.string.flash_empty), color = Hg.muted, fontSize = 15.sp)
            } else if (i >= cards.size) {
                Face {
                    Text(stringResource(R.string.flash_done, ok, ng), color = Hg.text, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                    Text(stringResource(R.string.flash_done_note), color = Hg.muted, fontSize = 12.sp)
                }
                FilledButton(stringResource(R.string.back_to_list), onClick = onClose)
            } else {
                val c = cards[i]
                Text("${i + 1} / ${cards.size}", color = Hg.faint, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                Face {
                    Text(c.meaning, color = Hg.text, fontSize = 19.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                    if (open) Text(c.phrase, color = Hg.accent, fontSize = 22.sp, fontWeight = FontWeight.ExtraBold, textAlign = TextAlign.Center)
                    else Text(stringResource(R.string.flash_say_first, languageName(model.targetLanguage)), color = Hg.faint, fontSize = 12.sp, textAlign = TextAlign.Center)
                }
                if (open) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilledButton(stringResource(R.string.said_it), Modifier.weight(1f), color = Hg.good) { model.recall(c.id, true); ok++; i++; open = false }
                        FilledButton(stringResource(R.string.missed), Modifier.weight(1f), color = Hg.bad) { model.recall(c.id, false); ng++; i++; open = false }
                    }
                } else {
                    FilledButton(stringResource(R.string.flash_reveal), Modifier.fillMaxWidth()) { open = true }
                }
            }
        }
    }
}

@Composable
private fun Face(content: @Composable () -> Unit) {
    val shape = RoundedCornerShape(14.dp)
    Column(
        Modifier.fillMaxWidth().heightIn(min = 140.dp).clip(shape).background(Hg.card).border(1.dp, Hg.line, shape).padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterVertically),
    ) { content() }
}
