import Foundation
import AppKit
import UserNotifications
import Observation
import UniformTypeIdentifiers
import Network

@Observable
@MainActor
final class AppModel {
    // MARK: 选择
    var selectedCities: Set<String> = []          // 城市 code
    var enabledRules: Set<String> = RuleBook.defaultEnabled
    var customPatterns: [String] = []
    var excludeText: String = "4"
    var speed: Speed = .steady
    var watchKeywords: [String] = ["8888", "520"]
    var alertHighScore = true
    // 高级：手动控制（参考菠萝的线程 / 间隔 / 模式）
    var manualControl = false
    var manualConcurrency = 8
    var manualIntervalMs = 300
    var scanMode: ScanMode = .spaced

    // MARK: 结果
    var hits: [Hit] = []
    var selectedHitID: String?
    var searchText: String = ""
    var log: [String] = []
    var ruleFilter: String?            // 中栏按规律筛选，nil = 全部
    var showLog = false
    var showRegionPicker = false
    private(set) var isOnline = true
    private(set) var updateURL: URL?
    var lastExportDate: Date?

    /// 联通官方选号页（num.10010.com 会跳到这里）
    static let orderURL = URL(string: "https://card.10010.com/numberPro/numberH5Page")!

    // MARK: 状态
    private(set) var isRunning = false
    private(set) var checkedCount = 0
    private(set) var perMinute = 0
    private(set) var concurrency = 1
    private(set) var statusNote = ""
    private(set) var exhaustedCities = 0
    private(set) var receivedCount = 0   // 接口返回的号码总数（含重复）
    private(set) var emptyCount = 0
    private(set) var failCount = 0

    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var recent: [(Date, Int)] = []
    @ObservationIgnored private let monitor = NWPathMonitor()
    private let source: NumberSource = UnicomSource()

    let provinces = RegionData.provinces

    init() {
        load()
        if selectedCities.isEmpty, let gd = provinces.first(where: { $0.name == "广东" }) {
            selectedCities = Set(gd.cities.map(\.code))
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in self?.setOnline(ok) }
        }
        monitor.start(queue: DispatchQueue(label: "net.monitor"))
        Task { await checkUpdate() }
        if Self.canNotify {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    // MARK: - 计算属性
    var allRules: [Rule] { RuleBook.builtIn + customPatterns.compactMap(RuleBook.customRule) }

    var targets: [Target] {
        provinces.flatMap { p in p.cities.filter { selectedCities.contains($0.code) }.map { Target(province: p, city: $0) } }
    }

    var filteredHits: [Hit] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        var list = q.isEmpty ? hits : hits.filter { $0.number.contains(q) }
        if let f = ruleFilter { list = list.filter { $0.primaryRule == f } }
        return list.sorted { $0.score != $1.score ? $0.score > $1.score : $0.number < $1.number }
    }

    /// 按主规律分组，组按最高分排
    var groupedHits: [HitGroup] {
        let groups = Dictionary(grouping: filteredHits, by: \.primaryRule)
        return groups.map { HitGroup(rule: $0.key, hits: $0.value) }.sorted { ($0.hits.first?.score ?? 0) > ($1.hits.first?.score ?? 0) }
    }

    /// 每条主规律命中多少（筛选标签用），按数量排
    var ruleCounts: [(rule: String, count: Int)] {
        Dictionary(grouping: hits, by: \.primaryRule)
            .map { (rule: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    var todayCount: Int { hits.filter { Calendar.current.isDateInToday($0.foundAt) }.count }

    var regionSummary: String {
        let full = provinces.filter(isProvinceFullySelected)
        let part = provinces.filter { isProvincePartlySelected($0) && !isProvinceFullySelected($0) }
        if full.count == provinces.count { return "全国" }
        if full.isEmpty && part.isEmpty { return "未选择" }
        var names = full.map { $0.name + "全省" }
        names += part.map { p in "\(p.name) \(p.cities.filter { selectedCities.contains($0.code) }.count) 城" }
        if names.count > 3 { return names.prefix(3).joined(separator: "、") + " 等 \(names.count) 省" }
        return names.joined(separator: "、")
    }

    func isWatched(_ number: String) -> String? {
        let tail = String(number.suffix(8))
        return watchKeywords.first { !$0.isEmpty && tail.contains($0) }
    }
    func addKeyword(_ k: String) -> Bool {
        let t = k.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy(\.isNumber), t.count <= 8, !watchKeywords.contains(t) else { return false }
        watchKeywords.append(t); save(); return true
    }
    func removeKeyword(_ k: String) { watchKeywords.removeAll { $0 == k }; save() }

    var selectedHit: Hit? { hits.first { $0.id == selectedHitID } }

    // MARK: - 选择操作
    func isProvinceFullySelected(_ p: Province) -> Bool { p.cities.allSatisfy { selectedCities.contains($0.code) } }
    func isProvincePartlySelected(_ p: Province) -> Bool { p.cities.contains { selectedCities.contains($0.code) } }

    func toggleProvince(_ p: Province) {
        if isProvinceFullySelected(p) { p.cities.forEach { selectedCities.remove($0.code) } }
        else { p.cities.forEach { selectedCities.insert($0.code) } }
    }
    func toggleCity(_ c: City) {
        if selectedCities.contains(c.code) { selectedCities.remove(c.code) } else { selectedCities.insert(c.code) }
    }
    func selectAll() { selectedCities = Set(provinces.flatMap { $0.cities.map(\.code) }) }
    func selectNone() { selectedCities.removeAll() }

    func toggleRule(_ id: String) {
        if enabledRules.contains(id) { enabledRules.remove(id) } else { enabledRules.insert(id) }
    }
    func addCustom(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let r = RuleBook.customRule(t), !customPatterns.contains(t) else { return false }
        customPatterns.append(t)
        enabledRules.insert(r.id)
        return true
    }
    func removeCustom(_ t: String) {
        customPatterns.removeAll { $0 == t }
        enabledRules.remove("custom:" + t)
    }

    // MARK: - 扫描
    func toggleRun() { isRunning ? stop() : start() }

    func start() {
        let ts = targets
        let rules = allRules.filter { enabledRules.contains($0.id) }
        guard !ts.isEmpty else { addLog("先在左边选地区"); return }
        guard !rules.isEmpty else { addLog("先勾选至少一条规律"); return }
        let excluded = Set(excludeText.compactMap { $0.wholeNumberValue })
        let evaluator = Evaluator(rules: rules, excludedDigits: excluded)
        isRunning = true
        concurrency = 1
        exhaustedCities = 0
        emptyCount = 0
        failCount = 0
        statusNote = ""
        addLog("开始扫描：\(ts.count) 个城市，\(rules.count) 条规律")
        task = Task { [weak self] in await self?.loop(targets: ts, evaluator: evaluator) }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        statusNote = ""
        addLog("已暂停")
        save()
    }

    private func loop(targets: [Target], evaluator: Evaluator) async {
        var cursor = 0
        var goodWaves = 0
        var badWaves = 0
        var dry: [String: Int] = [:]
        var empty: [String: Int] = [:]
        let src = source
        while !Task.isCancelled {
            if !isOnline {
                statusNote = "网络已断开，恢复后自动继续"
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            if statusNote.hasPrefix("网络") { statusNote = "" }
            let manual = manualControl
            if manual { concurrency = max(1, min(64, manualConcurrency)) }
            // 连续多次扫不出新号的城市视为「扫完了」，跳过；全部扫完就自动停止
            let active = targets.filter { (dry[$0.city.code] ?? 0) < Self.dryLimit && (empty[$0.city.code] ?? 0) < Self.emptyLimit }
            if active.isEmpty {
                let allEmpty = targets.allSatisfy { (empty[$0.city.code] ?? 0) >= Self.emptyLimit }
                finishExhausted(rateLimited: allEmpty); break
            }
            exhaustedCities = targets.count - active.count
            let n = min(concurrency, active.count)
            let batch = (0..<n).map { active[(cursor + $0) % active.count] }
            cursor = (cursor + n) % active.count
            // 分投：每个请求错开一个间隔再发；速投：一起发
            let stagger: Double = manual && scanMode == .spaced ? Double(manualIntervalMs) / 1000 : 0

            var results: [(Target, Result<[String], Error>)] = []
            await withTaskGroup(of: (Target, Result<[String], Error>).self) { g in
                for (i, t) in batch.enumerated() {
                    g.addTask {
                        if stagger > 0 && i > 0 { try? await Task.sleep(for: .seconds(stagger * Double(i))) }
                        do { return (t, .success(try await src.fetch(t))) }
                        catch { return (t, .failure(error)) }
                    }
                }
                for await r in g { results.append(r) }
            }
            if Task.isCancelled { break }

            var failed = 0
            var lastError = ""
            for (t, r) in results {
                switch r {
                case .failure(SourceError.empty(let code)):
                    let e = (empty[t.city.code] ?? 0) + 1
                    empty[t.city.code] = e
                    emptyCount += 1
                    if e == Self.emptyLimit { addLog("\(t.province.name)\(t.city.name) 连续返回空（\(code)），跳过") }
                case .failure(let err):
                    failed += 1
                    failCount += 1
                    lastError = err.localizedDescription
                case .success(let nums):
                    empty[t.city.code] = 0
                    receivedCount += nums.count
                    let fresh = handle(nums, target: t, evaluator: evaluator)
                    let before = dry[t.city.code] ?? 0
                    dry[t.city.code] = fresh == 0 ? before + 1 : 0
                    if fresh == 0 && before + 1 == Self.dryLimit {
                        addLog("\(t.province.name)\(t.city.name) 已扫不出新号，跳过")
                    }
                }
            }

            // 自动调速：顺利就慢慢加，出错就减半并退避；手动模式只退避不改并发
            if failed > 0 {
                badWaves += 1; goodWaves = 0
                if !manual { concurrency = max(1, concurrency / 2) }
                let wait = min(30.0, 2.0 * Double(badWaves))
                statusNote = "接口繁忙，\(Int(wait)) 秒后继续"
                addLog("\(failed) 个请求失败（\(lastError)），等待 \(Int(wait)) 秒" + (manual ? "" : "并降速"))
                try? await Task.sleep(for: .seconds(wait))
                statusNote = ""
            } else {
                badWaves = 0; goodWaves += 1
                if manual {
                    let gap = scanMode == .spaced ? Double(manualIntervalMs) / 1000 : 0.05
                    try? await Task.sleep(for: .seconds(max(0.05, gap)))
                } else {
                    if goodWaves >= 3, concurrency < speed.maxConcurrency { concurrency += 1; goodWaves = 0 }
                    try? await Task.sleep(for: .seconds(speed.minDelay))
                }
            }
        }
    }

    /// 一个城市连续这么多次返回里没有新号，就认为号池扫完了
    static let dryLimit = 8
    /// 一个城市连续这么多次返回空列表，就跳过（该城市没号，或被限流）
    static let emptyLimit = 5

    private func finishExhausted(rateLimited: Bool = false) {
        task = nil
        isRunning = false
        statusNote = ""
        exhaustedCities = 0
        if rateLimited {
            addLog("所有城市都一直返回空列表，可能被联通限流了。已停止，建议过半小时再试，或在设置里调慢速度")
        } else {
            addLog("所有选中城市都扫不出新号了，已自动停止。共查 \(checkedCount) 个，命中 \(hits.count) 个")
        }
        NSSound(named: "Hero")?.play()
        if Self.canNotify {
            let c = UNMutableNotificationContent()
            c.title = rateLimited ? "扫号已停止" : "扫号完成"
            c.body = rateLimited ? "接口一直返回空列表，可能被限流，过一会儿再试"
                                 : "选中地区的号池扫完了，共查 \(checkedCount) 个，命中 \(hits.count) 个"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "done-\(Date().timeIntervalSince1970)", content: c, trigger: nil))
        }
        save()
    }

    @discardableResult
    private func handle(_ numbers: [String], target: Target, evaluator: Evaluator) -> Int {
        var fresh = 0
        for num in numbers where seen.insert(num).inserted {
            fresh += 1
            var found = evaluator.evaluate(num)
            if found == nil, let k = isWatched(num), let range = num.range(of: k, options: .backwards) {
                let lo = num.distance(from: num.startIndex, to: range.lowerBound)
                let m = RuleMatch(ruleName: "关注 \(k)", range: lo..<(lo + k.count), score: 60)
                found = ([m], 60)
            }
            guard let r = found else { continue }
            let score = r.score
            let hit = Hit(number: num, provinceName: target.province.name, cityName: target.city.name,
                          matches: r.matches, score: score, foundAt: Date())
            hits.append(hit)
            addLog("命中 \(hit.formatted) · \(hit.primaryRule) · \(target.city.name)")
            if let k = isWatched(num) { notify(hit, reason: "关注 \(k)") }
            else if alertHighScore && score >= 90 { notify(hit, reason: "高分") }
            if hits.count % 20 == 0 { save() }
        }
        checkedCount += fresh
        let now = Date()
        recent.append((now, fresh))
        recent.removeAll { now.timeIntervalSince($0.0) > 60 }
        perMinute = recent.reduce(0) { $0 + $1.1 }
        return fresh
    }

    private func setOnline(_ ok: Bool) {
        guard ok != isOnline else { return }
        isOnline = ok
        addLog(ok ? "网络已恢复" : "网络已断开")
    }

    /// 启动时看 GitHub Release 有没有新版（Release 标题末尾是 commit 短号）
    func checkUpdate() async {
        let local = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
        guard local.count == 7,
              let url = URL(string: "https://api.github.com/repos/wwqla/LiangHao/releases/tags/latest"),
              let result = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let name = json["name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return }
        if !name.hasSuffix(local) { updateURL = page }
    }

    func openOrder(_ hit: Hit) {
        copy(hit)
        NSWorkspace.shared.open(Self.orderURL)
        addLog("已复制 \(hit.formatted)，打开联通官方选号页")
    }

    func revealData() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: - 结果操作
    func toggleFavorite(_ id: String) {
        guard let i = hits.firstIndex(where: { $0.id == id }) else { return }
        hits[i].favorite.toggle()
        save()
    }

    func clearResults() {
        hits.removeAll { !$0.favorite }   // 收藏的保留
        seen.removeAll()
        checkedCount = 0
        selectedHitID = nil
        ruleFilter = nil
        save()
    }

    func copy(_ hit: Hit) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hit.number, forType: .string)
    }

    enum ExportFormat { case excel, csv }

    func export(_ format: ExportFormat, onlyNew: Bool = false) {
        var list = filteredHits
        if onlyNew, let last = lastExportDate { list = list.filter { $0.foundAt > last } }
        guard !list.isEmpty else { addLog(onlyNew ? "上次导出之后没有新号码" : "没有可导出的号码"); return }
        let panel = NSSavePanel()
        let stamp = Int(Date().timeIntervalSince1970)
        switch format {
        case .excel:
            panel.nameFieldStringValue = "靓号-\(stamp).xlsx"
            panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
        case .csv:
            panel.nameFieldStringValue = "靓号-\(stamp).csv"
            panel.allowedContentTypes = [.commaSeparatedText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let header = ["号码", "靓号分", "规律", "省份", "城市", "发现时间", "收藏", "办理入口"]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let rows: [[String]] = list.map { h in
            [h.number, String(h.score), h.matches.map(\.ruleName).joined(separator: " / "),
             h.provinceName, h.cityName, f.string(from: h.foundAt), h.favorite ? "是" : "", Self.orderURL.absoluteString]
        }
        do {
            switch format {
            case .excel: try XLSXWriter.write(header: header, rows: rows, to: url)
            case .csv:
                // 号码前加 \t，Excel 打开不会变成科学计数法
                var s = "\u{FEFF}" + header.joined(separator: ",") + "\n"
                for r in rows { s += (["\t" + r[0]] + r.dropFirst().map { "\"\($0)\"" }).joined(separator: ",") + "\n" }
                try s.write(to: url, atomically: true, encoding: .utf8)
            }
            lastExportDate = Date()
            save()
            addLog("已导出 \(list.count) 个号码")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            addLog("导出失败：\(error.localizedDescription)")
        }
    }

    func exportCSV() { export(.csv) }

    private func notify(_ hit: Hit, reason: String) {
        NSSound(named: "Glass")?.play()
        guard Self.canNotify else { return }
        let c = UNMutableNotificationContent()
        c.title = "扫到靓号 \(hit.formatted)（\(reason)）"
        c.body = "\(hit.primaryRule) · \(hit.provinceName)\(hit.cityName) · \(hit.score) 分"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: hit.number, content: c, trigger: nil))
    }

    /// 只有打包成 .app 运行时才能用系统通知（swift run 直接跑会崩）
    private static var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    private func addLog(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(s)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // MARK: - 存储
    private struct Saved: Codable {
        var hits: [Hit]
        var selectedCities: Set<String>
        var enabledRules: Set<String>
        var customPatterns: [String]
        var excludeText: String
        var speed: Speed
        var watchKeywords: [String]?
        var alertHighScore: Bool?
        var lastExportDate: Date?
        var manualControl: Bool?
        var manualConcurrency: Int?
        var manualIntervalMs: Int?
        var scanMode: ScanMode?
    }

    var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiangHao", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("data.json")
    }

    func save() {
        let s = Saved(hits: hits, selectedCities: selectedCities, enabledRules: enabledRules,
                      customPatterns: customPatterns, excludeText: excludeText, speed: speed,
                      watchKeywords: watchKeywords, alertHighScore: alertHighScore, lastExportDate: lastExportDate,
                      manualControl: manualControl, manualConcurrency: manualConcurrency,
                      manualIntervalMs: manualIntervalMs, scanMode: scanMode)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: fileURL) }
    }

    private func load() {
        guard let d = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        hits = s.hits
        seen = Set(s.hits.map(\.number))
        selectedCities = s.selectedCities
        enabledRules = s.enabledRules
        customPatterns = s.customPatterns
        excludeText = s.excludeText
        speed = s.speed
        if let w = s.watchKeywords { watchKeywords = w }
        if let a = s.alertHighScore { alertHighScore = a }
        lastExportDate = s.lastExportDate
        if let v = s.manualControl { manualControl = v }
        if let v = s.manualConcurrency { manualConcurrency = v }
        if let v = s.manualIntervalMs { manualIntervalMs = v }
        if let v = s.scanMode { scanMode = v }
    }
}
