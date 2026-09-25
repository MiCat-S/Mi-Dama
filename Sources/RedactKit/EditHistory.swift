// 撤销 / 重做：保存编辑前的完整状态快照（状态是值类型，快照很便宜）
public struct EditHistory<State: Equatable> {
    public private(set) var undoStack: [State] = []
    public private(set) var redoStack: [State] = []
    /// 最多保留的撤销步数
    public var limit: Int

    public init(limit: Int = 100) {
        self.limit = limit
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// 记录一次编辑；没有实际变化时忽略。新的编辑会清空重做栈
    public mutating func record(before: State, after: State) {
        guard before != after else { return }
        undoStack.append(before)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    /// 返回要恢复到的状态；current 进入重做栈
    public mutating func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    public mutating func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
