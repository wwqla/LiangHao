import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showLog = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } content: {
            HitListView()
                .navigationSplitViewColumnWidth(min: 340, ideal: 420)
        } detail: {
            DetailView()
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "搜号码，如 888")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.toggleRun()
                } label: {
                    Label(model.isRunning ? "暂停" : "开始", systemImage: model.isRunning ? "pause.fill" : "play.fill")
                }
                .help(model.isRunning ? "暂停扫描 ⌘R" : "开始扫描 ⌘R")

                Button { model.clearResults() } label: { Label("清空", systemImage: "trash") }
                    .help("清空结果（收藏的会保留）")
                    .disabled(model.isRunning)

                Button { model.exportCSV() } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .help("导出 CSV")
                    .disabled(model.hits.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar(showLog: $showLog)
        }
        .onChange(of: model.speed) { model.save() }
    }
}

// MARK: - 左栏

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var customInput = ""
    @State private var customError = false

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                ForEach(model.provinces) { p in
                    DisclosureGroup {
                        ForEach(p.cities) { c in
                            Toggle(c.name, isOn: Binding(
                                get: { model.selectedCities.contains(c.code) },
                                set: { _ in model.toggleCity(c) }))
                                .toggleStyle(.checkbox)
                                .disabled(model.isRunning)
                        }
                    } label: {
                        Toggle(isOn: Binding(
                            get: { model.isProvinceFullySelected(p) },
                            set: { _ in model.toggleProvince(p) })) {
                            HStack {
                                Text(p.name)
                                Spacer()
                                let n = p.cities.filter { model.selectedCities.contains($0.code) }.count
                                if n > 0 && n < p.cities.count {
                                    Text("\(n)/\(p.cities.count)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(model.isRunning)
                    }
                }
            } header: {
                HStack {
                    Text("地区 · 联通（\(model.targets.count) 个城市）")
                    Spacer()
                    Menu("选择") {
                        Button("全国") { model.selectAll() }
                        Button("全不选") { model.selectNone() }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.isRunning)
                }
            }

            Section("规律") {
                ForEach(model.allRules) { r in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { model.enabledRules.contains(r.id) },
                            set: { _ in model.toggleRule(r.id) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name)
                                Text(r.example).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(model.isRunning)
                        Spacer()
                        if r.isBroad {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .help("这条规律会命中很多号码，结果会很杂")
                        }
                        if r.id.hasPrefix("custom:") {
                            Button {
                                model.removeCustom(String(r.id.dropFirst("custom:".count)))
                            } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .disabled(model.isRunning)
                        }
                    }
                }
                HStack {
                    TextField("自定义：*8888、AABB、re:正则", text: $customInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addCustom)
                    Button("添加", action: addCustom).disabled(customInput.isEmpty || model.isRunning)
                }
                if customError {
                    Text("格式不对。例子：*8888（尾号）、AABB、1?14、re:520\\d{2}")
                        .font(.caption).foregroundStyle(.red)
                }
            }

            Section("排除数字（后 8 位不含）") {
                TextField("例如 4", text: $model.excludeText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isRunning)
            }

            Section("速度") {
                Picker("速度", selection: $model.speed) {
                    ForEach(Speed.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isRunning)
            }
        }
        .listStyle(.sidebar)
    }

    private func addCustom() {
        customError = !model.addCustom(customInput)
        if !customError { customInput = "" }
    }
}

// MARK: - 中栏

struct HitListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.hits.isEmpty {
                ContentUnavailableView {
                    Label(model.isRunning ? "扫描中…" : "还没有号码", systemImage: model.isRunning ? "antenna.radiowaves.left.and.right" : "number")
                } description: {
                    Text(model.isRunning ? "命中的靓号会实时出现在这里" : "左边选好地区和规律，点右上角开始")
                }
            } else {
                List(selection: $model.selectedHitID) {
                    ForEach(model.groupedHits) { group in
                        Section("\(group.rule)（\(group.hits.count)）") {
                            ForEach(group.hits) { h in
                                HitRow(hit: h).tag(h.id as String?)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("扫到的号")
        .navigationSubtitle("\(model.hits.count) 个")
    }
}

struct HitRow: View {
    let hit: Hit

    var body: some View {
        HStack {
            HighlightedNumber(hit: hit, size: 17)
            if hit.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
            Spacer()
            Text(hit.cityName).font(.caption).foregroundStyle(.secondary)
            ScoreBadge(score: hit.score)
        }
        .padding(.vertical, 2)
    }
}

struct HighlightedNumber: View {
    let hit: Hit
    let size: CGFloat

    var body: some View {
        let chars = Array(hit.number)
        let hl = hit.matches.first?.range ?? 0..<0
        var t = Text(verbatim: "")
        for (i, c) in chars.enumerated() {
            let piece = Text(verbatim: String(c))
            if hl.contains(i) {
                t = t + piece.font(.system(size: size, weight: .bold, design: .monospaced)).foregroundColor(.red)
            } else {
                t = t + piece.font(.system(size: size, weight: .regular, design: .monospaced))
            }
            if i == 2 || i == 6 { t = t + Text(verbatim: " ").font(.system(size: size, design: .monospaced)) }
        }
        return t
    }
}

struct ScoreBadge: View {
    let score: Int
    var body: some View {
        Text("\(score)")
            .font(.caption.monospacedDigit().bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
    private var color: Color { score >= 90 ? .red : score >= 70 ? .orange : .blue }
}

// MARK: - 右栏

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let hit = model.selectedHit {
            VStack(alignment: .leading, spacing: 18) {
                HighlightedNumber(hit: hit, size: 34)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    ScoreBadge(score: hit.score)
                    Text("\(hit.provinceName) · \(hit.cityName) · 中国联通").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("命中规律").font(.headline)
                    ForEach(hit.matches, id: \.self) { m in
                        HStack {
                            Text(m.ruleName)
                            Spacer()
                            Text("\(m.score) 分").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: 320)
                HStack {
                    Button { model.copy(hit) } label: { Label("复制号码", systemImage: "doc.on.doc") }
                    Button { model.toggleFavorite(hit.id) } label: {
                        Label(hit.favorite ? "取消收藏" : "收藏", systemImage: hit.favorite ? "star.slash" : "star")
                    }
                }
                Text("号码是联通选号池里随机出的，可能很快被别人选走，看中了尽快去下单。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView("选一个号码看详情", systemImage: "hand.point.left")
        }
    }
}

// MARK: - 底部状态栏

struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showLog: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.caption.monospaced()).id(i)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .onChange(of: model.log.count) { proxy.scrollTo(model.log.count - 1, anchor: .bottom) }
                }
                Divider()
            }
            HStack(spacing: 14) {
                Circle().fill(model.isRunning ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(model.isRunning ? "正在扫描" : "已停止")
                Text("已查 \(model.checkedCount.formatted()) 个")
                Text("命中 \(model.hits.count) 个")
                if model.isRunning {
                    Text("\(model.perMinute.formatted())/分")
                    Text("并发 \(model.concurrency)").foregroundStyle(.secondary)
                }
                if !model.statusNote.isEmpty { Text(model.statusNote).foregroundStyle(.orange) }
                Spacer()
                Button(showLog ? "收起日志" : "日志") { showLog.toggle() }
                    .buttonStyle(.link)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}
