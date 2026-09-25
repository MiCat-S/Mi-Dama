import ChatSynth
import CoreImage
import Testing
@testable import RedactKit

/// 用合成截图做回归：头像 / 昵称的召回率不能掉
@Suite("聊天截图布局")
struct ChatLayoutTests {
    @Test(arguments: [
        SynthConfig(widthPx: 1170, scale: 3, dark: false, group: true, seed: 101),
        SynthConfig(widthPx: 1290, scale: 3, dark: true, group: true, seed: 102),
        SynthConfig(widthPx: 750, scale: 2, dark: false, group: true, circleAvatars: true, seed: 103),
        SynthConfig(widthPx: 1080, scale: 2.75, dark: true, group: false, seed: 104),
    ])
    func 头像和昵称都能找到(cfg: SynthConfig) throws {
        let synth = ChatSynth.render(cfg)
        let findings = try DetectionPipeline().detect(CIImage(cgImage: synth.image))
        for (name, kind) in [("avatar", FindingKind.chatAvatar), ("nickname", .chatNickname)] {
            let truth = synth.labels.filter { $0.kind == name }.map(\.rect)
            let found = findings.filter { $0.kind == kind && $0.isEnabled }.map(\.rect)
            let missed = truth.filter { t in !found.contains { t.iou($0) >= 0.4 || t.intersection($0).area >= t.area * 0.9 } }
            #expect(missed.isEmpty, "\(name) 漏检 \(missed.count)/\(truth.count)")
        }
    }

    @Test func 返回文字行供文字工具使用() throws {
        let synth = ChatSynth.render(SynthConfig(widthPx: 1170, scale: 3, seed: 105))
        let image = CIImage(cgImage: synth.image)
        let result = try DetectionPipeline().analyze(image)
        #expect(result.textLines.count >= 5)
        #expect(result.textLines.allSatisfy { image.extent.contains($0.rect.insetBy(dx: 2, dy: 2)) })
        // 标注的昵称都能在文字行里找到对应的行
        for nick in synth.labels.filter({ $0.kind == "nickname" }).map(\.rect) {
            #expect(result.textLines.contains { $0.rect.intersects(nick) })
        }
    }

    @Test func 普通照片不做聊天布局分析() throws {
        // 渐变图：没有统一的页面背景色，不应该冒出头像 / 昵称
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 800, y: 1600),
            "inputColor0": CIColor.red, "inputColor1": CIColor.blue,
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 800, height: 1600))
        let findings = try DetectionPipeline().detect(gradient)
        #expect(!findings.contains { [.chatAvatar, .chatNickname, .chatTitle].contains($0.kind) })
    }
}
