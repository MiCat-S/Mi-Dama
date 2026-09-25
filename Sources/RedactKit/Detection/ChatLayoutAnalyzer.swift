// 聊天截图布局分析（不需要训练）：
//  头像 = 贴着左 / 右边距的一列、竖向重复出现、内侧紧挨着间隙的近似正方形色块（带状搜索，见 detectAvatars）
//  昵称 = 头像旁边、顶部与头像对齐、落在页面背景上（不在气泡里）的 OCR 行
//  标题 = 顶部居中的 OCR 行；系统消息 = 居中且含"撤回 / 邀请 / 拍了拍"等关键词的行
import CoreGraphics
import simd

enum ChatLayoutAnalyzer {
    /// 布局分析用的工作宽度（约等于 1pt 一个像素，够用且快）
    static let workingWidth: CGFloat = 400

    enum Side { case left, right }

    struct Avatar {
        var rect: CGRect      // 原图像素，左上原点
        var side: Side
        var confidence: Float
    }

    /// - Parameters:
    ///   - small: 按 `scale` 缩小后的像素
    ///   - lines: 原图坐标的 OCR 行
    static func analyze(small: RGBAImage, scale: CGFloat, lines: [RecognizedLine], imageSize: CGSize) -> [Finding] {
        var findings: [Finding] = []
        guard let bg = pageBackground(small) else { return systemMessages(lines, imageSize: imageSize) }

        var avatars = detectAvatars(small, background: bg, scale: scale)
        var names = nicknames(for: avatars, lines: lines, small: small, scale: scale, background: bg, imageSize: imageSize)
        // 头像漏检（比如和背景几乎同色的默认头像）时，靠"昵称列"把昵称和头像补回来
        let inferred = inferFromNicknameColumn(names, avatars: avatars, lines: lines, small: small, scale: scale,
                                               background: bg, imageSize: imageSize)
        names += inferred.nicknames
        avatars += inferred.avatars
        // OCR 偶尔漏掉又短又淡的昵称（比如深色模式下的 "Lily"），按像素在昵称槽位里补
        names += pixelNicknames(avatars: avatars, names: names, small: small, scale: scale, background: bg, imageSize: imageSize)
        findings += avatars.map { Finding(kind: .chatAvatar, rect: $0.rect, confidence: $0.confidence) }
        findings += names
        if avatars.contains(where: { $0.confidence >= 0.65 }) {
            let firstAvatarTop = avatars.map(\.rect.minY).min() ?? imageSize.height
            findings += title(lines, above: firstAvatarTop, imageSize: imageSize)
        }
        findings += systemMessages(lines, imageSize: imageSize)
        return findings
    }

    // MARK: - 页面背景

    /// 取左右最外侧 2.5% 的竖条（头像左边的空白）统计众数颜色；
    /// 众数占比太低说明不是聊天界面（比如照片），不做布局分析
    static func pageBackground(_ img: RGBAImage) -> SIMD3<Float>? {
        let strip = max(2, img.width / 40)
        var counts: [SIMD3<Int32>: (n: Int, sum: SIMD3<Float>)] = [:]
        var total = 0
        for y in stride(from: img.height * 15 / 100, to: img.height * 85 / 100, by: 2) {
            for x in Array(0..<strip) + Array((img.width - strip)..<img.width) {
                let c = img.rgb(x, y)
                let key = SIMD3<Int32>(c / 4, rounding: .down)   // 量化，容忍 JPEG 噪声
                let cur = counts[key, default: (0, .zero)]
                counts[key] = (cur.n + 1, cur.sum + c)
                total += 1
            }
        }
        guard let (_, mode) = counts.max(by: { $0.value.n < $1.value.n }), total > 0,
              Double(mode.n) / Double(total) > 0.45 else { return nil }
        return mode.sum / Float(mode.n)
    }

    // MARK: - 头像

    /// 带状搜索：头像和气泡之间只隔 4–6pt，连通域会把它们粘成一块；全局列统计又会被弹窗、卡片干扰。
    /// 所以直接枚举"离边缘 s、宽 bw"的竖带，找其中高≈宽、带内前景过半、紧挨内侧的间隙基本是背景的行段，
    /// 行段最多（其次最饱满）的那条带就是头像列。行前缀和让每次判断 O(1)。
    static func detectAvatars(_ img: RGBAImage, background bg: SIMD3<Float>, scale: CGFloat) -> [Avatar] {
        let W = img.width, H = img.height
        let y0 = H * 6 / 100, y1 = H * 94 / 100   // 跳过状态栏和底部输入栏
        let stripW = W / 4
        let isForeground = { (c: SIMD3<Float>) in simd_reduce_max(simd_abs(c - bg)) > 4 }
        // 整行 ≥ 90% 都是前景的行（输入栏、通栏横幅）不可能是头像所在行
        let fullWidth = (0..<H).map { y in
            (0..<W).reduce(0) { $0 + (isForeground(img.rgb($1, y)) ? 1 : 0) } * 10 >= W * 9
        }
        let minW = max(6, W * 6 / 100), maxW = W * 20 / 100, maxStart = W * 12 / 100
        let gapW = max(2, W / 100)
        var avatars: [Avatar] = []

        for side in [Side.left, .right] {
            // d = 离该侧边缘的距离；prefix[y * (stripW+1) + d] = 该行 [0, d) 的前景数
            let px = { (d: Int) in side == .left ? d : W - 1 - d }
            let stride = stripW + 1
            var prefix = [Int32](repeating: 0, count: H * stride)
            for y in y0..<y1 where !fullWidth[y] {
                for d in 0..<stripW {
                    prefix[y * stride + d + 1] = prefix[y * stride + d] + (isForeground(img.rgb(px(d), y)) ? 1 : 0)
                }
            }
            let count = { (y: Int, a: Int, b: Int) in Int(prefix[y * stride + b] - prefix[y * stride + a]) }

            var best: (runs: [ClosedRange<Int>], start: Int, width: Int, fill: Double)?
            for st in 0...maxStart {
                for bw in minW...maxW where st + bw + gapW <= stripW {
                    let runs = squareRuns(y0: y0, y1: y1, width: bw) { y in count(y, st, st + bw) * 2 >= bw }
                    let valid = runs.filter { run in
                        let inner = run.reduce(0) { $0 + count($1, st + bw, st + bw + gapW) }
                        let outer = st >= gapW ? run.reduce(0) { $0 + count($1, st - gapW, st) } : 0
                        let limit = Double(run.count * gapW) * 0.35
                        return Double(inner) < limit && Double(outer) < limit
                    }
                    guard !valid.isEmpty else { continue }
                    let fill = Double(valid.reduce(0) { acc, r in acc + r.reduce(0) { $0 + count($1, st, st + bw) } })
                        / Double(valid.reduce(0) { $0 + $1.count } * bw)
                    if best == nil || valid.count > best!.runs.count || (valid.count == best!.runs.count && fill > best!.fill) {
                        best = (valid, st, bw, fill)
                    }
                }
            }
            guard let b = best else { continue }
            let conf: Float = b.runs.count >= 2 ? 0.9 : 0.65
            for run in b.runs {
                let h = max(run.count, b.width)
                let top = run.lowerBound - (h - run.count) / 2
                let minX = side == .left ? b.start : W - b.start - b.width
                let r = CGRect(x: CGFloat(minX) / scale, y: CGFloat(top) / scale,
                               width: CGFloat(b.width) / scale, height: CGFloat(h) / scale)
                avatars.append(Avatar(rect: r.insetBy(dx: -1.5 / scale, dy: -1.5 / scale), side: side, confidence: conf))
            }
        }
        return avatars
    }

    /// 连续满足条件的行段（允许 2 行断裂），只保留高≈宽的；
    /// 圆形头像只有中间约 87% 的行过半，所以下限放到 0.75
    static func squareRuns(y0: Int, y1: Int, width bw: Int, _ inBand: (Int) -> Bool) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var runStart: Int?, last = 0, gap = 0
        for y in y0..<y1 {
            if inBand(y) {
                if runStart == nil { runStart = y }
                last = y; gap = 0
            } else if let s = runStart {
                gap += 1
                if gap > 2 { runs.append(s...last); runStart = nil }
            }
        }
        if let s = runStart { runs.append(s...last) }
        return runs.filter { Double($0.count) >= Double(bw) * 0.75 && Double($0.count) <= Double(bw) * 1.3 }
    }

    // MARK: - 昵称

    static func nicknames(for avatars: [Avatar], lines: [RecognizedLine], small: RGBAImage, scale: CGFloat,
                          background bg: SIMD3<Float>, imageSize: CGSize) -> [Finding] {
        let W = imageSize.width
        var out: [Finding] = []
        var used = Set<Int>()
        for a in avatars {
            let candidates = lines.enumerated().filter { i, l in
                guard !used.contains(i) else { return false }
                let horizontal = a.side == .left
                    ? (l.rect.minX >= a.rect.maxX - W * 0.01 && l.rect.minX <= a.rect.maxX + W * 0.12)
                    : (l.rect.maxX <= a.rect.minX + W * 0.01 && l.rect.maxX >= a.rect.minX - W * 0.12)
                let topAligned = l.rect.minY >= a.rect.minY - a.rect.height * 0.3
                    && l.rect.minY <= a.rect.minY + a.rect.height * 0.5
                return horizontal && topAligned && isOnBackground(l.rect, small: small, scale: scale, background: bg)
            }
            guard let (i, line) = candidates.min(by: { $0.element.rect.minY < $1.element.rect.minY }) else { continue }
            used.insert(i)
            out.append(Finding(kind: .chatNickname, rect: line.rect, confidence: a.confidence >= 0.65 ? 0.85 : 0.6, text: line.text))
        }
        return out
    }

    /// 文字行周围一圈是页面背景色 → 不在气泡里
    static func isOnBackground(_ rect: CGRect, small: RGBAImage, scale: CGFloat, background bg: SIMD3<Float>) -> Bool {
        let r = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        guard let stats = small.ringStats(around: r, band: 2) else { return false }
        return simd_reduce_max(simd_abs(stats.median - bg)) < 16
    }

    /// 群聊里昵称都左对齐在同一列（头像右侧固定间距）。已知至少 2 个昵称时，同一列上、
    /// 落在页面背景上、字号不大于昵称的其他行也是昵称，它左边同一高度必然有头像
    static func inferFromNicknameColumn(_ names: [Finding], avatars: [Avatar], lines: [RecognizedLine],
                                        small: RGBAImage, scale: CGFloat, background bg: SIMD3<Float>,
                                        imageSize: CGSize) -> (nicknames: [Finding], avatars: [Avatar]) {
        let W = imageSize.width
        let left = avatars.filter { $0.side == .left }
        guard names.count >= 2, let ref = left.first else { return ([], []) }
        let xs = names.map(\.rect.minX).sorted(), hs = names.map(\.rect.height).sorted()
        let columnX = xs[xs.count / 2], nameH = hs[hs.count / 2]
        var outNames: [Finding] = [], outAvatars: [Avatar] = []
        for l in lines where abs(l.rect.minX - columnX) < W * 0.015 && l.rect.height <= nameH * 1.25 {
            if names.contains(where: { $0.rect.intersects(l.rect) }) { continue }
            guard isOnBackground(l.rect, small: small, scale: scale, background: bg) else { continue }
            outNames.append(Finding(kind: .chatNickname, rect: l.rect, confidence: 0.75, text: l.text))
            let a = CGRect(x: ref.rect.minX, y: l.rect.minY - (ref.rect.height - l.rect.height) * 0.1,
                           width: ref.rect.width, height: ref.rect.height)
            if !avatars.contains(where: { $0.rect.intersects(a) }) {
                outAvatars.append(Avatar(rect: a, side: .left, confidence: 0.7))
            }
        }
        return (outNames, outAvatars)
    }

    /// 群聊里每个左侧头像旁固定位置都有昵称。已知昵称列、字高、相对头像的偏移后，
    /// 对还没配上昵称的头像，直接在该槽位里找文字像素：稀疏的前景是昵称，大片前景是气泡
    static func pixelNicknames(avatars: [Avatar], names: [Finding], small: RGBAImage, scale: CGFloat,
                               background bg: SIMD3<Float>, imageSize: CGSize) -> [Finding] {
        guard names.count >= 2 else { return [] }
        let W = imageSize.width
        let left = avatars.filter { $0.side == .left }
        let paired = { (a: Avatar) in
            names.first { abs($0.rect.minY - a.rect.minY) < a.rect.height * 0.5 && $0.rect.minX > a.rect.maxX - W * 0.01 }
        }
        let offsets = left.compactMap { a in paired(a).map { $0.rect.minY - a.rect.minY } }.sorted()
        guard !offsets.isEmpty else { return [] }
        let offset = offsets[offsets.count / 2]
        let columnX = names.map(\.rect.minX).sorted()[names.count / 2]
        let nameH = names.map(\.rect.height).sorted()[names.count / 2]

        var out: [Finding] = []
        for a in left where paired(a) == nil {
            let slot = CGRect(x: columnX - W * 0.01, y: a.rect.minY + offset - nameH * 0.2, width: W * 0.45, height: nameH * 1.4)
            let x0 = max(0, Int(slot.minX * scale)), x1 = min(small.width, Int(slot.maxX * scale))
            let y0 = max(0, Int(slot.minY * scale)), y1 = min(small.height, Int(slot.maxY * scale))
            guard x1 > x0, y1 > y0 else { continue }
            var n = 0, minX = x1, maxX = x0, minY = y1, maxY = y0
            for y in y0..<y1 {
                for x in x0..<x1 where simd_reduce_max(simd_abs(small.rgb(x, y) - bg)) > 12 {
                    n += 1
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard n > 0, n * 10 < (x1 - x0) * (y1 - y0) * 4 else { continue }
            let r = CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                           width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
            out.append(Finding(kind: .chatNickname, rect: r.insetBy(dx: -2 / scale, dy: -2 / scale), confidence: 0.7))
        }
        return out
    }

    // MARK: - 标题、系统消息

    private static let genericTitles: Set<String> = ["微信", "WeChat", "通讯录", "发现", "我", "朋友圈", "Moments", "Chats", "QQ", "消息"]

    /// 导航栏标题：在第一个头像之上、顶部 14% 以内、最居中的那一行
    static func title(_ lines: [RecognizedLine], above limit: CGFloat, imageSize: CGSize) -> [Finding] {
        let W = imageSize.width, H = imageSize.height
        let top = lines.filter { l in
            l.rect.maxY <= limit && l.rect.midY < H * 0.14 && abs(l.rect.midX - W / 2) < W * 0.12
                && !genericTitles.contains(l.text.trimmingCharacters(in: .whitespaces))
                && !isTimeLabel(l.text)
        }
        guard let t = top.min(by: { $0.rect.minY < $1.rect.minY }) else { return [] }
        return [Finding(kind: .chatTitle, rect: t.rect, confidence: 0.7, text: t.text)]
    }

    /// "9:41"、"昨天 14:32"、"星期二 21:17" 这类时间标签
    static func isTimeLabel(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.count <= 12 && t.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil
    }

    private static let systemKeywords = ["撤回了一条消息", "邀请", "加入了群聊", "拍了拍", "移出了群聊", "修改群名",
                                          "成为新群主", "recalled a message", "joined the group", "invited"]

    static func systemMessages(_ lines: [RecognizedLine], imageSize: CGSize) -> [Finding] {
        lines.filter { l in
            abs(l.rect.midX - imageSize.width / 2) < imageSize.width * 0.08
                && systemKeywords.contains { l.text.localizedCaseInsensitiveContains($0) }
        }.map { Finding(kind: .chatSystemMessage, rect: $0.rect, confidence: 0.7, text: $0.text) }
    }
}
