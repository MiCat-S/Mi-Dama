import CoreImage
import Testing
@testable import RedactKit

private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CIImage {
    CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
}

private func close(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 0.01) -> Bool {
    abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
}

@Suite("拼图")
struct CompositionTests {
    let context = CIContext()

    @Test func 上下拼统一成较窄的宽度且只缩不放() {
        let c = Composition(partSizes: [CGSize(width: 1000, height: 2000), CGSize(width: 500, height: 800)],
                            layout: MergeLayout(axis: .vertical, gap: .none, order: [0, 1]))
        #expect(c.canvasSize == CGSize(width: 500, height: 1800))
        #expect(c.frames == [CGRect(x: 0, y: 0, width: 500, height: 1000), CGRect(x: 0, y: 1000, width: 500, height: 800)])
    }

    @Test func 左右拼的间距和交换顺序() {
        let shot = CGSize(width: 1290, height: 2796)
        let c = Composition(partSizes: [shot, shot], layout: MergeLayout(axis: .horizontal, gap: .thin, order: [1, 0]))
        // 间距 = 最短图边 1290 × 2% ≈ 26
        #expect(c.canvasSize == CGSize(width: 1290 * 2 + 26, height: 2796))
        #expect(c.frames[1].minX == 0)
        #expect(c.frames[0].minX == CGFloat(1290 + 26))
    }

    @Test func 顺序不合法时按输入顺序() {
        let c = Composition(partSizes: [CGSize(width: 10, height: 10), CGSize(width: 10, height: 10)],
                            layout: MergeLayout(axis: .vertical, gap: .none, order: [0, 0]))
        #expect(c.layout.order == [0, 1])
        #expect(c.frames[1].minY == 10)
    }

    @Test func 超过像素上限整体等比缩小() {
        let long = CGSize(width: 1290, height: 20000)
        let c = Composition(partSizes: [long, long], layout: MergeLayout(axis: .vertical, gap: .none, order: [0, 1]))
        #expect(c.canvasSize.width * c.canvasSize.height <= Composition.maxPixels)
        #expect(c.canvasSize.width > 800)
        #expect(c.frames[1].minY == c.frames[0].maxY)
        // 比例不变（取整误差以内）
        #expect(abs(c.frames[0].height / c.frames[0].width - 20000 / 1290) < 0.01)
    }

    @Test func 默认布局() {
        let portrait = CGSize(width: 1290, height: 2796), landscape = CGSize(width: 4032, height: 3024)
        #expect(MergeLayout.defaultAxis(for: [portrait, portrait]) == .horizontal)
        #expect(MergeLayout.defaultAxis(for: [portrait, landscape]) == .vertical)
        #expect(MergeLayout.defaultAxis(for: [landscape, landscape]) == .vertical)
    }

    @Test func 区域换算往返不变() {
        let c = Composition(partSizes: [CGSize(width: 1000, height: 2000), CGSize(width: 500, height: 800)],
                            layout: MergeLayout(axis: .vertical, gap: .thick, order: [1, 0]))
        let r = CGRect(x: 100, y: 300, width: 200, height: 50)
        let canvas = c.toCanvas(r, from: 0)
        #expect(close(canvas, CGRect(x: 50, y: c.frames[0].minY + 150, width: 100, height: 25)))
        let back = c.toParts(canvas)
        #expect(back.count == 1 && back[0].part == 0 && close(back[0].rect, r))
    }

    @Test func 单张的勾选和效果带到拼图上() {
        let c = Composition(partSizes: [CGSize(width: 100, height: 100), CGSize(width: 100, height: 100)],
                            layout: MergeLayout(axis: .horizontal, gap: .none, order: [0, 1]))
        let off = Finding(kind: .phone, rect: CGRect(x: 10, y: 10, width: 20, height: 5), confidence: 0.9, isEnabled: false)
        let styled = Finding(kind: .face, rect: CGRect(x: 0, y: 0, width: 50, height: 50), confidence: 0.9, style: .solid)
        let merged = c.findings(from: [[off], [styled]])
        #expect(merged.map(\.id) == [off.id, styled.id])
        #expect(merged[0].isEnabled == false && merged[0].rect == off.rect)
        #expect(merged[1].style == .solid && merged[1].rect == CGRect(x: 100, y: 0, width: 50, height: 50))
    }

    @Test func 换布局时跨接缝的框拆成两段跟着图走() {
        let sizes = [CGSize(width: 100, height: 200), CGSize(width: 100, height: 200)]
        let vertical = Composition(partSizes: sizes, layout: MergeLayout(axis: .vertical, gap: .none, order: [0, 1]))
        let horizontal = Composition(partSizes: sizes, layout: MergeLayout(axis: .horizontal, gap: .thin, order: [0, 1]))
        // 马克笔框从上图底部拉到下图顶部
        let box = Finding(kind: .manual, rect: CGRect(x: 20, y: 180, width: 60, height: 40), confidence: 1, style: .blur)
        let moved = vertical.remap([box], to: horizontal)
        #expect(moved.count == 2)
        #expect(moved[0].id == box.id)
        #expect(close(moved[0].rect, CGRect(x: 20, y: 180, width: 60, height: 20)))
        #expect(close(moved[1].rect, CGRect(x: horizontal.frames[1].minX + 20, y: 0, width: 60, height: 20)))
        #expect(moved.allSatisfy { $0.kind == .manual && $0.style == .blur && $0.isEnabled })
        // 换回去：两段各自回到原位，合起来盖住原来的范围
        let back = horizontal.remap(moved, to: vertical)
        #expect(close(back[0].rect.union(back[1].rect), box.rect))
    }

    @Test func 完全落在间距里的框换布局时丢掉() {
        let sizes = [CGSize(width: 100, height: 100), CGSize(width: 100, height: 100)]
        let a = Composition(partSizes: sizes, layout: MergeLayout(axis: .vertical, gap: .thick, order: [0, 1]))
        let b = Composition(partSizes: sizes, layout: MergeLayout(axis: .horizontal, gap: .none, order: [0, 1]))
        let inGap = Finding(kind: .manual, rect: CGRect(x: 10, y: 101, width: 50, height: 3), confidence: 1)
        #expect(a.remap([inGap], to: b).isEmpty)
    }

    @Test func 合成的像素位置和间距颜色() {
        let c = Composition(partSizes: [CGSize(width: 100, height: 200), CGSize(width: 50, height: 100)],
                            layout: MergeLayout(axis: .vertical, gap: .thick, background: .black, order: [0, 1]))
        let out = RGBAImage(c.compose([solid(1, 0, 0, 100, 200), solid(0, 0, 1, 50, 100)]), context: context)
        #expect(out.width == Int(c.canvasSize.width) && out.height == Int(c.canvasSize.height))
        let top = out.rgb(50, Int(c.frames[0].midY)), bottom = out.rgb(50, Int(c.frames[1].midY))
        let gap = out.rgb(50, Int(c.frames[0].maxY) + 1)
        #expect(top.x > 250 && top.z < 5)
        #expect(bottom.z > 250 && bottom.x < 5)
        #expect(gap.x < 5 && gap.y < 5 && gap.z < 5)
        // 接缝处不混色：第二张图的第一行仍是纯蓝
        let edge = out.rgb(50, Int(c.frames[1].minY))
        #expect(edge.z > 250 && edge.x < 5)
    }

    @Test func 拼图上打码用的是换算后的位置() {
        let c = Composition(partSizes: [CGSize(width: 200, height: 100), CGSize(width: 400, height: 200)],
                            layout: MergeLayout(axis: .vertical, gap: .none, order: [1, 0]))
        // 第二张图（缩小一半后放在上面）里的一处
        let f = Finding(kind: .phone, rect: CGRect(x: 100, y: 50, width: 200, height: 100), confidence: 1, style: .solid)
        var redactor = Redactor(context: context)
        redactor.fillColor = CIColor(red: 0, green: 1, blue: 0)
        let merged = c.compose([solid(1, 1, 1, 200, 100), solid(1, 1, 1, 400, 200)])
        let out = RGBAImage(redactor.render(merged, findings: c.findings(from: [[], [f]])), context: context)
        let inside = out.rgb(100, 50), outside = out.rgb(10, 150)
        #expect(inside.y > 250 && inside.x < 5)
        #expect(outside.x > 250 && outside.y > 250)
    }
}
