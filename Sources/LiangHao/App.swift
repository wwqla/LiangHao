import SwiftUI
import AppKit
import Combine

extension Color {
    /// 主色：中国红
    static let lucky = Color(red: 0.86, green: 0.16, blue: 0.13)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 关掉窗口不退出，菜单栏图标继续显示扫描进度
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct LiangHaoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var web = WebScanner()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("靓号助手", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
                .tint(.lucky)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.save()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands { AppCommands(model: model) }

        Window("网页扫号", id: "web") {
            WebScanView()
                .environment(model)
                .environment(web)
                .tint(.lucky)
        }
        .defaultSize(width: 560, height: 860)

        Settings {
            SettingsView()
                .environment(model)
                .tint(.lucky)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: model.isRunning ? "sparkle.magnifyingglass" : "sparkles")
            if model.isRunning || !model.hits.isEmpty {
                Text("\(model.hits.count)")
            }
        }
    }
}

// MARK: - 菜单栏

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // 去掉「新建窗口」
        CommandGroup(replacing: .newItem) {}

        CommandGroup(replacing: .importExport) {
            Button("导出 Excel…") { model.export(.excel) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.hits.isEmpty)
            Button("只导出新号码…") { model.export(.excel, onlyNew: true) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.hits.isEmpty || model.lastExportDate == nil)
            Button("导出 CSV…") { model.export(.csv) }
                .disabled(model.hits.isEmpty)
        }

        CommandMenu("扫描") {
            Button(model.isRunning ? "暂停扫描" : "开始扫描") { model.toggleRun() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("网页扫号（移动 / 电信 / 广电）…") { openWindow(id: "web") }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Button("选择地区…") { model.showRegionPicker = true }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.isRunning)
            Picker("速度", selection: Binding(get: { model.speed }, set: { model.speed = $0; model.save() })) {
                ForEach(Speed.allCases) { Text($0 == .steady ? "稳（不易被限流）" : "快").tag($0) }
            }
            .disabled(model.isRunning)
            Divider()
            Button("清空结果（保留收藏）") { model.clearResults() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(model.isRunning || model.hits.isEmpty)
        }

        CommandGroup(after: .sidebar) {
            Button(model.showLog ? "隐藏日志" : "显示日志") { model.showLog.toggle() }
                .keyboardShortcut("l", modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            Link("项目主页（GitHub）", destination: URL(string: "https://github.com/wwqla/LiangHao")!)
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.isRunning ? "正在扫描 · 命中 \(model.hits.count)" : "已停止 · 命中 \(model.hits.count)")
        Button(model.isRunning ? "暂停扫描" : "开始扫描") { model.toggleRun() }
        Divider()
        let top = model.hits.sorted { $0.foundAt > $1.foundAt }.prefix(5)
        if !top.isEmpty {
            Text("最近命中")
            ForEach(Array(top)) { h in
                Button("\(h.formatted)  ·  \(h.cityName)  ·  \(h.score)分") {
                    model.selectedHitID = h.id
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
            Divider()
        }
        Button("打开主窗口") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("退出") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
