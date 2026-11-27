import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 数据源协议：以后加移动 / 电信，只需要再写一个实现
protocol NumberSource: Sendable {
    var name: String { get }
    func fetch(_ target: Target) async throws -> [String]
}

enum SourceError: Error, LocalizedError {
    case http(Int)
    case badResponse
    case empty(String)   // 接口正常返回，但没有号码（无号或被软限流）

    var errorDescription: String? {
        switch self {
        case .http(let c): return "HTTP \(c)"
        case .badResponse: return "返回格式不对"
        case .empty(let code): return "返回空列表（\(code)）"
        }
    }
}

/// 中国联通 m.10010.com 选号接口（每次随机返回约 100 个号）
struct UnicomSource: NumberSource {
    let name = "中国联通"

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            "Referer": "https://m.10010.com/",
        ]
        return URLSession(configuration: c)
    }()

    func fetch(_ target: Target) async throws -> [String] {
        var comps = URLComponents(string: "https://m.10010.com/NumApp/NumberCenter/qryNum")!
        comps.queryItems = [
            .init(name: "callback", value: "jsonp_queryMoreNums"),
            .init(name: "provinceCode", value: target.province.code),
            .init(name: "cityCode", value: target.city.code),
            .init(name: "monthFeeLimit", value: "0"),
            .init(name: "groupKey", value: target.province.groupKey),
            .init(name: "searchCategory", value: "3"),
            .init(name: "net", value: "01"),
            .init(name: "amounts", value: "200"),
            .init(name: "codeTypeCode", value: ""),
            .init(name: "searchValue", value: ""),
            .init(name: "qryType", value: "02"),
            .init(name: "goodsNet", value: "4"),
            .init(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]
        let (data, resp) = try await Self.session.data(from: comps.url!)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw SourceError.http(http.statusCode) }
        return try Self.parse(data)
    }

    /// 返回是 JSONP：jsonp_queryMoreNums({...})
    /// numArray 每 12 个元素一组，第一个是号码
    static func parse(_ data: Data) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8),
              let l = text.firstIndex(of: "("), let r = text.lastIndex(of: ")"), l < r,
              let json = try JSONSerialization.jsonObject(with: Data(text[text.index(after: l)..<r].utf8)) as? [String: Any]
        else { throw SourceError.badResponse }
        let code = json["code"] as? String ?? "?"
        guard let arr = json["numArray"] as? [Any], !arr.isEmpty else { throw SourceError.empty(code) }
        var out: [String] = []
        for v in arr {
            let n: Int64? = (v as? NSNumber)?.int64Value ?? (v as? String).flatMap { Int64($0) }
            if let n, n >= 10_000_000_000, n < 20_000_000_000 { out.append(String(n)) }
        }
        if out.isEmpty { throw SourceError.empty(code) }
        return out
    }
}
