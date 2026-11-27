import Foundation

/// 一条规律：给一个 11 位号码，返回命中的位置（没命中返回 nil）
struct Rule: Identifiable, Hashable {
    let id: String
    let name: String
    let example: String
    let baseScore: Int
    /// 命中范围较宽（会扫出很多号），界面上给提示
    let isBroad: Bool
    let match: @Sendable ([Int]) -> Range<Int>?

    static func == (l: Rule, r: Rule) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum RuleBook {
    /// 只在号码后 8 位里找规律（前 3 位是号段，没意义）
    static let searchStart = 3

    static let builtIn: [Rule] = [
        Rule(id: "aaaa", name: "AAAA+ 四连以上", example: "8888", baseScore: 90, isBroad: false) { d in
            run(d, minLen: 4) { $0 == $1 }
        },
        Rule(id: "abcdabcd", name: "ABCDABCD", example: "13141314", baseScore: 95, isBroad: false) { d in
            for i in searchStart...(d.count - 8) where Array(d[i..<i+4]) == Array(d[i+4..<i+8]) {
                if Set(d[i..<i+4]).count > 1 { return i..<i+8 }
            }
            return nil
        },
        Rule(id: "abcde", name: "ABCDE 五连顺", example: "12345", baseScore: 85, isBroad: false) { d in
            run(d, minLen: 5) { $1 == $0 + 1 }
        },
        Rule(id: "edcba", name: "EDCBA 五连倒顺", example: "54321", baseScore: 80, isBroad: false) { d in
            run(d, minLen: 5) { $1 == $0 - 1 }
        },
        Rule(id: "aabbcc", name: "AABBCC", example: "112233", baseScore: 75, isBroad: false) { d in
            window(d, 6) { w in w[0] == w[1] && w[2] == w[3] && w[4] == w[5] && Set([w[0], w[2], w[4]]).count == 3 }
        },
        Rule(id: "abccba", name: "ABCCBA 对称", example: "123321", baseScore: 70, isBroad: false) { d in
            window(d, 6) { w in w[0] == w[5] && w[1] == w[4] && w[2] == w[3] && Set([w[0], w[1], w[2]]).count == 3 }
        },
        Rule(id: "few", name: "全号 ≤3 种数字", example: "18611611166", baseScore: 80, isBroad: false) { d in
            Set(d[searchStart...]).count <= 3 ? searchStart..<d.count : nil
        },
        Rule(id: "birthday", name: "生日号 (尾 8 位)", example: "19990101", baseScore: 60, isBroad: false) { d in
            let tail = d.suffix(8).map { String($0) }.joined()
            guard let y = Int(tail.prefix(4)), let m = Int(tail.dropFirst(4).prefix(2)), let day = Int(tail.suffix(2)) else { return nil }
            let thisYear = Calendar.current.component(.year, from: Date())
            guard (1950...thisYear).contains(y), (1...12).contains(m), (1...31).contains(day) else { return nil }
            return (d.count - 8)..<d.count
        },
        Rule(id: "abab", name: "ABAB", example: "1212", baseScore: 55, isBroad: false) { d in
            window(d, 4) { w in w[0] == w[2] && w[1] == w[3] && w[0] != w[1] }
        },
        Rule(id: "aabb", name: "AABB", example: "1122", baseScore: 50, isBroad: false) { d in
            window(d, 4) { w in w[0] == w[1] && w[2] == w[3] && w[0] != w[2] }
        },
        Rule(id: "five", name: "某数字出现 ≥5 次", example: "1x8x8x88x8", baseScore: 50, isBroad: true) { d in
            var counts = [Int](repeating: 0, count: 10)
            for x in d[searchStart...] { counts[x] += 1 }
            return counts.contains { $0 >= 5 } ? searchStart..<d.count : nil
        },
        Rule(id: "abcd", name: "ABCD 四连顺", example: "1234", baseScore: 45, isBroad: true) { d in
            run(d, minLen: 4) { $1 == $0 + 1 }
        },
        Rule(id: "aaa", name: "AAA 三连", example: "666", baseScore: 40, isBroad: true) { d in
            run(d, minLen: 3) { $0 == $1 }
        },
    ]

    /// 默认勾选的常用规律
    static let defaultEnabled: Set<String> = ["aaaa", "abcdabcd", "abcde", "edcba", "aabbcc", "few"]

    // MARK: - 自定义模板
    /// 支持：
    /// - `*8888`  以 8888 结尾
    /// - `AABB` / `ABAB` 字母代表不同数字，可出现在任意位置
    /// - `?` 任意一位，数字原样匹配，如 `*1?14`
    /// - `re:正则` 直接写正则（高级）
    static func customRule(_ raw: String) -> Rule? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("re:") {
            guard let re = try? NSRegularExpression(pattern: String(t.dropFirst(3))) else { return nil }
            return Rule(id: "custom:" + t, name: "自定义 " + t, example: t, baseScore: 70, isBroad: false) { d in
                let s = d.map { String($0) }.joined()
                guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) else { return nil }
                return m.range.location..<(m.range.location + max(m.range.length, 1))
            }
        }
        let anchoredEnd = t.hasPrefix("*")
        let pattern = Array(anchoredEnd ? String(t.dropFirst()) : t)
        guard !pattern.isEmpty, pattern.count <= 11,
              pattern.allSatisfy({ $0.isNumber || $0 == "?" || ($0.isLetter && $0.isASCII) }) else { return nil }
        let p = pattern.map { Character($0.uppercased()) }
        return Rule(id: "custom:" + t, name: "自定义 " + t, example: t, baseScore: 70, isBroad: false) { d in
            let n = p.count
            let lo = max(0, min(searchStart, d.count - n))
            let starts: [Int] = anchoredEnd ? [d.count - n] : Array(lo...(d.count - n))
            for i in starts where i >= 0 {
                if templateMatches(p, Array(d[i..<i+n])) { return i..<i+n }
            }
            return nil
        }
    }

    private static func templateMatches(_ p: [Character], _ w: [Int]) -> Bool {
        var bind: [Character: Int] = [:]
        for (c, x) in zip(p, w) {
            if c == "?" { continue }
            if let v = c.wholeNumberValue { if v != x { return false }; continue }
            if let b = bind[c] { if b != x { return false } }
            else {
                if bind.values.contains(x) { return false }   // 不同字母必须是不同数字
                bind[c] = x
            }
        }
        return true
    }

    // MARK: - 辅助
    /// 找最长的一段连续满足 step(前, 后) 的数字，长度 ≥ minLen
    private static func run(_ d: [Int], minLen: Int, _ step: (Int, Int) -> Bool) -> Range<Int>? {
        var best: Range<Int>? = nil
        var start = searchStart
        for i in (searchStart + 1)...d.count {
            if i < d.count && step(d[i - 1], d[i]) { continue }
            if i - start >= minLen, (best == nil || i - start >= best!.count) { best = start..<i }
            start = i
        }
        return best
    }

    /// 找最靠后的一个长度为 n 的窗口满足条件（越靠尾越值钱）
    private static func window(_ d: [Int], _ n: Int, _ ok: ([Int]) -> Bool) -> Range<Int>? {
        guard d.count - n >= searchStart else { return nil }
        for i in stride(from: d.count - n, through: searchStart, by: -1) where ok(Array(d[i..<i+n])) {
            return i..<i+n
        }
        return nil
    }
}

/// 把号码过一遍选中的规律，算靓号分
struct Evaluator {
    let rules: [Rule]
    let excludedDigits: Set<Int>

    func evaluate(_ number: String) -> (matches: [RuleMatch], score: Int)? {
        let d = number.compactMap { $0.wholeNumberValue }
        guard d.count == 11 else { return nil }
        if !excludedDigits.isEmpty, d.suffix(8).contains(where: { excludedDigits.contains($0) }) { return nil }

        var ms: [RuleMatch] = []
        for r in rules {
            guard let range = r.match(d) else { continue }
            // 在尾号的规律更值钱
            let atTail = range.upperBound == 11
            let s = atTail ? r.baseScore + 15 : r.baseScore
            ms.append(RuleMatch(ruleName: r.name, range: range, score: s))
        }
        guard !ms.isEmpty else { return nil }
        ms.sort { $0.score > $1.score }
        let score = min(100 + 50, ms[0].score + 5 * (ms.count - 1))
        return (ms, score)
    }
}
