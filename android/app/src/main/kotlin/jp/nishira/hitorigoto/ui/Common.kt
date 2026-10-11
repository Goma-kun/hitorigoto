package jp.nishira.hitorigoto.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.automirrored.outlined.VolumeUp
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import jp.nishira.hitorigoto.AppModel
import jp.nishira.hitorigoto.R
import kotlinx.coroutines.delay

/** カード（拡張の .en-section / .history-card・iOS の Card） */
@Composable
fun Card(title: String? = null, modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val shape = RoundedCornerShape(12.dp)
    Column(
        modifier = modifier.fillMaxWidth().clip(shape).background(Hg.card).border(1.dp, Hg.line, shape).padding(12.dp),
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp),
    ) {
        if (title != null) Text(title, color = Hg.faint, fontSize = 12.sp, fontWeight = FontWeight.Bold)
        content()
    }
}

/** 小さなラベル（拡張の .en-badge / .ph-today-tag） */
@Composable
fun Tag(text: String, fg: Color = Hg.muted, bg: Color = Hg.line.copy(alpha = 0.5f)) {
    Text(
        text, color = fg, fontSize = 11.sp, fontWeight = FontWeight.Bold,
        modifier = Modifier.clip(RoundedCornerShape(5.dp)).background(bg).padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

/** 説明の小さな灰色の文（拡張の .en-note） */
@Composable
fun Note(text: String, color: Color = Hg.faint) {
    Text(text, color = color, fontSize = 12.sp, lineHeight = 17.sp, modifier = Modifier.fillMaxWidth())
}

/** 1px の区切り線 */
@Composable
fun Line() { Box(Modifier.fillMaxWidth().height(1.dp).background(Hg.line)) }

/** 塗りのボタン（iOS の borderedProminent） */
@Composable
fun FilledButton(text: String, modifier: Modifier = Modifier, color: Color = Hg.accent, enabled: Boolean = true, small: Boolean = false, onClick: () -> Unit) {
    Box(
        modifier = modifier.clip(RoundedCornerShape(9.dp)).background(if (enabled) color else color.copy(alpha = 0.45f))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = if (small) 12.dp else 16.dp, vertical = if (small) 7.dp else 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = Color.White, fontSize = if (small) 13.sp else 15.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** 薄い地のボタン（iOS の bordered） */
@Composable
fun TintedButton(text: String, modifier: Modifier = Modifier, color: Color = Hg.accent, enabled: Boolean = true, small: Boolean = true, onClick: () -> Unit) {
    Box(
        modifier = modifier.clip(RoundedCornerShape(8.dp)).background(color.copy(alpha = if (enabled) 0.14f else 0.07f))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = if (small) 10.dp else 14.dp, vertical = if (small) 6.dp else 9.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = color.copy(alpha = if (enabled) 1f else 0.5f), fontSize = if (small) 13.sp else 15.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** 選ぶチップ（表現の絞り込みなど） */
@Composable
fun ChoiceChip(text: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        text, color = if (selected) Hg.accent else Hg.muted, fontSize = 12.sp, fontWeight = FontWeight.Bold,
        modifier = Modifier.clip(CircleShape).background(if (selected) Hg.accentBg else Color.Transparent)
            .border(1.dp, if (selected) Hg.accent else Hg.line, CircleShape)
            .clickable(onClick = onClick).padding(horizontal = 10.dp, vertical = 5.dp),
    )
}

/** 文の横に置く、小さな読み上げボタン。読み上げるのは直されたあとの形だけ */
@Composable
fun SpeakButton(model: AppModel, text: String) {
    val isSpeaking = model.speaker.speaking == text.trim()
    val desc = stringResource(R.string.read_aloud)
    Icon(
        if (isSpeaking) Icons.AutoMirrored.Filled.VolumeUp else Icons.AutoMirrored.Outlined.VolumeUp,
        contentDescription = desc, tint = if (isSpeaking) Hg.accent else Hg.muted,
        modifier = Modifier.size(32.dp).clip(CircleShape).clickable { model.speaker.toggle(text) }.padding(6.dp),
    )
}

fun copyToClipboard(context: Context, text: String) {
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    cm.setPrimaryClip(ClipData.newPlainText("hitorigoto", text))
}

@Composable
fun CopyButton(text: String, label: String = stringResource(R.string.copy), modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var done by remember { mutableStateOf(false) }
    LaunchedEffect(done) { if (done) { delay(1500); done = false } }
    Row(modifier.fillMaxWidth(), horizontalArrangement = androidx.compose.foundation.layout.Arrangement.End) {
        TintedButton(if (done) stringResource(R.string.copied) else label) { copyToClipboard(context, text); done = true }
    }
}

/** ◎△✗− の色。画面のどこでも同じ色にする */
object Mark {
    fun symbol(r: String): String = mapOf("hit" to "◎", "partial" to "△", "miss" to "✗", "skip" to "−", "rok" to "○", "rng" to "×")[r] ?: ""
    fun color(c: HgColors, r: String): Color = when (r) { "hit" -> c.good; "partial" -> c.warn; "miss" -> c.bad; else -> c.faint }
    fun bg(c: HgColors, r: String): Color = when (r) { "hit" -> c.goodBg; "partial" -> c.warnBg; "miss" -> c.badBg; else -> c.line.copy(alpha = 0.4f) }
}

/** 設定画面などの「節」。見出し＋白いカード＋脚注 */
@Composable
fun SettingsSection(header: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        if (header != null) Text(header, color = Hg.muted, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 4.dp, bottom = 6.dp))
        val shape = RoundedCornerShape(12.dp)
        Column(Modifier.fillMaxWidth().clip(shape).background(Hg.card).border(1.dp, Hg.line, shape).padding(horizontal = 14.dp, vertical = 8.dp)) { content() }
        if (footer != null) Box(Modifier.padding(start = 4.dp, top = 6.dp)) { Note(footer, color = Hg.muted) }
    }
}

/** 設定の 1 行（押せる文） */
@Composable
fun SettingsRow(text: String, color: Color? = null, enabled: Boolean = true, onClick: () -> Unit) {
    Text(
        text, color = (color ?: Hg.accent).copy(alpha = if (enabled) 1f else 0.4f), fontSize = 15.sp,
        modifier = Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = onClick).padding(vertical = 11.dp),
    )
}

/** 設定の切り替え */
@Composable
fun SettingsToggle(text: String, on: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(text, color = Hg.text, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Switch(on, onChange, colors = SwitchDefaults.colors(checkedTrackColor = Hg.accent, checkedThumbColor = Color.White))
    }
}

/**
 * 選択肢から 1 つ選ぶ行（プルダウン）。**ステッパーにしない**（上下矢印は押す向きと数字の動きが分かりにくい・本人指摘）
 */
@Composable
fun <T> SettingsPicker(title: String, value: T, options: List<T>, label: @Composable (T) -> String, onPick: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clickable { open = true }.padding(vertical = 11.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = Hg.text, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(8.dp))
        Box {
            Text(label(value) + "  ⌄", color = Hg.accent, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                for (o in options) DropdownMenuItem(
                    text = { Text(label(o), color = if (o == value) Hg.accent else Hg.text, fontWeight = if (o == value) FontWeight.Bold else FontWeight.Normal) },
                    onClick = { open = false; onPick(o) },
                )
            }
        }
    }
}
