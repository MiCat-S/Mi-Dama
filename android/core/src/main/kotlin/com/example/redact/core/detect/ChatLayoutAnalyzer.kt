// 聊天截图布局分析（不需要训练）：
//  头像 = 贴着左 / 右边距的一列、竖向重复出现、内侧紧挨着间隙的近似正方形色块（带状搜索，见 detectAvatars）
//  昵称 = 头像旁边、顶部与头像对齐、落在页面背景上（不在气泡里）的 OCR 行
//  标题 = 顶部居中的 OCR 行；系统消息 = 居中且含"撤回 / 邀请 / 拍了拍"等关键词的行
package com.example.redact.core.detect

import com.example.redact.core.Finding
import com.example.redact.core.FindingKind
import com.example.redact.core.Rect
import com.example.redact.core.render.RgbaImage
import com.example.redact.core.render.Rgb
import com.example.redact.core.render.blue
import com.example.redact.core.render.green
import com.example.redact.core.render.red
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

object ChatLayoutAnalyzer {
    enum class Side { LEFT, RIGHT }

    class Avatar(
        /** 原图像素，左上原点 */
        val rect: Rect,
        val side: Side,
        val confidence: Float,
    )

    /**
     * @param small 按 [scale] 缩小后的像素
     * @param lines 原图坐标的 OCR 行
     */
    fun analyze(small: RgbaImage, scale: Float, lines: List<RecognizedLine>, width: Float, height: Float): List<Finding> {
        val bg = pageBackground(small) ?: return systemMessages(lines, width)
        val findings = mutableListOf<Finding>()

        val avatars = detectAvatars(small, bg, scale).toMutableList()
        val names = nicknames(avatars, lines, small, scale, bg, width).toMutableList()
        // 头像漏检（比如和背景几乎同色的默认头像）时，靠"昵称列"把昵称和头像补回来
        val inferred = inferFromNicknameColumn(names, avatars, lines, small, scale, bg, width)
        names += inferred.first
        avatars += inferred.second
        // OCR 偶尔漏掉又短又淡的昵称（比如深色模式下的 "Lily"），按像素在昵称槽位里补
        names += pixelNicknames(avatars, names, small, scale, bg, width)
        findings += avatars.map { Finding(FindingKind.CHAT_AVATAR, it.rect, it.confidence) }
        findings += names
        if (avatars.any { it.confidence >= 0.65f }) {
            val firstAvatarTop = avatars.minOfOrNull { it.rect.minY } ?: height
            findings += title(lines, firstAvatarTop, width, height)
        }
        findings += systemMessages(lines, width)
        return findings
    }

    // 页面背景

    /**
     * 取左右最外侧 2.5% 的竖条（头像左边的空白）统计众数颜色；
     * 众数占比太低说明不是聊天界面（比如照片），不做布局分析
     */
    fun pageBackground(img: RgbaImage): Rgb? {
        val strip = max(2, img.width / 40)
        val counts = HashMap<Int, LongArray>()   // 量化后的颜色 → [数量, r 之和, g 之和, b 之和]
        var total = 0
        val xs = (0 until min(strip, img.width)) + (max(0, img.width - strip) until img.width)
        for (y in img.height * 15 / 100 until img.height * 85 / 100 step 2) {
            for (x in xs) {
                val c = img[x, y]
                // 量化，容忍 JPEG 噪声
                val key = ((red(c) / 4) shl 16) or ((green(c) / 4) shl 8) or (blue(c) / 4)
                val acc = counts.getOrPut(key) { LongArray(4) }
                acc[0]++; acc[1] += red(c).toLong(); acc[2] += green(c).toLong(); acc[3] += blue(c).toLong()
                total++
            }
        }
        val mode = counts.values.maxByOrNull { it[0] } ?: return null
        if (total == 0 || mode[0].toDouble() / total <= 0.45) return null
        val n = mode[0].toFloat()
        return Rgb(mode[1] / n, mode[2] / n, mode[3] / n)
    }

    // 头像

    /**
     * 带状搜索：头像和气泡之间只隔 4–6dp，连通域会把它们粘成一块；全局列统计又会被弹窗、卡片干扰。
     * 所以直接枚举"离边缘 s、宽 bw"的竖带，找其中高≈宽、带内前景过半、紧挨内侧的间隙基本是背景的行段，
     * 行段最多（其次最饱满）的那条带就是头像列。行前缀和让每次判断 O(1)。
     */
    fun detectAvatars(img: RgbaImage, bg: Rgb, scale: Float): List<Avatar> {
        val W = img.width
        val H = img.height
        val y0 = H * 6 / 100
        val y1 = H * 94 / 100   // 跳过状态栏和底部输入栏
        val stripW = W / 4
        fun isForeground(c: Int) = bg.maxDiff(c) > 4
        // 整行 ≥ 90% 都是前景的行（输入栏、通栏横幅）不可能是头像所在行
        val fullWidth = BooleanArray(H) { y ->
            var n = 0
            for (x in 0 until W) if (isForeground(img[x, y])) n++
            n * 10 >= W * 9
        }
        val minW = max(6, W * 6 / 100)
        val maxW = W * 20 / 100
        val maxStart = W * 12 / 100
        val gapW = max(2, W / 100)
        val avatars = mutableListOf<Avatar>()

        for (side in Side.entries) {
            // d = 离该侧边缘的距离；prefix[y * (stripW+1) + d] = 该行 [0, d) 的前景数
            fun px(d: Int) = if (side == Side.LEFT) d else W - 1 - d
            val stride = stripW + 1
            val prefix = IntArray(H * stride)
            for (y in y0 until y1) {
                if (fullWidth[y]) continue
                for (d in 0 until stripW) {
                    prefix[y * stride + d + 1] = prefix[y * stride + d] + if (isForeground(img[px(d), y])) 1 else 0
                }
            }
            fun count(y: Int, a: Int, b: Int) = prefix[y * stride + b] - prefix[y * stride + a]

            var bestRuns: List<IntRange>? = null
            var bestStart = 0
            var bestWidth = 0
            var bestFill = 0.0
            for (st in 0..maxStart) {
                for (bw in minW..maxW) {
                    if (st + bw + gapW > stripW) continue
                    val runs = squareRuns(y0, y1, bw) { y -> count(y, st, st + bw) * 2 >= bw }
                    val valid = runs.filter { run ->
                        val inner = run.sumOf { count(it, st + bw, st + bw + gapW) }
                        val outer = if (st >= gapW) run.sumOf { count(it, st - gapW, st) } else 0
                        val limit = run.count() * gapW * 0.35
                        inner < limit && outer < limit
                    }
                    if (valid.isEmpty()) continue
                    val fill = valid.sumOf { r -> r.sumOf { count(it, st, st + bw) } }.toDouble() /
                        (valid.sumOf { it.count() } * bw)
                    val best = bestRuns
                    if (best == null || valid.size > best.size || (valid.size == best.size && fill > bestFill)) {
                        bestRuns = valid
                        bestStart = st
                        bestWidth = bw
                        bestFill = fill
                    }
                }
            }
            val runs = bestRuns ?: continue
            val conf = if (runs.size >= 2) 0.9f else 0.65f
            for (run in runs) {
                val h = max(run.count(), bestWidth)
                val top = run.first - (h - run.count()) / 2
                val minX = if (side == Side.LEFT) bestStart else W - bestStart - bestWidth
                val r = Rect(minX / scale, top / scale, bestWidth / scale, h / scale)
                avatars += Avatar(r.inset(-1.5f / scale, -1.5f / scale), side, conf)
            }
        }
        return avatars
    }

    /**
     * 连续满足条件的行段（允许 2 行断裂），只保留高≈宽的；
     * 圆形头像只有中间约 87% 的行过半，所以下限放到 0.75
     */
    fun squareRuns(y0: Int, y1: Int, bw: Int, inBand: (Int) -> Boolean): List<IntRange> {
        val runs = mutableListOf<IntRange>()
        var runStart = -1
        var last = 0
        var gap = 0
        for (y in y0 until y1) {
            if (inBand(y)) {
                if (runStart < 0) runStart = y
                last = y
                gap = 0
            } else if (runStart >= 0) {
                gap++
                if (gap > 2) {
                    runs += runStart..last
                    runStart = -1
                }
            }
        }
        if (runStart >= 0) runs += runStart..last
        return runs.filter { it.count() >= bw * 0.75 && it.count() <= bw * 1.3 }
    }

    // 昵称

    fun nicknames(avatars: List<Avatar>, lines: List<RecognizedLine>, small: RgbaImage, scale: Float, bg: Rgb, width: Float): List<Finding> {
        val out = mutableListOf<Finding>()
        val used = HashSet<Int>()
        for (a in avatars) {
            val best = lines.withIndex().filter { (i, l) ->
                if (i in used) return@filter false
                val horizontal = if (a.side == Side.LEFT) {
                    l.rect.minX >= a.rect.maxX - width * 0.01f && l.rect.minX <= a.rect.maxX + width * 0.12f
                } else {
                    l.rect.maxX <= a.rect.minX + width * 0.01f && l.rect.maxX >= a.rect.minX - width * 0.12f
                }
                val topAligned = l.rect.minY >= a.rect.minY - a.rect.height * 0.3f &&
                    l.rect.minY <= a.rect.minY + a.rect.height * 0.5f
                horizontal && topAligned && isOnBackground(l.rect, small, scale, bg)
            }.minByOrNull { it.value.rect.minY } ?: continue
            used += best.index
            val rect = if (a.side == Side.LEFT) extendOverTrailingGlyphs(best.value.rect, small, scale, bg) else best.value.rect
            out += Finding(FindingKind.CHAT_NICKNAME, rect, if (a.confidence >= 0.65f) 0.85f else 0.6f, best.value.text)
        }
        return out
    }

    /**
     * OCR 认不出昵称末尾的表情（如 "小鱼儿🐟"），行框只到最后一个字：沿着这一行往右，
     * 把紧跟着的前景像素也算进昵称，遇到一段比半个字还宽的背景就停
     */
    fun extendOverTrailingGlyphs(rect: Rect, small: RgbaImage, scale: Float, bg: Rgb): Rect {
        val y0 = max(0, (rect.minY * scale).toInt())
        val y1 = min(small.height, ceil(rect.maxY * scale).toInt())
        val limit = min(small.width, ((rect.maxX + rect.height * 4) * scale).toInt())
        val maxGap = max(2, (rect.height * scale * 0.6f).toInt())
        var x = ceil(rect.maxX * scale).toInt()
        var lastForeground = -1
        var gap = 0
        while (x < limit) {
            if ((y0 until y1).any { bg.maxDiff(small[x, it]) > 12 }) {
                lastForeground = x
                gap = 0
            } else if (++gap > maxGap) {
                break
            }
            x++
        }
        if (lastForeground < 0) return rect
        return Rect.fromLTRB(rect.minX, rect.minY, max(rect.maxX, (lastForeground + 1) / scale), rect.maxY)
    }

    /** 文字行周围一圈是页面背景色 → 不在气泡里 */
    fun isOnBackground(rect: Rect, small: RgbaImage, scale: Float, bg: Rgb): Boolean {
        val stats = small.ringStats(rect.scaled(scale), band = 2) ?: return false
        return stats.median.maxDiff(bg) < 16
    }

    /**
     * 群聊里昵称都左对齐在同一列（头像右侧固定间距）。已知至少 2 个昵称时，同一列上、
     * 落在页面背景上、字号不大于昵称的其他行也是昵称，它左边同一高度必然有头像
     */
    fun inferFromNicknameColumn(
        names: List<Finding>, avatars: List<Avatar>, lines: List<RecognizedLine>,
        small: RgbaImage, scale: Float, bg: Rgb, width: Float,
    ): Pair<List<Finding>, List<Avatar>> {
        val ref = avatars.firstOrNull { it.side == Side.LEFT }
        if (names.size < 2 || ref == null) return emptyList<Finding>() to emptyList()
        val columnX = names.map { it.rect.minX }.sorted()[names.size / 2]
        val nameH = names.map { it.rect.height }.sorted()[names.size / 2]
        val outNames = mutableListOf<Finding>()
        val outAvatars = mutableListOf<Avatar>()
        for (l in lines) {
            if (abs(l.rect.minX - columnX) >= width * 0.015f || l.rect.height > nameH * 1.25f) continue
            if (names.any { it.rect.intersects(l.rect) }) continue
            if (!isOnBackground(l.rect, small, scale, bg)) continue
            outNames += Finding(FindingKind.CHAT_NICKNAME, extendOverTrailingGlyphs(l.rect, small, scale, bg), 0.75f, l.text)
            val a = Rect(ref.rect.minX, l.rect.minY - (ref.rect.height - l.rect.height) * 0.1f, ref.rect.width, ref.rect.height)
            if (avatars.none { it.rect.intersects(a) }) outAvatars += Avatar(a, Side.LEFT, 0.7f)
        }
        return outNames to outAvatars
    }

    /**
     * 群聊里每个左侧头像旁固定位置都有昵称。已知昵称列、字高、相对头像的偏移后，
     * 对还没配上昵称的头像，直接在该槽位里找文字像素：稀疏的前景是昵称，大片前景是气泡
     */
    fun pixelNicknames(avatars: List<Avatar>, names: List<Finding>, small: RgbaImage, scale: Float, bg: Rgb, width: Float): List<Finding> {
        if (names.size < 2) return emptyList()
        val left = avatars.filter { it.side == Side.LEFT }
        fun paired(a: Avatar) = names.firstOrNull {
            abs(it.rect.minY - a.rect.minY) < a.rect.height * 0.5f && it.rect.minX > a.rect.maxX - width * 0.01f
        }
        val offsets = left.mapNotNull { a -> paired(a)?.let { it.rect.minY - a.rect.minY } }.sorted()
        if (offsets.isEmpty()) return emptyList()
        val offset = offsets[offsets.size / 2]
        val columnX = names.map { it.rect.minX }.sorted()[names.size / 2]
        val nameH = names.map { it.rect.height }.sorted()[names.size / 2]

        val out = mutableListOf<Finding>()
        for (a in left) {
            if (paired(a) != null) continue
            val slot = Rect(columnX - width * 0.01f, a.rect.minY + offset - nameH * 0.2f, width * 0.45f, nameH * 1.4f)
            val x0 = max(0, (slot.minX * scale).toInt())
            val x1 = min(small.width, (slot.maxX * scale).toInt())
            val y0 = max(0, (slot.minY * scale).toInt())
            val y1 = min(small.height, (slot.maxY * scale).toInt())
            if (x1 <= x0 || y1 <= y0) continue
            var n = 0
            var minX = x1
            var maxX = x0
            var minY = y1
            var maxY = y0
            for (y in y0 until y1) {
                for (x in x0 until x1) {
                    if (bg.maxDiff(small[x, y]) <= 12) continue
                    n++
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            if (n == 0 || n * 10 >= (x1 - x0) * (y1 - y0) * 4) continue
            val r = Rect(minX / scale, minY / scale, (maxX - minX + 1) / scale, (maxY - minY + 1) / scale)
            out += Finding(FindingKind.CHAT_NICKNAME, r.inset(-2 / scale, -2 / scale), 0.7f)
        }
        return out
    }

    // 标题、系统消息

    private val genericTitles = setOf("微信", "WeChat", "通讯录", "发现", "我", "朋友圈", "Moments", "Chats", "QQ", "消息")

    /** 导航栏标题：在第一个头像之上、顶部 14% 以内、最居中的那一行 */
    fun title(lines: List<RecognizedLine>, limit: Float, width: Float, height: Float): List<Finding> {
        val t = lines.filter { l ->
            l.rect.maxY <= limit && l.rect.midY < height * 0.14f && abs(l.rect.midX - width / 2) < width * 0.12f &&
                l.text.trim() !in genericTitles && !isTimeLabel(l.text)
        }.minByOrNull { it.rect.minY } ?: return emptyList()
        return listOf(Finding(FindingKind.CHAT_TITLE, t.rect, 0.7f, t.text))
    }

    private val timeRegex = Regex("[0-9]{1,2}:[0-9]{2}")

    /** "9:41"、"昨天 14:32"、"星期二 21:17" 这类时间标签 */
    fun isTimeLabel(text: String): Boolean {
        val t = text.trim()
        return t.length <= 12 && timeRegex.containsMatchIn(t)
    }

    private val systemKeywords = listOf(
        "撤回了一条消息", "邀请", "加入了群聊", "拍了拍", "移出了群聊", "修改群名",
        "成为新群主", "recalled a message", "joined the group", "invited",
    )

    fun systemMessages(lines: List<RecognizedLine>, width: Float) = lines.filter { l ->
        abs(l.rect.midX - width / 2) < width * 0.08f && systemKeywords.any { l.text.contains(it, ignoreCase = true) }
    }.map { Finding(FindingKind.CHAT_SYSTEM_MESSAGE, it.rect, 0.7f, it.text) }
}
