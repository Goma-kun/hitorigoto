package jp.nishira.hitorigoto

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.LibraryBooks
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import jp.nishira.hitorigoto.core.Logic
import jp.nishira.hitorigoto.ui.Hg
import jp.nishira.hitorigoto.ui.HgTheme
import jp.nishira.hitorigoto.ui.HistoryScreen
import jp.nishira.hitorigoto.ui.PhrasesScreen
import jp.nishira.hitorigoto.ui.SettingsScreen
import jp.nishira.hitorigoto.ui.SpeakScreen

class MainActivity : ComponentActivity() {
    private val model: AppModel by viewModels()
    private var initialTab = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // スクショ用（デバッグ版だけ）: am start -e HGShot result / -e HGShotTab 2
        if (BuildConfig.DEBUG) {
            if (intent?.getStringExtra("HGShot") == "result") model.showLatestSessionAsResult()
            intent?.getStringExtra("HGShotTab")?.toIntOrNull()?.let { initialTab = it }
        }
        setContent { HgTheme { Root() } }
    }

    @Composable
    private fun Root() {
        var tab by remember { mutableStateOf(initialTab) }
        val context = LocalContext.current
        val micDenied = stringResource(R.string.err_mic_denied)

        // マイクの許可は「開始」を押したときに聞く（必要になった瞬間に聞くのが Android の作法）
        val micPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) model.startRecording() else model.errorMessage = micDenied
        }
        fun startWithPermission() {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) model.startRecording()
            else micPermission.launch(Manifest.permission.RECORD_AUDIO)
        }

        // 記録の書き出し・読み込み（SAF。拡張・iPhone と同じ JSON）
        var dataStatus by remember { mutableStateOf("") }
        val exported = stringResource(R.string.exported); val exportFailed = stringResource(R.string.export_failed)
        val importFailed = stringResource(R.string.import_failed)
        val exportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
            if (uri == null) return@rememberLauncherForActivityResult
            dataStatus = try {
                contentResolver.openOutputStream(uri)?.use { it.write(model.exportJson().toByteArray(Charsets.UTF_8)) }
                exported
            } catch (e: Exception) { exportFailed }
        }
        val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            if (uri == null) return@rememberLauncherForActivityResult
            try {
                val text = contentResolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""
                val n = model.importJson(text)
                dataStatus = resources.getQuantityString(R.plurals.imported, n, n)
            } catch (e: Exception) { dataStatus = importFailed }
        }

        Scaffold(
            containerColor = Hg.bg,
            bottomBar = {
                NavigationBar(containerColor = Hg.card) {
                    val items = listOf(
                        Triple(stringResource(R.string.tab_speak), Icons.Filled.Mic, 0),
                        Triple(stringResource(R.string.tab_phrases), Icons.Filled.LibraryBooks, 1),
                        Triple(stringResource(R.string.tab_history), Icons.Filled.History, 2),
                        Triple(stringResource(R.string.tab_settings), Icons.Filled.Settings, 3),
                    )
                    for ((name, icon, i) in items) {
                        NavigationBarItem(
                            selected = tab == i, onClick = { tab = i },
                            icon = { Icon(icon, contentDescription = null) }, label = { Text(name) },
                            colors = NavigationBarItemDefaults.colors(
                                selectedIconColor = Hg.accent, selectedTextColor = Hg.accent, indicatorColor = Hg.accentBg,
                                unselectedIconColor = Hg.muted, unselectedTextColor = Hg.muted,
                            ),
                        )
                    }
                }
            },
        ) { inner ->
            Box(Modifier.fillMaxSize().padding(top = inner.calculateTopPadding(), bottom = inner.calculateBottomPadding())) {
                when (tab) {
                    0 -> SpeakScreen(model, goPhrases = { tab = 1 }, onStart = { startWithPermission() }, bottomInset = 0.dp)
                    1 -> PhrasesScreen(model, bottomInset = 0.dp)
                    2 -> HistoryScreen(model, bottomInset = 0.dp)
                    else -> SettingsScreen(
                        model, dataStatus = dataStatus,
                        onExport = { exportLauncher.launch("hitorigoto-history-${Logic.todayStamp().replace("-", "")}.json") },
                        onImport = { importLauncher.launch(arrayOf("application/json", "text/plain", "*/*")) },
                        bottomInset = 0.dp,
                    )
                }
            }
        }
    }
}
