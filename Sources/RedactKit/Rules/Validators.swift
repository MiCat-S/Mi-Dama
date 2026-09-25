// 号码校验：命中校验的给高置信度，结构对但校验失败（常见于 OCR 错一位）的给中等置信度，照样打码
enum Validators {
    /// 18 位居民身份证校验码（GB 11643-1999）
    static func chineseIDChecksum(_ id: String) -> Bool {
        let chars = Array(id)
        guard chars.count == 18 else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let checks: [Character] = ["1", "0", "X", "9", "8", "7", "6", "5", "4", "3", "2"]
        var sum = 0
        for i in 0..<17 {
            guard let d = chars[i].wholeNumberValue, chars[i].isASCIIDigit else { return false }
            sum += d * weights[i]
        }
        return Character(chars[17].uppercased()) == checks[sum % 11]
    }

    /// Luhn（银行卡）
    static func luhn(_ number: String) -> Bool {
        var sum = 0
        for (i, c) in number.reversed().enumerated() {
            guard var d = c.wholeNumberValue, c.isASCIIDigit else { return false }
            if i % 2 == 1 {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
        }
        return sum % 10 == 0
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { p in
            guard let n = Int(p), p.count <= 3 else { return false }
            return (0...255).contains(n) && !(p.count > 1 && p.hasPrefix("0"))
        }
    }
}
