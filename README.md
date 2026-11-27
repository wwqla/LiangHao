# 靓号助手 (Mac)

参考菠萝扫号 PC 版做的 macOS 原生扫号工具，第一版支持中国联通（全国 31 省、340 个城市）。

## 运行
需要 macOS 14+ 和 Xcode（或 `xcode-select --install` 装命令行工具）。

```bash
./build-app.sh        # 打包成 靓号助手.app，双击运行（系统通知只在 .app 里可用）
# 或者开发时直接跑：
swift run
```
也可以用 Xcode 打开 `Package.swift` 直接运行。

## 用法
1. 左栏勾地区（默认广东全省，可「选择 → 全国」）
2. 勾规律，或添加自定义：`*8888` 尾号、`AABB` 字母模板、`1?14` 任意位、`re:正则`
3. 点右上角 ▶︎ 开始（⌘R），命中的号按规律分组、按靓号分排序；≥90 分会弹通知 + 提示音
4. 选中号码可复制 / 收藏；⌘E 导出 CSV

## 说明
- 数据源：`m.10010.com/NumApp/NumberCenter/qryNum`，每次随机返回约 100 个号；各省 groupKey 在 `RegionData.swift`（2026-11-27 实测 30/31 省可用，宁夏无号）。
- 自动调速：从 1 个并发起步，顺利就慢慢加（稳 ≤4 / 快 ≤10），出错立即减半并退避，避免 IP 被封。
- 加新运营商：实现 `NumberSource` 协议即可。
- 数据保存在 `~/Library/Application Support/LiangHao/data.json`。
