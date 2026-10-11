package jp.nishira.hitorigoto.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/**
 * iOS の Theme.swift と同じ色（ダークは拡張機能の sidepanel.html と同じ）。**同じ製品に見えることが大事。**
 * 前景（accent）と背景（accentBg など）を分けて持つ
 */
class HgColors(val dark: Boolean) {
    private fun pick(light: Long, darkHex: Long) = Color(if (dark) darkHex else light)

    val bg = pick(0xFFF4F4F8, 0xFF0F172A)
    val card = pick(0xFFFFFFFF, 0xFF1E293B)
    val line = pick(0xFFE2E4EC, 0xFF334155)
    val text = pick(0xFF1E2233, 0xFFE2E8F0)
    val muted = pick(0xFF6B7280, 0xFF94A3B8)
    val faint = pick(0xFF9CA3AF, 0xFF64748B)
    /** 紫のアクセント（拡張の #a78bfa）。ライトでは少し濃く */
    val accent = pick(0xFF7C3AED, 0xFFA78BFA)
    val accentBg = pick(0xFFEDE9FE, 0xFF2A2450)
    val good = pick(0xFF15803D, 0xFF4ADE80)
    val goodBg = pick(0xFFDCFCE7, 0xFF14301F)
    val warn = pick(0xFFB45309, 0xFFFBBF24)
    val warnBg = pick(0xFFFEF3C7, 0xFF3A2F0F)
    val bad = pick(0xFFB91C1C, 0xFFF87171)
    val badBg = pick(0xFFFEE2E2, 0xFF3B1414)
    val info = pick(0xFF0369A1, 0xFF38BDF8)
    val rec = pick(0xFFDC2626, 0xFFEF4444)
    val white = Color.White
}

val LocalHgColors = staticCompositionLocalOf { HgColors(dark = false) }

/** いまの色一式。`Hg.bg` のように使う */
val Hg: HgColors
    @Composable get() = LocalHgColors.current

@Composable
fun HgTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val c = HgColors(dark)
    val scheme = if (dark) darkColorScheme(
        primary = c.accent, onPrimary = c.bg, background = c.bg, onBackground = c.text,
        surface = c.card, onSurface = c.text, surfaceVariant = c.card, onSurfaceVariant = c.muted,
        secondary = c.accentBg, onSecondary = c.text, error = c.bad, outline = c.line, surfaceContainer = c.card,
        surfaceContainerHigh = c.card, surfaceContainerLow = c.card, surfaceContainerHighest = c.card,
    ) else lightColorScheme(
        primary = c.accent, onPrimary = c.white, background = c.bg, onBackground = c.text,
        surface = c.card, onSurface = c.text, surfaceVariant = c.bg, onSurfaceVariant = c.muted,
        secondary = c.accentBg, onSecondary = c.text, error = c.bad, outline = c.line, surfaceContainer = c.card,
        surfaceContainerHigh = c.card, surfaceContainerLow = c.card, surfaceContainerHighest = c.card,
    )
    CompositionLocalProvider(LocalHgColors provides c) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
