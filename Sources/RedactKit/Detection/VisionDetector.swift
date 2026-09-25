// Vision 识别：一次 perform 同时跑 OCR、人脸、条码；长截图分段识别
import CoreImage
import CoreML
import Vision

/// 一行 OCR 结果（像素坐标，左上原点）
public struct RecognizedLine: @unchecked Sendable {
    public let text: String
    public let confidence: Float
    public let rect: CGRect
    let candidate: VNRecognizedText
    /// 该行所在分段在整图中的位置（左上原点），用于把子串框换算回整图
    let tileRect: CGRect

    /// 字符范围 → 像素框。Vision 的子串框在中文无空格时可能退化成整行，
    /// 这时按字符宽度比例在行框内插值
    public func rect(forCharacters range: Range<Int>) -> CGRect {
        let chars = Array(text)
        guard !chars.isEmpty, range.lowerBound >= 0, range.upperBound <= chars.count else { return rect }
        if range.count == chars.count { return rect }

        let start = text.index(text.startIndex, offsetBy: range.lowerBound)
        let end = text.index(text.startIndex, offsetBy: range.upperBound)
        if let box = try? candidate.boundingBox(for: start..<end)?.boundingBox {
            let r = VNImageRectForNormalizedRect(box, Int(tileRect.width), Int(tileRect.height))
                .flippedVertically(inHeight: tileRect.height)
                .offsetBy(dx: tileRect.minX, dy: tileRect.minY)
            let coversWholeLine = r.width > rect.width * 0.9
            let expectedFraction = weight(chars[range]) / weight(chars[...])
            if !coversWholeLine || expectedFraction > 0.8 { return r }
        }
        // 兜底：按字符宽度插值（中文 1、半角 0.55），左右各留半个字的余量
        let total = weight(chars[...])
        let x0 = rect.minX + rect.width * weight(chars[..<range.lowerBound]) / total
        let x1 = rect.minX + rect.width * weight(chars[..<range.upperBound]) / total
        let slack = rect.width / total * 0.5
        return CGRect(x: max(rect.minX, x0 - slack), y: rect.minY,
                      width: min(rect.maxX, x1 + slack) - max(rect.minX, x0 - slack), height: rect.height)
    }

    private func weight(_ chars: ArraySlice<Character>) -> CGFloat {
        chars.reduce(0) { $0 + ($1.isASCII ? 0.55 : 1) }
    }
}

public struct VisionResult: Sendable {
    public var lines: [RecognizedLine] = []
    public var faces: [(rect: CGRect, confidence: Float)] = []
    public var codes: [(rect: CGRect, isQR: Bool)] = []
}

public enum VisionDetector {
    /// 分段高度 = 宽度 × 该系数；长截图整张送进去会被 Vision 缩小，小字就丢了
    static let tileAspect: CGFloat = 2.2

    public static func detect(_ image: CIImage) throws -> VisionResult {
        let image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let W = image.extent.width, H = image.extent.height
        var result = VisionResult()

        // 人脸、二维码整图一次
        let face = VNDetectFaceRectanglesRequest()
        let code = VNDetectBarcodesRequest()
        preferCPUInSimulator(face)
        preferCPUInSimulator(code)
        try VNImageRequestHandler(ciImage: image).perform([face, code])
        let toPixels = { (box: CGRect) in
            VNImageRectForNormalizedRect(box, Int(W), Int(H)).flippedVertically(inHeight: H)
        }
        result.faces = (face.results ?? []).map { (toPixels($0.boundingBox), $0.confidence) }
        result.codes = (code.results ?? []).map { (toPixels($0.boundingBox), $0.symbology == .qr) }

        // OCR 按竖向分段，段间重叠 8%，重叠区的重复行去掉
        let tileH = min(H, W * tileAspect)
        let step = max(1, tileH * 0.92)
        var top: CGFloat = 0
        while true {
            let tile = CGRect(x: 0, y: top, width: W, height: min(tileH, H - top))
            let lines = try recognizeText(in: image, tile: tile, imageHeight: H)
            for line in lines where !result.lines.contains(where: { $0.rect.iou(line.rect) > 0.5 && $0.text == line.text }) {
                result.lines.append(line)
            }
            if tile.maxY >= H { break }
            top += step
        }
        return result
    }

    /// 模拟器没有神经网络引擎，Vision 默认设备会报 "Could not create inference context"，
    /// 只在模拟器里把每个阶段都指定到 CPU；真机和 macOS 不受影响
    private static func preferCPUInSimulator(_ request: VNRequest) {
        #if targetEnvironment(simulator)
        guard let stages = try? request.supportedComputeStageDevices else { return }
        for (stage, devices) in stages {
            if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        #endif
    }

    private static func recognizeText(in image: CIImage, tile: CGRect, imageHeight H: CGFloat) throws -> [RecognizedLine] {
        let ciTile = tile.flippedVertically(inHeight: H)
        let cropped = image.cropped(to: ciTile)
            .transformed(by: CGAffineTransform(translationX: -ciTile.minX, y: -ciTile.minY))
        let ocr = VNRecognizeTextRequest()
        ocr.recognitionLevel = .accurate
        ocr.recognitionLanguages = ["zh-Hans", "en-US"]
        ocr.usesLanguageCorrection = false   // 否则会把号码"纠正"成单词
        preferCPUInSimulator(ocr)
        try VNImageRequestHandler(ciImage: cropped).perform([ocr])

        return (ocr.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            let r = VNImageRectForNormalizedRect(obs.boundingBox, Int(tile.width), Int(tile.height))
                .flippedVertically(inHeight: tile.height)
                .offsetBy(dx: tile.minX, dy: tile.minY)
            return RecognizedLine(text: top.string, confidence: top.confidence, rect: r, candidate: top, tileRect: tile)
        }
    }
}
