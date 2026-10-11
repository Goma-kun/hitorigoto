package jp.nishira.hitorigoto.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import jp.nishira.hitorigoto.AppModel
import jp.nishira.hitorigoto.BuildConfig
import jp.nishira.hitorigoto.R
import jp.nishira.hitorigoto.core.TargetLanguage
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen(model: AppModel, dataStatus: String, onExport: () -> Unit, onImport: () -> Unit, bottomInset: Dp) {
    val context = LocalContext.current
    var editingKey by remember { mutableStateOf(false) }
    var confirmDeleteKey by remember { mutableStateOf(false) }
    var keyStatus by remember { mutableStateOf("") }
    LaunchedEffect(model.engine) { model.refreshQuota() }

    Column(
        Modifier.fillMaxSize().background(Hg.bg).verticalScroll(rememberScrollState()).padding(start = 12.dp, end = 12.dp, top = 12.dp, bottom = 12.dp + bottomInset),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        SettingsSection(header = stringResource(R.string.section_review),
            footer = stringResource(if (model.usesRelay) R.string.cloud_note else R.string.gemini_note)) {
            SettingsPicker(stringResource(R.string.engine_label), model.engine, listOf("cloud", "gemini"),
                { stringResource(if (it == "gemini") R.string.engine_gemini else R.string.engine_cloud) }) { model.changeEngine(it) }
            if (model.usesRelay) model.quota?.let { q ->
                StatusLine(
                    if (q.remaining > 0) pluralStringResource(R.plurals.reviews_left, q.remaining, q.remaining, q.limit) else pluralStringResource(R.plurals.reviews_used_up, q.limit, q.limit),
                    ok = q.remaining > 0,
                )
            }
        }

        if (model.engine == "gemini") SettingsSection(header = stringResource(R.string.section_key), footer = stringResource(R.string.key_note)) {
            StatusLine(stringResource(if (model.hasKey) R.string.key_set else R.string.key_not_set), ok = model.hasKey)
            Row(verticalAlignment = Alignment.CenterVertically) {
                SettingsRowInline(stringResource(if (model.hasKey) R.string.key_change else R.string.key_register)) { editingKey = true }
                Spacer(Modifier.weight(1f))
                // 一押しで消えないように、確認を挟む（キーの再発行は手間なので）
                if (model.hasKey) SettingsRowInline(stringResource(R.string.key_delete), color = Hg.bad) { confirmDeleteKey = true }
            }
            if (keyStatus.isNotEmpty()) Text(keyStatus, color = if (keyStatus.startsWith("✗")) Hg.bad else Hg.good, fontSize = 12.sp, modifier = Modifier.padding(bottom = 6.dp))
        }

        SettingsSection(header = stringResource(R.string.section_language), footer = stringResource(R.string.language_note)) {
            SettingsPicker(stringResource(R.string.section_language), model.targetLanguage, TargetLanguage.entries, { languageLabel(it) }) { model.changeLanguage(it.code) }
        }

        SettingsSection(header = stringResource(R.string.section_captions), footer = stringResource(R.string.captions_note)) {
            SettingsToggle(stringResource(R.string.captions_toggle), model.captionsOn) { model.changeCaptionsOn(it) }
        }

        SettingsSection(header = stringResource(R.string.section_voice), footer = stringResource(R.string.voice_note)) {
            SettingsPicker(stringResource(R.string.voice_rate), if (model.voiceRate < 0.95f) "slow" else "normal", listOf("slow", "normal"),
                { stringResource(if (it == "slow") R.string.voice_slow else R.string.voice_normal) }) { model.changeVoiceRate(if (it == "slow") 0.85f else 1.0f) }
            val sample = when (model.targetLanguage) {
                TargetLanguage.ES_ES, TargetLanguage.ES_MX -> "Por un instante, miró directamente a la cámara."
                TargetLanguage.JA_JP -> "ほんの一瞬、カメラをまっすぐ見つめた。"
                else -> "For a split second, he looked straight into the lens."
            }
            SettingsRow(stringResource(R.string.voice_try)) { model.speaker.toggle(sample) }
        }

        SettingsSection(header = stringResource(R.string.section_daily), footer = stringResource(R.string.daily_note)) {
            SettingsPicker(stringResource(R.string.daily_total), model.dailyTotal, (1..12).toList(), { "$it" }) { model.changeDailyTotal(it) }
            SettingsPicker(stringResource(R.string.daily_new), model.dailyNew, (0..6).toList(), { "$it" }) { model.changeDailyNew(it) }
        }

        SettingsSection(header = stringResource(R.string.section_data), footer = stringResource(R.string.data_note)) {
            Row {
                SettingsRowInline(stringResource(R.string.export), onClick = onExport)
                Spacer(Modifier.width(24.dp))
                SettingsRowInline(stringResource(R.string.import_), onClick = onImport)
            }
            if (dataStatus.isNotEmpty()) Text(dataStatus, color = if (dataStatus.startsWith("✗")) Hg.bad else Hg.good, fontSize = 12.sp, modifier = Modifier.padding(bottom = 6.dp))
        }

        SettingsSection(header = stringResource(R.string.section_about)) {
            Text(stringResource(R.string.about_version, BuildConfig.VERSION_NAME), color = Hg.muted, fontSize = 12.sp, modifier = Modifier.padding(vertical = 8.dp))
            SettingsRow(stringResource(R.string.privacy_policy)) { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/Goma-kun/hitorigoto/blob/main/PRIVACY.md"))) }
            SettingsRow(stringResource(R.string.support)) { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://nishira.jp/"))) }
        }
    }

    if (editingKey) KeySheet(model, onStatus = { keyStatus = it }) { editingKey = false }
    if (confirmDeleteKey) AlertDialog(
        onDismissRequest = { confirmDeleteKey = false },
        title = { Text(stringResource(R.string.key_delete_confirm), color = Hg.text) },
        text = { Text(stringResource(R.string.key_delete_body), color = Hg.muted) },
        confirmButton = { val deleted = stringResource(R.string.key_deleted); TextButton({ confirmDeleteKey = false; model.setKey(null); keyStatus = deleted }) { Text(stringResource(R.string.delete_do), color = Hg.bad) } },
        dismissButton = { TextButton({ confirmDeleteKey = false }) { Text(stringResource(R.string.cancel), color = Hg.muted) } },
    )
}

@Composable
fun languageLabel(l: TargetLanguage): String = stringResource(when (l) {
    TargetLanguage.EN_US -> R.string.lang_en_us
    TargetLanguage.EN_GB -> R.string.lang_en_gb
    TargetLanguage.ES_ES -> R.string.lang_es_es
    TargetLanguage.ES_MX -> R.string.lang_es_mx
    TargetLanguage.JA_JP -> R.string.lang_ja_jp
})

@Composable
private fun StatusLine(text: String, ok: Boolean) {
    Row(Modifier.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(if (ok) Icons.Filled.CheckCircle else Icons.Outlined.ErrorOutline, contentDescription = null, tint = if (ok) Hg.good else Hg.warn, modifier = Modifier.size(18.dp))
        Text(text, color = if (ok) Hg.good else Hg.warn, fontSize = 14.sp)
    }
}

@Composable
private fun SettingsRowInline(text: String, color: Color? = null, onClick: () -> Unit) {
    Text(text, color = color ?: Hg.accent, fontSize = 15.sp, modifier = Modifier.clickable(onClick = onClick).padding(vertical = 11.dp))
}

/** キーの登録シート。入力→接続テスト→保存。キーは画面に伏せ字で出す */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun KeySheet(model: AppModel, onStatus: (String) -> Unit, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var keyInput by remember { mutableStateOf("") }
    var result by remember { mutableStateOf("") }
    var testing by remember { mutableStateOf(false) }
    val connected = stringResource(R.string.key_connected); val saved = stringResource(R.string.key_saved)
    ModalBottomSheet(onDismissRequest = onClose, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = Hg.bg) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).navigationBarsPadding().padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.key_sheet_title), color = Hg.text, fontSize = 17.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                TextButton(onClose) { Text(stringResource(R.string.close), color = Hg.accent) }
            }
            SettingsSection(header = stringResource(R.string.section_key), footer = stringResource(R.string.key_sheet_note)) {
                OutlinedTextField(keyInput, { keyInput = it }, label = { Text(stringResource(R.string.key_field)) }, placeholder = { Text(stringResource(R.string.key_placeholder)) },
                    singleLine = true, colors = hgFieldColors(), visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp))
                Row(Modifier.padding(vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TintedButton(stringResource(if (testing) R.string.key_testing else R.string.key_test), small = false, enabled = !testing && keyInput.isNotBlank()) {
                        testing = true
                        scope.launch { result = model.testKey(keyInput.trim())?.let { "✗ $it" } ?: connected; testing = false }
                    }
                    FilledButton(stringResource(R.string.save), enabled = keyInput.isNotBlank()) {
                        model.setKey(keyInput); onStatus(saved); onClose()
                    }
                }
                if (result.isNotEmpty()) Text(result, color = if (result.startsWith("✗")) Hg.bad else Hg.good, fontSize = 12.sp, modifier = Modifier.padding(bottom = 6.dp))
            }
            SettingsSection {
                SettingsRow(stringResource(R.string.key_get)) { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://aistudio.google.com/apikey"))) }
            }
        }
    }
}
