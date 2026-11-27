import Foundation

struct City: Hashable, Codable, Identifiable {
    let name: String
    let code: String
    var id: String { code }
}

struct Province: Hashable, Codable, Identifiable {
    let name: String
    let code: String
    let groupKey: String
    let cities: [City]
    var id: String { code }
}

/// 一个扫描目标：某省某市
struct Target: Hashable {
    let province: Province
    let city: City
}

/// 号码命中的一条规律
struct RuleMatch: Hashable, Codable {
    let ruleName: String
    let range: Range<Int>   // 在 11 位号码字符串中的位置
    let score: Int
}

/// 一个命中的号码
struct Hit: Identifiable, Hashable, Codable {
    let number: String
    let provinceName: String
    let cityName: String
    let matches: [RuleMatch]
    let score: Int
    let foundAt: Date
    var favorite: Bool = false

    var id: String { number }
    var primaryRule: String { matches.first?.ruleName ?? "" }
    /// 选号池的号会被别人拿走，超过 2 小时的结果标记为可能失效
    var isStale: Bool { Date().timeIntervalSince(foundAt) > 2 * 3600 }

    /// 3-4-4 分段显示
    var formatted: String {
        let c = Array(number)
        guard c.count == 11 else { return number }
        return String(c[0..<3]) + " " + String(c[3..<7]) + " " + String(c[7..<11])
    }
}

enum Speed: String, CaseIterable, Identifiable, Codable {
    case steady = "稳"
    case fast = "快"
    var id: String { rawValue }

    var maxConcurrency: Int { self == .steady ? 4 : 10 }
    /// 每个并发通道两次请求之间的最小间隔（秒）
    var minDelay: Double { self == .steady ? 0.6 : 0.2 }
}

struct HitGroup: Identifiable {
    let rule: String
    let hits: [Hit]
    var id: String { rule }
}
