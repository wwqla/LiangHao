import SwiftUI
import AppKit

// MARK: - 主窗口

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 270, ideal: 300, max: 360)
        } content: {
            HitListView()
                .navigationSplitViewColumnWidth(min: 380, ideal: 460)
        } detail: {
            DetailView()
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "搜号码，如 888")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("导出 Excel…") { model.export(.excel) }
                    Button("只导出新号码…") { model.export(.excel, onlyNew: true) }
                        .disabled(model.lastExportDate == nil)
                    Divider()
                    Button("导出 CSV…") { model.export(.csv) }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .disabled(model.hits.isEmpty)
                .help("导出结果")

                Button { model.clearResults() } label: { Label("清空", systemImage: "trash") }
                    .help("清空结果（收藏的会保留）")
                    .disabled(model.isRunning || model.hits.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.showLog { LogPanel() }
        }
        .sheet(isPresented: $model.showRegionPicker) {
            RegionPicker().environment(model).tint(.lucky)
        }
    }
}

// MARK: - 通用小组件

/// 自动换行排布（标签用）
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

struct Chip: View {
    let title: String
    var count: Int? = nil
    let isOn: Bool
    var warn = false
    var onRemove: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if let count {
                    Text("\(count)").monospacedDigit()
                        .foregroundStyle(isOn ? Color.white.opacity(0.8) : Color.secondary)
                }
                if warn {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                        .foregroundStyle(isOn ? Color.white : Color.orange)
                        .help("这条规律会命中很多号码")
                }
                if let onRemove {
                    Image(systemName: "xmark").font(.caption2.bold())
                        .onTapGesture(perform: onRemove)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(isOn ? Color.lucky : Color.primary.opacity(0.07)))
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

struct InlineAdd: View {
    let placeholder: String
    let onAdd: (String) -> Bool
    @State private var text = ""
    @State private var bad = false

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
                .onChange(of: text) { bad = false }
            Button(action: add) { Image(systemName: "plus") }
                .disabled(text.isEmpty)
        }
        .overlay(alignment: .bottomLeading) {
            if bad {
                Text("格式不对").font(.caption2).foregroundStyle(.red).offset(y: 14)
            }
        }
    }

    private func add() {
        if onAdd(text) { text = "" } else { bad = true }
    }
}

// MARK: - 左栏

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("靓号助手").font(.headline)
                            Text("联通全国选号池 · 移动电信广电网页扫").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 2)

                    SectionCard("地区", systemImage: "map") {
                        Button { model.showRegionPicker = true } label: {
                            HStack {
                                Text(model.regionSummary).lineLimit(2)
                                Spacer()
                                Text("\(model.targets.count) 城").foregroundStyle(.secondary).monospacedDigit()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isRunning)
                    }

                    SectionCard("规律", systemImage: "wand.and.stars") {
                        FlowLayout {
                            ForEach(model.allRules) { r in
                                Chip(title: r.name, isOn: model.enabledRules.contains(r.id), warn: r.isBroad,
                                     onRemove: removeAction(for: r)) {
                                    model.toggleRule(r.id)
                                }
                            }
                        }
                        .disabled(model.isRunning)
                        InlineAdd(placeholder: "自定义：*8888、AABB、1?14") { model.addCustom($0) }
                            .disabled(model.isRunning)
                    }

                    SectionCard("关注号码", systemImage: "bell.badge") {
                        if !model.watchKeywords.isEmpty {
                            FlowLayout {
                                ForEach(model.watchKeywords, id: \.self) { k in
                                    Chip(title: k, isOn: true, onRemove: { model.removeKeyword(k) }) {}
                                }
                            }
                        }
                        InlineAdd(placeholder: "加数字，如 1314") { model.addKeyword($0) }
                        Text("后 8 位出现这些数字，就弹通知提醒你")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }

            Divider()

            VStack(spacing: 8) {
                Button { model.toggleRun() } label: {
                    Label(model.isRunning ? "暂停扫描" : "开始扫描",
                          systemImage: model.isRunning ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button { openWindow(id: "web") } label: {
                    Label("网页扫号：移动 / 电信 / 广电", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                HStack(spacing: 6) {
                    Circle()
                        .fill(model.isRunning ? (model.statusNote.isEmpty ? Color.green : Color.orange) : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(statusText).lineLimit(1)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }

    private func removeAction(for r: Rule) -> (() -> Void)? {
        guard r.id.hasPrefix("custom:") else { return nil }
        let pattern = String(r.id.dropFirst("custom:".count))
        return { model.removeCustom(pattern) }
    }

    private var statusText: String {
        if !model.statusNote.isEmpty { return model.statusNote }
        if model.isRunning {
            let done = model.exhaustedCities > 0 ? " · \(model.exhaustedCities) 城已扫完" : ""
            if model.manualControl { return "扫描中 · 手动 \(model.scanMode.rawValue) · 并发 \(model.concurrency)" + done }
            return "扫描中 · 速度「\(model.speed.rawValue)」· 并发 \(model.concurrency)" + done
        }
        return "已停止 · ⌘R 开始"
    }
}

// MARK: - 地区选择

struct RegionPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var focused: Province?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("选择地区").font(.title2.bold())
                Spacer()
                Button("全国") { model.selectAll() }
                Button("清空") { model.selectNone() }
            }
            Text("点省份整省选中 / 取消，点省份右边的「›」单独挑城市")
                .font(.caption).foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.provinces) { p in
                    provinceTile(p)
                }
            }

            if let p = focused {
                Divider()
                HStack {
                    Text("\(p.name) · 城市").font(.headline)
                    Spacer()
                    Button(model.isProvinceFullySelected(p) ? "取消全选" : "全选") { model.toggleProvince(p) }
                }
                ScrollView {
                    FlowLayout {
                        ForEach(p.cities) { c in
                            Chip(title: c.name, isOn: model.selectedCities.contains(c.code)) { model.toggleCity(c) }
                        }
                    }
                }
                .frame(maxHeight: 150)
            }

            HStack {
                Text("已选 \(model.targets.count) 个城市").foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss(); model.save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 660)
    }

    private func provinceTile(_ p: Province) -> some View {
        let full = model.isProvinceFullySelected(p)
        let part = !full && model.isProvincePartlySelected(p)
        return HStack(spacing: 0) {
            Button { model.toggleProvince(p) } label: {
                Text(p.name)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { focused = p } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(full ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(full ? Color.lucky : (part ? Color.lucky.opacity(0.22) : Color.primary.opacity(0.06))))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(focused == p ? Color.lucky : Color.clear, lineWidth: 2))
    }
}

// MARK: - 中栏

struct HitListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            StatsStrip()
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if let url = model.updateURL {
                Banner(icon: "arrow.down.circle.fill", text: "有新版本可以下载", color: .blue) {
                    NSWorkspace.shared.open(url)
                }
            }
            if !model.isOnline {
                Banner(icon: "wifi.slash", text: "网络已断开，恢复后自动继续扫描", color: .orange, action: nil)
            }

            if !model.hits.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Chip(title: "全部", count: model.hits.count, isOn: model.ruleFilter == nil) { model.ruleFilter = nil }
                        ForEach(model.ruleCounts, id: \.rule) { rc in
                            Chip(title: rc.rule, count: rc.count, isOn: model.ruleFilter == rc.rule) {
                                model.ruleFilter = model.ruleFilter == rc.rule ? nil : rc.rule
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)
            }

            Divider()

            if model.hits.isEmpty {
                ContentUnavailableView {
                    Label(model.isRunning ? "正在扫描…" : "还没有号码",
                          systemImage: model.isRunning ? "antenna.radiowaves.left.and.right" : "sparkles")
                } description: {
                    Text(model.isRunning ? "命中的靓号会实时出现在这里" : "左边选好地区和规律，点「开始扫描」")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $model.selectedHitID) {
                    ForEach(model.filteredHits) { h in
                        HitRow(hit: h).tag(h.id as String?)
                            .contextMenu {
                                Button("去办理") { model.openOrder(h) }
                                Button("复制号码") { model.copy(h) }
                                Button(h.favorite ? "取消收藏" : "收藏") { model.toggleFavorite(h.id) }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("扫到的号")
    }
}

struct StatsStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatTile(title: "已查", value: model.checkedCount.formatted(), icon: "magnifyingglass")
                StatTile(title: "命中", value: model.hits.count.formatted(), icon: "sparkles", highlight: true)
                StatTile(title: "今日新增", value: model.todayCount.formatted(), icon: "sun.max")
                StatTile(title: "每分钟新号", value: model.isRunning ? model.perMinute.formatted() : "–", icon: "speedometer")
            }
            HStack(spacing: 12) {
                if !topCities.isEmpty {
                    Text("命中最多：" + topCities).lineLimit(1)
                }
                Spacer()
                if model.emptyCount > 0 {
                    Text("空返回 \(model.emptyCount)").foregroundStyle(.orange)
                        .help("接口正常回应但没有号码：该城市没号，或被限流")
                }
                if model.failCount > 0 {
                    Text("失败 \(model.failCount)").foregroundStyle(.red)
                        .help("请求出错（超时、网络问题等），详情看日志 ⌘L")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var topCities: String {
        Dictionary(grouping: model.hits, by: \.cityName)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(4)
            .map { "\($0.0) \($0.1)" }
            .joined(separator: " · ")
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let icon: String
    var highlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(highlight ? Color.lucky : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

struct Banner: View {
    let icon: String
    let text: String
    let color: Color
    let action: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: icon)
            Text(text)
            Spacer()
            if action != nil { Text("查看").bold() }
        }
        .font(.callout)
        .foregroundStyle(color)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }
}

struct HitRow: View {
    let hit: Hit

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HighlightedNumber(hit: hit, size: 19)
                HStack(spacing: 6) {
                    Text(hit.primaryRule)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.lucky.opacity(0.12)))
                        .foregroundStyle(Color.lucky)
                    Text(hit.shortLocation).font(.caption).foregroundStyle(.secondary)
                    if hit.isStale {
                        Text("可能已被选走").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if hit.favorite {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
            }
            ScoreBadge(score: hit.score)
        }
        .padding(.vertical, 5)
        .opacity(hit.isStale ? 0.55 : 1)
    }
}

struct HighlightedNumber: View {
    let hit: Hit
    let size: CGFloat
    var onDark = false

    var body: some View {
        let chars = Array(hit.number)
        let hl = hit.matches.first?.range ?? 0..<0
        let hot: Color = onDark ? .white : .lucky
        let cold: Color = onDark ? Color.white.opacity(0.7) : .primary
        var t = Text(verbatim: "")
        for (i, c) in chars.enumerated() {
            let piece = Text(verbatim: String(c))
            if hl.contains(i) {
                t = t + piece.font(.system(size: size, weight: .bold, design: .rounded)).foregroundColor(hot)
            } else {
                t = t + piece.font(.system(size: size, weight: .regular, design: .rounded)).foregroundColor(cold)
            }
            if i == 2 || i == 6 { t = t + Text(verbatim: " ").font(.system(size: size * 0.6)) }
        }
        return t.monospacedDigit()
    }
}

struct ScoreBadge: View {
    let score: Int
    var body: some View {
        Text("\(score)")
            .font(.callout.monospacedDigit().bold())
            .frame(minWidth: 34)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .help("靓号分")
    }
    private var color: Color { score >= 100 ? .lucky : score >= 80 ? .orange : .blue }
}

// MARK: - 右栏

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let hit = model.selectedHit {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(hit.locationText)
                            .font(.callout)
                            .foregroundStyle(Color.white.opacity(0.85))
                        HighlightedNumber(hit: hit, size: 38, onDark: true)
                            .textSelection(.enabled)
                        HStack(spacing: 8) {
                            Text("靓号分 \(hit.score)").bold()
                            if hit.isStale { Text("· 可能已被选走") }
                        }
                        .font(.callout)
                        .foregroundStyle(.white)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient(colors: [Color.lucky, Color(red: 0.95, green: 0.45, blue: 0.15)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .shadow(color: Color.lucky.opacity(0.25), radius: 12, y: 6)

                    HStack(spacing: 10) {
                        Button { model.openOrder(hit) } label: { Label("去办理", systemImage: "cart.fill") }
                            .buttonStyle(.borderedProminent)
                        Button { model.copy(hit) } label: { Label("复制", systemImage: "doc.on.doc") }
                        Button { model.toggleFavorite(hit.id) } label: {
                            Label(hit.favorite ? "已收藏" : "收藏", systemImage: hit.favorite ? "star.fill" : "star")
                        }
                    }
                    .controlSize(.large)

                    Text("「去办理」会复制号码并打开\(hit.carrierName)官方选号页，在页面里按尾号搜索即可。号码随时可能被别人选走，看中了尽快办。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("命中规律").font(.headline)
                        ForEach(hit.matches, id: \.self) { m in
                            HStack {
                                Text(m.ruleName)
                                Spacer()
                                Text("\(m.score) 分").foregroundStyle(.secondary).monospacedDigit()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
                        }
                    }

                    Text("发现于 \(hit.foundAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(24)
                .frame(maxWidth: 520, alignment: .leading)
            }
        } else {
            ContentUnavailableView("选一个号码看详情", systemImage: "hand.point.left",
                                   description: Text("右键号码有更多操作"))
        }
    }
}

// MARK: - 日志

struct LogPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("日志").font(.caption.bold())
                Spacer()
                Button { model.showLog = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).id(i)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                .onChange(of: model.log.count) { proxy.scrollTo(model.log.count - 1, anchor: .bottom) }
            }
        }
        .background(.bar)
    }
}

// MARK: - 设置（⌘,）

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("扫描") {
                Picker("速度", selection: $model.speed) {
                    Text("稳（不易被限流）").tag(Speed.steady)
                    Text("快").tag(Speed.fast)
                }
                .disabled(model.isRunning || model.manualControl)
                TextField("排除数字", text: $model.excludeText, prompt: Text("例如 4"))
                    .disabled(model.isRunning)
                Text("号码后 8 位含这些数字就跳过").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("手动控制速度", isOn: $model.manualControl)
                if model.manualControl {
                    Stepper(value: $model.manualConcurrency, in: 1...64) {
                        LabeledContent("并发数", value: "\(model.manualConcurrency)")
                    }
                    Stepper(value: $model.manualIntervalMs, in: 0...3000, step: 50) {
                        LabeledContent("间隔", value: "\(model.manualIntervalMs) 毫秒")
                    }
                    Picker("扫号模式", selection: $model.scanMode) {
                        Text("分投（按间隔逐个发，稳定）").tag(ScanMode.spaced)
                        Text("速投（一批同时发，快）").tag(ScanMode.burst)
                    }
                }
            } header: {
                Text("高级")
            } footer: {
                Text(model.manualControl
                     ? "并发越大、间隔越小越快，也越容易被联通限流封 IP。建议并发 4–16，间隔 200–500 毫秒。出错时仍会自动暂停退避。"
                     : "默认自动调速：顺利就加快，被限流就减半。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(model.isRunning)

            Section("提醒") {
                Toggle("高分号码（≥90 分）也提醒", isOn: $model.alertHighScore)
                Text("「关注号码」命中时总会提醒，在主窗口左栏设置").font(.caption).foregroundStyle(.secondary)
            }
            Section("数据") {
                LabeledContent("扫描结果保存在本机") {
                    Button("在 Finder 中显示") { model.revealData() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.speed) { model.save() }
        .onChange(of: model.excludeText) { model.save() }
        .onChange(of: model.alertHighScore) { model.save() }
        .onChange(of: model.manualControl) { model.save() }
        .onChange(of: model.manualConcurrency) { model.save() }
        .onChange(of: model.manualIntervalMs) { model.save() }
        .onChange(of: model.scanMode) { model.save() }
    }
}
