// 撤销 / 重做：保存编辑前的完整状态快照（状态是不可变值，快照很便宜）
package com.example.redact.core

class EditHistory<S>(
    /** 最多保留的撤销步数 */
    val limit: Int = 100,
) {
    private val undoStack = ArrayDeque<S>()
    private val redoStack = ArrayDeque<S>()

    val undoStates: List<S> get() = undoStack.toList()
    val canUndo get() = undoStack.isNotEmpty()
    val canRedo get() = redoStack.isNotEmpty()

    /** 记录一次编辑；没有实际变化时忽略。新的编辑会清空重做栈 */
    fun record(before: S, after: S) {
        if (before == after) return
        undoStack.addLast(before)
        while (undoStack.size > limit) undoStack.removeFirst()
        redoStack.clear()
    }

    /** 返回要恢复到的状态；current 进入重做栈 */
    fun undo(current: S): S? {
        val previous = undoStack.removeLastOrNull() ?: return null
        redoStack.addLast(current)
        return previous
    }

    fun redo(current: S): S? {
        val next = redoStack.removeLastOrNull() ?: return null
        undoStack.addLast(current)
        return next
    }

    fun reset() {
        undoStack.clear()
        redoStack.clear()
    }
}
