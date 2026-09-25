import CoreGraphics
import Testing
@testable import RedactKit

@Suite("撤销 / 重做")
struct EditHistoryTests {
    @Test func 撤销再重做回到原状态() {
        var h = EditHistory<Int>()
        var state = 0
        for next in [1, 2, 3] {
            h.record(before: state, after: next)
            state = next
        }
        state = h.undo(current: state)!   // 2
        state = h.undo(current: state)!   // 1
        #expect(state == 1)
        state = h.redo(current: state)!   // 2
        #expect(state == 2)
        #expect(h.canUndo && h.canRedo)
    }

    @Test func 新编辑清空重做栈() {
        var h = EditHistory<Int>()
        h.record(before: 0, after: 1)
        _ = h.undo(current: 1)
        #expect(h.canRedo)
        h.record(before: 0, after: 5)
        #expect(!h.canRedo)
    }

    @Test func 没有变化不记录且有上限() {
        var h = EditHistory<Int>(limit: 3)
        h.record(before: 7, after: 7)
        #expect(!h.canUndo)
        for i in 0..<10 { h.record(before: i, after: i + 1) }
        #expect(h.undoStack == [7, 8, 9])
    }

    @Test func 识别框整体快照可以撤销() {
        struct State: Equatable { var findings: [Finding] }
        let a = Finding(kind: .phone, rect: CGRect(x: 0, y: 0, width: 10, height: 10), confidence: 0.9)
        var h = EditHistory<State>()
        var s = State(findings: [a])
        let before = s
        s.findings[0].isEnabled = false
        h.record(before: before, after: s)
        s = h.undo(current: s)!
        #expect(s.findings[0].isEnabled)
    }
}
