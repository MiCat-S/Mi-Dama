// 数据模型：一次识别的产出是一组 Finding，界面负责让用户确认，Redactor 负责打码
package com.example.redact.core

import java.util.UUID

/** 敏感信息类别（声明顺序即界面上数量相同时的排列顺序） */
enum class FindingKind(val label: String, val isText: Boolean = true) {
    // 文字类
    PHONE("手机号"), ID_CARD("身份证号"), BANK_CARD("银行卡号"), EMAIL("邮箱"), PLATE("车牌"), IP_ADDRESS("IP 地址"),
    VERIFICATION_CODE("验证码"), LONG_NUMBER("长数字"), ORDER_NUMBER("订单/单号"), LINK("链接"), MENTION("@提及"),

    /** "收货人：张三" 这类由关键词定位到的值 */
    KEYWORD_VALUE("个人信息"),

    // 图像类
    FACE("人脸", isText = false), QR_CODE("二维码", isText = false), BARCODE("条形码", isText = false),

    // 聊天截图布局类
    CHAT_AVATAR("头像", isText = false), CHAT_NICKNAME("昵称"), CHAT_TITLE("聊天标题"), CHAT_SYSTEM_MESSAGE("系统消息"),

    /** 用户手动框选 */
    MANUAL("手动"),
}

/** 打码样式（声明顺序即界面上的排列顺序） */
enum class MaskStyle(val label: String) {
    /** 背景近似纯色时用背景色把内容抹掉，否则退回大块像素化（不可逆） */
    HIDE_TEXT("抹除文字"),
    SOLID("色块"),

    /** 带噪点的色块：比纯色块自然，同样不取原图像素 */
    NOISE_BLOCK("杂讯色块"),
    PIXELATE("像素化"),
    BLUR("模糊"),

    /** 横向彩虹条纹 */
    RAINBOW_BARS("彩虹条"),

    /** 随机彩色方格：看起来像马赛克，但颜色与原图无关 */
    RAINBOW_GRID("彩虹格");

    /** 是否使用用户选择的颜色 */
    val usesColor get() = this == SOLID || this == NOISE_BLOCK

    /** 结果只由区域大小和颜色决定、不读取原图像素 —— 无论强度如何都无法还原 */
    val ignoresSourcePixels get() = this == SOLID || this == NOISE_BLOCK || this == RAINBOW_BARS || this == RAINBOW_GRID

    companion object {
        /** 各类别的默认样式：文字用不可逆的抹除，人脸模糊，头像 / 二维码大块像素化 */
        fun defaultFor(kind: FindingKind) = when (kind) {
            FindingKind.FACE -> BLUR
            FindingKind.CHAT_AVATAR, FindingKind.QR_CODE, FindingKind.BARCODE -> PIXELATE
            else -> HIDE_TEXT
        }
    }
}

/** 一处待打码区域 */
data class Finding(
    val kind: FindingKind,
    /** 原图像素坐标，左上角为原点 */
    val rect: Rect,
    /** 0–1，低于阈值的默认不勾选 */
    val confidence: Float,
    /** 命中的文字（仅用于界面展示，不落盘、不打日志） */
    val text: String? = null,
    /** 隐私工具宁可多盖：只有明显不可靠的结果默认不勾选 */
    val isEnabled: Boolean = confidence >= 0.5f,
    /** 单独指定的样式；null 时用全局样式或该类别的默认样式 */
    val style: MaskStyle? = null,
    val id: String = UUID.randomUUID().toString(),
) {
    val resolvedStyle get() = style ?: MaskStyle.defaultFor(kind)
}
