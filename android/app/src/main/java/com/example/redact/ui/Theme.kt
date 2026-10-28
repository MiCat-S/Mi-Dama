// 主题：Android 12+ 跟随系统取色，更早的系统用固定配色；深浅色跟随系统
package com.example.redact.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import com.example.redact.core.FindingKind

/** 保存按钮的绿色 */
val SaveGreen = Color(0xFF34C759)

@Composable
fun RedactTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val scheme = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme(primary = Color(0xFF6E98FF))
        else -> lightColorScheme(primary = Color(0xFF2F6BFF))
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

/** 各类别的颜色：聊天布局蓝、人脸橙、条码紫、手动黄、文字红 */
val FindingKind.tint: Color
    get() = when (this) {
        FindingKind.CHAT_AVATAR, FindingKind.CHAT_NICKNAME, FindingKind.CHAT_TITLE, FindingKind.CHAT_SYSTEM_MESSAGE -> Color(0xFF007AFF)
        FindingKind.FACE -> Color(0xFFFF9500)
        FindingKind.QR_CODE, FindingKind.BARCODE -> Color(0xFFAF52DE)
        FindingKind.MANUAL -> Color(0xFFFFCC00)
        else -> Color(0xFFFF3B30)
    }
