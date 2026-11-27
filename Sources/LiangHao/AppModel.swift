import Foundation
import AppKit
import UserNotifications
import Observation
import UniformTypeIdentifiers

@Observable
@MainActor
final class AppModel {
    // MARK: 选择
    var selectedCities: Set<String> = []          // 城市 code
    var enabledRules: Set<String> = RuleBook.defaultEnabled
    var customPatterns: [String] = []
    var excludeText: String = "4"
    var speed: Speed = .steady

    // MARK: 结果
    var hits: [Hit] = []
    var selectedHitID: String?
    var searchText: String = ""
    var log: [String] = []

    // MARK: 状态
    private(set) var isRunning = false
    private(set) var checkedCount = 0
    private(set) var perMinute = 0
    private(set) var concurrency = 1
    private(set) var statusNote = ""

    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var recent: [(Date, Int)] = []
    private let source: NumberSource = UnicomSource()

    let provinces = RegionData.provinces

    init() {
        load()
        if selectedCities.isEmpty, let gd = provinces.first(where: { $0.name == "广东" }) {
            selectedCities = Set(gd.cities.map(\.code))
        }
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
        let list = q.isEmpty ? hits : hits.filter { $0.number.contains(q) }
        return list.sorted { $0.score != $1.score ? $0.score > $1.score : $0.number < $1.number }
    }

    /// 按主规律分组，组按最高分排
    var groupedHits: [HitGroup] {
        let groups = Dictionary(grouping: filteredHits, by: \.primaryRule)
        return groups.map { HitGroup(rule: $0.key, hits: $0.value) }.sorted { ($0.hits.first?.score ?? 0) > ($1.hits.first?.score ?? 0) }
    }

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
        let src = source
        while !Task.isCancelled {
            let n = concurrency
            let batch = (0..<n).map { targets[(cursor + $0) % targets.count] }
            cursor = (cursor + n) % targets.count

            var results: [(Target, Result<[String], Error>)] = []
            await withTaskGroup(of: (Target, Result<[String], Error>).self) { g in
                for t in batch {
                    g.addTask {
                        do { return (t, .success(try await src.fetch(t))) }
                        catch { return (t, .failure(error)) }
                    }
                }
                for await r in g { results.append(r) }
            }
            if Task.isCancelled { break }

            var failed = 0
            for (t, r) in results {
                switch r {
                case .success(let nums): handle(nums, target: t, evaluator: evaluator)
                case .failure: failed += 1
                }
            }

            // 自动调速：顺利就慢慢加，出错就减半并退避
            if failed > 0 {
                badWaves += 1; goodWaves = 0
                concurrency = max(1, concurrency / 2)
                let wait = min(30.0, 2.0 * Double(badWaves))
                statusNote = "接口繁忙，\(Int(wait)) 秒后继续"
                addLog("\(failed) 个请求失败，降速并等待 \(Int(wait)) 秒")
                try? await Task.sleep(for: .seconds(wait))
                statusNote = ""
            } else {
                badWaves = 0; goodWaves += 1
                if goodWaves >= 3, concurrency < speed.maxConcurrency { concurrency += 1; goodWaves = 0 }
                try? await Task.sleep(for: .seconds(speed.minDelay))
            }
        }
    }

    private func handle(_ numbers: [String], target: Target, evaluator: Evaluator) {
        var fresh = 0
        for num in numbers where seen.insert(num).inserted {
            fresh += 1
            guard let r = evaluator.evaluate(num) else { continue }
            let score = r.score
            let hit = Hit(number: num, provinceName: target.province.name, cityName: target.city.name,
                          matches: r.matches, score: score, foundAt: Date())
            hits.append(hit)
            addLog("命中 \(hit.formatted) · \(hit.primaryRule) · \(target.city.name)")
            if score >= 90 { notify(hit) }
            if hits.count % 20 == 0 { save() }
        }
        checkedCount += fresh
        let now = Date()
        recent.append((now, fresh))
        recent.removeAll { now.timeIntervalSince($0.0) > 60 }
        perMinute = recent.reduce(0) { $0 + $1.1 }
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
        save()
    }

    func copy(_ hit: Hit) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hit.number, forType: .string)
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "靓号-\(Int(Date().timeIntervalSince1970)).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var s = "\u{FEFF}号码,靓号分,规律,省份,城市,收藏\n"
        for h in filteredHits {
            s += "\(h.number),\(h.score),\(h.matches.map(\.ruleName).joined(separator: "/")),\(h.provinceName),\(h.cityName),\(h.favorite ? "是" : "")\n"
        }
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }

    private func notify(_ hit: Hit) {
        NSSound(named: "Glass")?.play()
        guard Self.canNotify else { return }
        let c = UNMutableNotificationContent()
        c.title = "扫到靓号 \(hit.formatted)"
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
    }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiangHao", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("data.json")
    }

    func save() {
        let s = Saved(hits: hits, selectedCities: selectedCities, enabledRules: enabledRules,
                      customPatterns: customPatterns, excludeText: excludeText, speed: speed)
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
    }
}
