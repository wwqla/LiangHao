import SwiftUI
import AppKit
import Combine

@main
struct LiangHaoApp: App {
    @State private var model = AppModel()

    init() {
        // 用 swift run 直接跑时也显示成正常窗口应用
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("靓号助手") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 600)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.save()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.isRunning ? "暂停" : "开始扫描") { model.toggleRun() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("导出 CSV…") { model.exportCSV() }
                    .keyboardShortcut("e", modifiers: .command)
            }
        }
    }
}
