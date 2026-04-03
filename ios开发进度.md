## 2026-04-03

- 已生成并接入 iOS 平台目录：`ios/`
- 新增 Packet Tunnel Extension：`ios/PacketTunnel`，使用 `file-descriptor`（fd 模式）启动 mihomo
- iOS 原生侧实现 `com.accelerator.tg/mihomo` MethodChannel + `mihomo/traffic` EventChannel（轮询 extension）
- iOS App/Extension 证书与标识对齐：
  - App: `com.xiangyu.clash`
  - Extension: `com.xiangyu.clash.packettunnel`
  - App Group: `group.com.xiangyu.clash`
- Flutter 侧补齐 iOS 工作目录与 Country.mmdb 释放逻辑，避免影响 Android/Windows
- 已将 `mihomo-ios` 内核移动到 `ios/MihomoCore/`，Xcode 工程改为引用 iOS 工程内静态库与头文件
- Flutter 侧启动前会为 iOS 订阅配置补齐 `tun` 段默认项；Packet Tunnel Extension 启动时会再注入/覆盖 `tun.file-descriptor`
- iOS App ↔ Extension 的高频状态（流量/运行态/部分缓存信息）改为通过 App Group 共享状态文件读取，减少 provider message 轮询对真机稳定性的影响
- iOS 侧不接入原生日志 EventChannel，仅保留 `MobileSetLogLevel("silent")` 静默模式，避免真机日志回调/轮询引发额外崩溃风险
- iOS 启动链路已调整为“首页进入优先、VPN 后台拉起”：登录成功后首页不再阻塞等待 `startTunnel` 完成，首次授权/配置保存过程改为在首页后后台继续
- `PacketTunnelProvider.startTunnel()` 已瘦身：completion 前只保留 fd 获取、tun 注入、`MobileStart` 与最小运行态落盘，`getProxies` 延后到启动完成后异步刷新
- 首页左下角已接入 iOS VPN 纯文本状态提示：支持显示“VPN 授权中 / VPN 重试中 / VPN 启动失败，点击重试”，不增加背景层，失败后可在首页直接触发重试
- iOS 原生通道增加就绪探测；Flutter 侧首次取密钥/工作目录前会等待通道 ready 并做轻量重试，降低冷启动早期通道未就绪导致的密钥/目录读取失败
- 共享状态读取已增加 `updatedAt` 10 秒时效校验，并在启动前清理旧状态；`startTunnel` 超时保护已从 12 秒收紧到 8 秒
- 热更新前等待网络已增加 10 秒上限：超时后跳过热更新继续启动，不再因无网无限阻塞首启链路
- 共享状态已补充 `sessionId`：App 发起每次 iOS VPN 启动时生成独立 session，Extension 落盘时同步写入，Flutter 侧仅读取当前 session 的失败信息，降低旧状态串扰新启动的问题
- iOS 首页左下角失败提示已透传 Extension `lastError` 明细：除“点击重试”外，还会显示具体失败原因（如 `startTunnel timeout`、fd 获取失败、系统网络扩展错误等）
- Splash 启动失败不再直接退出 App：登录失败或非 iOS 平台 VPN 启动失败时，会留在启动页显示失败原因并支持“重试启动”
- 启动前网络探测已从单一 `vpnapis.com:443` 扩展为“默认探测点 + 动态服务端 host”多目标探测，降低单点探测异常导致误判离线的风险
- iOS 设备标识优先使用 `identifierForVendor`，并回写到 Keychain 持久化 fallback UUID，减少重装或缓存丢失导致的设备身份漂移
- iOS 手动开关/切模式链路已收紧为“等待 tunnel ready 后再切 mode”；原生 `start` 返回后不再立即把 Flutter 侧 running 缓存置 true，降低 connecting 阶段误判已可切换的风险
- Splash 失败态与首页左下角 VPN 失败态已统一接入错误码/错误文案映射：同一份 raw error 会归一成统一 code + 中文摘要，示例包括 `NETWORK-UNAVAILABLE`、`LOGIN-HTTP`、`VPN-TIMEOUT`、`VPN-FD`
- Windows 环境已回归验证：`flutter analyze`、`flutter test` 通过，当前改动未影响 Android/Windows 分支编译分析
- PacketTunnel 启动链路已进一步加固：共享目录写探测前置、启动超时 work item 可取消、失败时主动停止内核并清理 socket protector，降低 `startTunnel` 超时后误写失败态与被系统强杀后的脏状态
- iOS 17+ fd 获取策略已调整为“优先扫描有效 `utun` fd，KVC `socket.fileDescriptor` 仅作为兜底且二次校验”，减少新系统对私有路径变化导致的无流量风险
- App 侧 `MihomoIosPlugin` 已补充 App Group/Extension 预检、旧/重复 VPN manager 清理与失败后重建一次配置；`getWorkingDirectory` 改为显式返回错误，不再因 App Group 缺失直接崩溃
- Flutter iOS 启动探测已补充 MethodChannel 单次调用超时、更多 ready 重试、共享状态 `updatedAt` 新鲜度校验；新增 `Network Extension` 能力缺失与授权超时错误映射
- iOS 冷启动 `SERVER-URL` 链路继续加固：`initNativeKeys()` 在 iOS 下支持分次累积有效 key（避免单次任一 key 空值导致整体失败），并新增启动失败调试日志弹窗（可查看/复制 Native key trace + App logs）；Android/Windows 保持原有一次性拉取语义不变

### 待办

- 在 macOS + Xcode + 真机环境完成 Packet Tunnel 拉起、签名与 VPN 联调验证
