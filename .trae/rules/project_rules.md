项目关键记忆（压缩版）

一、边界
- 仅维护顶层 `app` 项目，`clashmi-main` 只作参考实现，不直接改动。
- iOS 变更不得影响 Android/Windows 分支判断与运行路径。
- 当前环境仅做代码侧验证；iOS 真机 VPN 联调需 macOS/Xcode。

二、Windows 启动主链路（从启动到首页）
- 入口：`windows/runner/main.cpp` 的 `wWinMain`。
- 引擎/通道：`windows/runner/flutter_window.cpp` 挂载 `com.accelerator.tg/mihomo`、`.../security`、`.../traffic`、`.../logs`、`.../hot_update`。
- Dart 入口：`lib/main.dart`；`MaterialApp(home: SplashPage)` 固定先走 `SplashPage`。
- Splash 启动序：热更新 → 本地 token 检查/用户信息 → 登录重试 → 启动/复用 Mihomo → 解析 mode → 跳转 Home。
- Home 首次状态补齐在 `HomeViewModel.init()`，并开启轮询与流量订阅。

三、Windows 关键约束
- 原生窗口初始 1280x720，最终以 Dart `window_manager` 的 300x520 为准。
- 关闭窗口默认隐藏到托盘，不是真退出。
- Windows 启动前必须确保系统代理可设置成功，否则 Mihomo 启动判失败。
- 启动前网络门禁：`SecureSocket.connect(vpnapis.com, 443)`；无网停留 Splash。

四、iOS 启动与通道约定
- 关键文件：`ios/Runner/AppDelegate.swift`、`ios/Runner/MihomoIosPlugin.swift`、`ios/PacketTunnel/PacketTunnelProvider.swift`。
- 通道：`com.accelerator.tg/mihomo`、`.../traffic`、`.../security`。
- iOS 当前策略：先进入首页，再后台拉起 VPN（Splash 不再和 VPN 强耦合）。
- 冷启动早期通道调用需带重试（`isReady` 探测）。

五、iOS PacketTunnel 当前实现要点（2026-04-03）
- Dart 层已移除 iOS tun 注入；仅原生侧处理 tun 与 fd 注入。
- 订阅配置无 `tun` 时，PacketTunnel 会补最小 tun scaffold；最终强制写入 `file-descriptor`。
- `NEPacketTunnelNetworkSettings` 由配置动态解析生成；仅当 `tun.auto-route == true` 时下发系统路由与 DNS，降低“开 VPN 触发 Wi‑Fi 抖动”风险。
- 已接入 `MobileSetSocketProtector`（mark/protect/stop/异常清理全链路）。

六、iOS 已知风险与后续
- 当前仍是“解析 YAML 映射 tun options”，尚非直接消费 core 结构化 TunOptions；行为接近 `clashmi-main`，但非完全同构。
- 若需完全同构，需上游导出结构化 tun options 接口，减少文本推断误差。
- 真机重点回归：Wi‑Fi↔蜂窝切换、direct/global/rule 切换、DNS 与纯 IP 连通性。

七、已完成的专项记忆
- SERVER-URL 冷启动时序问题（2026-04-03）已修复：iOS Native key 初始化重试 + 启动前确保 serverUrl 就绪；`update_server_url.py` 目标改为 `MihomoIosPlugin.swift`。
