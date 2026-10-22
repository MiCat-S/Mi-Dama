// 识别总入口：Vision → 文本规则 → 聊天布局 → 合并去重
import CoreImage

/// 一行 OCR 文字（原图像素坐标，左上原点）：编辑器的"文字"工具点一下就能盖住整行
public struct TextLine: Hashable, Sendable {
    public let rect: CGRect
    public let text: String
}

public struct DetectionResult: Sendable {
    public let findings: [Finding]
    public let textLines: [TextLine]
}

public struct DetectionPipeline {
    let context: CIContext

    public init(context: CIContext = RenderContext.shared) {
        self.context = context
    }

    /// - Parameter image: 已按方向校正的原图（`CIImage(contentsOf:options:[.applyOrientationProperty: true])`）
    /// - Returns: 原图像素坐标（左上原点）的待打码区域
    public func detect(_ image: CIImage) throws -> [Finding] {
        try analyze(image).findings
    }

    /// 识别结果 + 所有 OCR 文字行
    public func analyze(_ image: CIImage) throws -> DetectionResult {
        let image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let size = image.extent.size
        let vision = try VisionDetector.detect(image)

        var findings = textFindings(vision.lines)
        findings += vision.faces.map { Finding(kind: .face, rect: $0.rect, confidence: max(0.6, $0.confidence)) }
        findings += vision.codes.map { Finding(kind: $0.isQR ? .qrCode : .barcode, rect: $0.rect, confidence: 0.9) }

        let scale = min(1, ChatLayoutAnalyzer.workingWidth / size.width)
        let small = RGBAImage(image, scale: scale, context: context)
        let chat = ChatLayoutAnalyzer.analyze(small: small, scale: scale, lines: vision.lines, imageSize: size)
        findings += chat

        // 头像里的人脸交给头像处理，避免重复框
        let avatars = chat.filter { $0.kind == .chatAvatar }.map(\.rect)
        findings.removeAll { f in
            f.kind == .face && avatars.contains { $0.intersection(f.rect).area > f.rect.area * 0.6 }
        }
        let sorted = deduplicate(findings).sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
        return DetectionResult(findings: sorted, textLines: vision.lines.map { TextLine(rect: $0.rect, text: $0.text) })
    }

    /// 文本规则命中 → 字符级框；"收货人" 这类单独一行的标签，把同一行右侧的文字当作值
    func textFindings(_ lines: [RecognizedLine]) -> [Finding] {
        var out: [Finding] = []
        for line in lines {
            let chars = Array(line.text)
            for m in SensitiveTextScanner.scan(line.text) {
                // OCR 本身不确定时稍微降权，但仍在默认勾选线以上
                let conf = line.confidence < 0.5 ? max(0.5, m.confidence - 0.1) : m.confidence
                out.append(Finding(kind: m.kind, rect: line.rect(forCharacters: m.range), confidence: conf,
                                   text: String(chars[m.range])))
            }
            if SensitiveTextScanner.isLabelOnly(line.text) {
                let sameRow = lines.filter { other in
                    let overlap = min(other.rect.maxY, line.rect.maxY) - max(other.rect.minY, line.rect.minY)
                    return other.rect.minX > line.rect.maxX && overlap > min(other.rect.height, line.rect.height) * 0.5
                }
                if let value = sameRow.min(by: { $0.rect.minX < $1.rect.minX }) {
                    out.append(Finding(kind: .keywordValue, rect: value.rect, confidence: 0.7, text: value.text))
                }
            }
        }
        out += crossLineFindings(lines)
        return out
    }

    /// 气泡里折行的邮箱、号码：把上下紧挨、左对齐的两行拼起来再扫一遍，
    /// 只取跨越折行处的命中，两半各出一个框
    func crossLineFindings(_ lines: [RecognizedLine]) -> [Finding] {
        let sorted = lines.sorted { $0.rect.minY < $1.rect.minY }
        var out: [Finding] = []
        for (i, a) in sorted.enumerated() {
            guard let b = sorted[(i + 1)...].first(where: { n in
                n.rect.minY > a.rect.minY + a.rect.height * 0.5
                    && n.rect.minY - a.rect.maxY < a.rect.height * 0.6
                    && abs(n.rect.minX - a.rect.minX) < a.rect.height * 1.5
            }) else { continue }
            let joined = a.text + b.text
            let split = a.text.count
            let chars = Array(joined)
            for m in SensitiveTextScanner.scan(joined) where m.range.lowerBound < split && m.range.upperBound > split {
                let text = String(chars[m.range])
                out.append(Finding(kind: m.kind, rect: a.rect(forCharacters: m.range.lowerBound..<split), confidence: m.confidence, text: text))
                out.append(Finding(kind: m.kind, rect: b.rect(forCharacters: 0..<(m.range.upperBound - split)), confidence: m.confidence, text: text))
            }
        }
        return out
    }

    /// 同类且高度重叠的只留置信度最高的
    func deduplicate(_ items: [Finding]) -> [Finding] {
        var kept: [Finding] = []
        for f in items.sorted(by: { $0.confidence > $1.confidence }) {
            if kept.contains(where: { $0.kind == f.kind && $0.rect.iou(f.rect) > 0.7 }) { continue }
            kept.append(f)
        }
        return kept
    }
}
