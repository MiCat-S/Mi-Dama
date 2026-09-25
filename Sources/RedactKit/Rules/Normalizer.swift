// OCR 文本归一化：让 "6222 0212 3456 7894"、"１３８ＯＯ１３８０００" 这类写法也能被规则命中，
// 同时记住每个归一化字符来自原文哪个字符，命中后能精确映射回字符框
import Foundation

struct NormalizedText {
    /// 归一化后的文本
    let text: String
    /// 归一化文本第 i 个字符 → 原文字符下标
    let origin: [Int]
    /// 归一化文本 UTF-16 下标 → 字符下标（NSRegularExpression 返回的是 UTF-16 范围）
    private let utf16ToChar: [Int]

    init(characters: [Character], origin: [Int]) {
        self.text = String(characters)
        self.origin = origin
        var map: [Int] = []
        map.reserveCapacity(characters.count)
        for (i, c) in characters.enumerated() {
            map.append(contentsOf: repeatElement(i, count: c.utf16.count))
        }
        self.utf16ToChar = map
    }

    /// 把一次正则命中（UTF-16 范围）映射回原文字符范围
    func originalRange(of range: NSRange) -> Range<Int>? {
        guard range.location != NSNotFound, range.length > 0,
              range.location + range.length <= utf16ToChar.count else { return nil }
        let first = utf16ToChar[range.location]
        let last = utf16ToChar[range.location + range.length - 1]
        return origin[first]..<(origin[last] + 1)
    }
}

enum Normalizer {
    /// 数字之间可以去掉的分组分隔符
    private static let digitSeparators: Set<Character> = [" ", "\u{3000}", "-", "－", "·", "•", "—", "_"]

    /// - Parameter stripSeparators: 是否去掉数字之间的分隔符。
    ///   两种都要跑一遍：去掉能命中分组号码，不去掉才能把两个相邻号码分开。
    static func normalize(_ s: String, stripSeparators: Bool) -> NormalizedText {
        let chars = s.map(widen)
        var out: [Character] = []
        var origin: [Int] = []
        out.reserveCapacity(chars.count)

        for (i, raw) in chars.enumerated() {
            var c = raw
            let prev: Character? = out.last
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            // 数字上下文里的 OCR 形近字：一侧是数字、另一侧不是字母时才替换，避免破坏英文单词
            if let fixed = digitLookalike(c) {
                let prevDigit = prev?.isASCIIDigit == true
                let nextDigit = next?.isASCIIDigit == true
                let prevLetter = prev?.isASCIILetter == true
                let nextLetter = next.map { $0.isASCIILetter && digitLookalike($0) == nil } == true
                if (prevDigit && !nextLetter) || (nextDigit && !prevLetter) { c = fixed }
            }

            if stripSeparators, digitSeparators.contains(c),
               prev?.isASCIIDigit == true, next.map(isDigitOrLookalike) == true {
                continue
            }
            out.append(c)
            origin.append(i)
        }
        return NormalizedText(characters: out, origin: origin)
    }

    /// 全角 → 半角（数字、字母、常用符号）
    private static func widen(_ c: Character) -> Character {
        guard c.unicodeScalars.count == 1, let v = c.unicodeScalars.first?.value else { return c }
        if (0xFF01...0xFF5E).contains(v), let u = Unicode.Scalar(v - 0xFEE0) { return Character(u) }
        return c
    }

    private static func digitLookalike(_ c: Character) -> Character? {
        switch c {
        case "O", "o", "〇": return "0"
        case "l", "I", "|", "ǀ": return "1"
        default: return nil
        }
    }

    private static func isDigitOrLookalike(_ c: Character) -> Bool {
        c.isASCIIDigit || digitLookalike(c) != nil
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
    var isASCIILetter: Bool { isASCII && isLetter }
}
