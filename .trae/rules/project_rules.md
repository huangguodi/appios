Windows 平台启动到首页链路记忆（顶层 app 项目，不是 clashmi-main 子项目）

1. Windows 原生入口
- 文件：windows/runner/main.cpp
- 入口函数：wWinMain
- 启动顺序：AttachConsole/CoInitializeEx → flutter::DartProject → 读取命令行参数 → 创建 FlutterWindow → 进入 Win32 消息循环
- 原生窗口初始标题为“加速器”，初始尺寸 1280x720；后续会被 Dart 层 window_manager 再次调整成 300x520 固定窗口

2. Flutter Engine 与原生通道挂载
- 文件：windows/runner/flutter_window.cpp
- 在 FlutterWindow::OnCreate 中创建 FlutterViewController、注册插件、挂载 MethodChannel/EventChannel
- 关键通道：
  - com.accelerator.tg/mihomo：Windows 原生与 Dart 之间的 Mihomo 控制通道
  - com.accelerator.tg/security：调试器检测、安全校验
  - com.accelerator.tg/hot_update：Windows 热更新后重启 APP
  - com.accelerator.tg/mihomo/traffic：实时流量事件
  - com.accelerator.tg/mihomo/logs：原生日志事件
- Windows 原生层负责：
  - 启动/停止 mihomo.dll
  - 切换代理模式
  - 读写系统代理
  - 返回 AES/混淆/serverUrl 动态密钥
  - 返回运行状态、模式、节点、日志等信息

3. Dart 主入口
- 文件：lib/main.dart
- main() 启动顺序：
  - WidgetsFlutterBinding.ensureInitialized()
  - 注册 FlutterError / PlatformDispatcher 异常捕获
  - _enforceSecurity()：Windows 下通过 security channel 检查 isDebuggerAttached / isAppDebuggable；非 debug 命中则直接退出
  - Windows 专属窗口初始化：
    - windowManager.ensureInitialized()
    - waitUntilReadyToShow 后设置 300x520、不可拉伸、不可最大化、关闭时不真正退出
    - TrayService().init() 初始化系统托盘
  - 设置 SystemChrome 样式
  - HotUpdateService().resolveRuntimeAssetBundle()
  - runApp(MyApp(...))
- MyApp build() 中 MaterialApp 的 home 固定是 SplashPage，没有命名路由首页

4. 首屏一定先进入 SplashPage
- 文件：lib/views/splash_page.dart
- SplashPage initState() 中延迟 200ms 调用 _initApp()
- 从打开 APP 到进入首页的核心链路就是 _initApp()

5. SplashPage 启动链路
- _initApp() 的顺序：
  1) _runHotUpdateBeforeLogin()
  2) ApiService().checkLocalToken()
  3) 若本地已有 token，先 ApiService().fetchUserInfo()
  4) _loginWithStartupRetry()
  5) _ensureGiftCardRedeemed()
  6) _startMihomo()
  7) _resolveInitialMode()
  8) _scheduleDeferredStartupTasks()
  9) _navigateToHome(initialMode)
- 任一步失败基本都会走 _exitApp()；Windows 下直接 exit(0)

6. 热更新在登录前执行
- 文件：lib/services/hot_update_service.dart
- performStartupUpdate() 在 Splash 阶段先执行
- Windows env 会被识别为 windows
- 只要更新包被成功应用，就返回 shouldContinue=false / requiresRestart=true
- Splash 收到 appliedUpdate 或 requiresRestart 后不会继续登录和进首页，而是中断当前启动链路，等待重启
- 注意：resolveRuntimeAssetBundle() 当前只对 Android 启用；Windows 主要是“启动前检查并应用更新包”，不是运行时替换 AssetBundle

7. 启动前网络门禁
- Splash 在“热更新”和“登录”两个阶段前，都会先 _waitForStartupNetwork()
- 探测方式：SecureSocket.connect(vpnapis.com, 443)
- 无网络时会停留在 Splash，展示“等待网络连接”，直到联网后才继续

8. 登录与本地凭据
- 文件：lib/services/api_service.dart
- checkLocalToken():
  - 先 initNativeKeys()，通过 com.accelerator.tg/mihomo 向 Windows 原生层读取 AES / obfuscate / serverUrl 三个动态密钥
  - Windows 上 token 和 user_info 主要放在 SharedPreferences，不走 secure storage
  - 只要本地同时存在 auth_token 和 user_info，就认为有本地登录态
- login():
  - 使用 Windows 设备 ID（device_info_plus 的 windowsInfo.deviceId，拿不到再退化到本地 UUID）
  - 对请求体做 AES-GCM + 混淆后发到 /app/v2/login
  - 成功后把 token 与 userInfo 写回本地缓存
- fetchUserInfo():
  - 用 bearer token 拉取 /app/v2/user/info
  - 更新 quota / expire_time / expired_traffic_logs / ads
  - Windows 为减少频繁磁盘写入，user_info 持久化带延迟批量写策略

9. Mihomo 启动与 Windows 特性
- 文件：lib/views/splash_page.dart + lib/services/mihomo_service.dart + windows/runner/flutter_window.cpp
- Splash::_startMihomo() 顺序：
  - MihomoService().init()：准备工作目录与 Country.mmdb
  - 先 checkIsRunning(forceRefresh: true)
  - 若 Windows 下发现已有 mihomo 在跑，则 waitUntilReady() 验证是否真可用
  - 若可用，直接 ensureSystemProxyEnabled() 复用现有隧道
  - 若不可用，则 stop() 后重启
  - 从 ApiService().userInfo 里取 subscribe_url
  - MihomoService().start(subscribeUrl)
  - 启动后循环 waitUntilReady() 探测运行状态与 mode 是否就绪
- MihomoService.start() 内部顺序：
  - 下载订阅配置
  - 保存到 Application Support 目录下 config.yaml
  - 确保 Country.mmdb 存在
  - 通过 MethodChannel 调原生 start
- Windows 原生 start 逻辑：
  - 加载 mihomo.dll 导出函数
  - 校验 config.yaml 与 Country.mmdb
  - g_api.start(homeDir, config.yaml)
  - 启动成功后立即 ApplySystemProxy(true)
  - 如果系统代理设置失败，原生层会直接 stop 并返回错误

10. 首页初始模式是怎么来的
- Splash 成功启动 mihomo 后调用 _resolveInitialMode()
- 逻辑：
  - checkIsRunning(forceRefresh: true)
  - 若没运行，首页模式 = ConnectionMode.off
  - 若运行中，再 getMode(forceRefresh: true)
  - global → ConnectionMode.global
  - direct → ConnectionMode.off
  - 其他（主要是 rule）→ ConnectionMode.smart
- 然后通过 _navigateToHome(initialMode) pushReplacement 到 HomePage

11. 真正进入首页的时刻
- 文件：lib/views/splash_page.dart
- _navigateToHome() 使用 Navigator.pushReplacement + FadeTransition
- 也就是说首页不是启动时直接渲染，而是在 Splash 的所有前置任务完成后被替换上来

12. 首页首次构建时的状态初始化
- 文件：lib/views/home_page.dart
- HomePage 不是直接展示 UI，而是：
  - ChangeNotifierProvider(create: (_) => HomeViewModel(initialMode: initialMode)..init())
  - child: _HomePageContent()
- 所以“进入首页”后立刻执行的核心初始化，实际在 HomeViewModel.init()

13. HomeViewModel.init() 进入首页后的动作
- 文件：lib/view_models/home_view_model.dart
- init() 做三件关键事：
  - unawaited(_initServiceState())
  - _startPolling()：启动 user_info 轮询
  - 订阅 MihomoService().trafficStream 和 runningStateStream
- _initServiceState()：
  - 先把 ApiService().userInfo 中已有的 quota / ads / is_device_bound 填进首页状态
  - 再 checkIsRunning()
  - 如果 mihomo 正在运行：
    - Windows 下 ensureSystemProxyEnabled()
    - getMode() 反推出首页连接模式
    - ensureTrafficMonitor()
    - 后续调度一次 _refreshGlobalNodeInfo()
- 所以首页第一次显示时，很多数据不是路由参数传全的，而是“Splash 给初始 mode + HomeViewModel 再补齐其他状态”

14. 首页展示的核心数据来源
- connectionMode：Splash 传入 initialMode，随后 HomeViewModel 再与原生实际模式对齐
- upload/download speed：来自 mihomo/traffic EventChannel
- quota / ads / 是否绑定设备：来自 ApiService.userInfo 与后续轮询 fetchUserInfo()
- 全局节点名称/国家/UDP：来自 MihomoService 查询代理信息

15. Windows 平台几个容易忽略但很关键的点
- main.cpp 的原生窗口尺寸不是最终尺寸，最终以 Dart 层 window_manager 的 300x520 为准
- 关闭窗口不会退出，只会 hide 到托盘；真正退出通常走托盘菜单“退出”
- Windows 启动首页前必须保证系统代理可被设置成功，否则 Mihomo 启动会被判失败
- Splash 登录前已经可能读取本地 token + userInfo，因此“进入首页前的数据预热”并不完全依赖 login() 返回
- 首页 UI 渲染本身不复杂，真正耗时的是 Splash 中的热更新、联网等待、登录、拉用户信息、拉订阅并启动 Mihomo

16. 一句话总链路
- Windows wWinMain → FlutterWindow 创建 engine 与 MethodChannel → Dart main() 做安全校验/窗口初始化/托盘初始化 → MaterialApp(home: SplashPage) → Splash 执行 热更新 → 本地 token 检查 → 用户信息拉取/登录 → 启动或复用 Mihomo + 设置系统代理 → 解析初始模式 → pushReplacement(HomePage) → HomeViewModel.init() 补齐首页状态并开始轮询/流量订阅

iOS 开发记忆（压缩版，顶层 app 项目，不是 clashmi-main 子项目）

1. 边界与同步要求
- 只在顶层 `app` 项目继续做 iOS 接入，禁止影响 Android/Windows 分支判断
- iOS 开发完成后同步更新 `ios开发进度.md`
- 当前环境只能做代码侧与 Flutter 侧验证，Xcode 编译/签名/真机 VPN 联调仍需 macOS 环境

2. 关键文件
- App 入口：`ios/Runner/AppDelegate.swift`
- iOS 通道桥：`ios/Runner/MihomoIosPlugin.swift`
- Packet Tunnel：`ios/PacketTunnel/PacketTunnelProvider.swift`
- Flutter 启动链路：`lib/main.dart`、`lib/views/splash_page.dart`
- Flutter Mihomo 服务：`lib/services/mihomo_service.dart`
- 首页状态：`lib/view_models/home_view_model.dart`
- 统一错误映射：`lib/core/failure_mapper.dart`

3. 内核与通道约定
- iOS 静态库固定在 `ios/MihomoCore/`，不要再用旧路径 `mihomo-ios/`
- MethodChannel：`com.accelerator.tg/mihomo`
- EventChannel：`com.accelerator.tg/mihomo/traffic`
- 安全通道：`com.accelerator.tg/security`
- iOS 原生侧额外提供 `isReady / getWorkingDirectory / getTunnelStatus`

4. 启动到首页主链路
- `AppDelegate` 注册 `MihomoIosPlugin`
- Dart `main()` → `MaterialApp(home: SplashPage)`
- `SplashPage.initState()` 延迟 200ms 调 `_initApp()`，避免冷启动过早打原生通道
- `_initApp()` 顺序：
  1) `_runHotUpdateBeforeLogin()`
  2) `ApiService().checkLocalToken()`
  3) 如已有 token，先 `fetchUserInfo()`
  4) `_loginWithStartupRetry()`
  5) `_ensureGiftCardRedeemed()`
  6) iOS：`_resolveInitialMode()` → `_navigateToHome(initialMode)` → `unawaited(_startMihomoInBackground())`
- 结论：iOS 现在是“先首页，后 VPN”，不要再把首页显示和 VPN 拉起重新耦合回 Splash

5. 启动失败与错误映射
- Splash 启动失败不再直接退出 App，而是留在启动页显示失败原因并支持“重试启动”
- 首页左下角 VPN 失败态与 Splash 失败态共用 `failure_mapper.dart`
- 同一份 raw error 会被归一成统一错误码/中文摘要，如 `LOGIN-HTTP`、`NETWORK-UNAVAILABLE`、`VPN-TIMEOUT`、`VPN-FD`

6. iOS 原生通道时序约束
- `ApiService.initNativeKeys()` 与 `MihomoService._getWorkingDir()` 在 iOS 下都先走 `isReady` 探测 + 轻量重试
- 冷启动早期不要依赖单次 MethodChannel 成功，关键风险是“引擎与通道刚注册时过早调用原生”

7. Mihomo 启动链路
- `MihomoService.init()`：准备共享工作目录与 `Country.mmdb`
- `MihomoService.start()`：下载订阅、校验配置、Flutter 侧先补 iOS `tun` 默认项、写 `config.yaml`
- App 侧原生 `start`：`NETunnelProviderManager.saveToPreferences()` → `loadFromPreferences()` → `startVPNTunnel()`
- 首次 `startVPNTunnel()` 的系统授权/配置保存行为无法绕过
- iOS 原生 `start` 返回后，Flutter 侧不再立即把 running 缓存置 true，而是等 ready probe 成功后再认定 tunnel 可用

8. PacketTunnel 关键约束
- `startTunnel()` 只做最小必要操作：`NEPacketTunnelNetworkSettings` → fd 获取 → tun 注入 → `MobileStart` → 写最小 running 状态
- `getProxies`、全量共享状态刷新放到 completion 之后异步做
- completion gate 超时当前固定 8 秒，不要回退到 12 秒
- Packet Tunnel 内统一走单串行队列，避免 `start / stop / handleAppMessage` 并发踩状态

9. fd、App Group 与共享状态
- fd 必须坚持双路径：`socket.fileDescriptor` 优先，失败再扫描 `utun`
- `tun` 最终必须有 `enable / stack / file-descriptor`
- App Group 固定：`group.com.xiangyu.clash`
- Bundle ID：App `com.xiangyu.clash`，Extension `com.xiangyu.clash.packettunnel`
- `config.yaml`、`Country.mmdb`、`shared_state.json` 必须放 App Group 目录，不允许 fallback 普通沙盒
- 共享状态已带 `sessionId` + `updatedAt`
- Flutter 侧只接受当前 session 的失败信息，避免旧 `shared_state.json` 串扰新一次启动
- 高频只读状态优先读共享状态文件，不依赖高频 provider message

10. 网络、登录与设备标识
- 热更新仍在登录前执行；“热更新前等网”最多等 10 秒，超时后跳过热更新继续启动
- 登录阶段仍会等网络，因为无网通常无法完成登录/拉用户信息
- 启动前网络探测已从单一 `vpnapis.com:443` 扩展为“默认探测点 + 动态服务端 host”多目标探测
- iOS 设备标识优先使用 `identifierForVendor`，并回写 Keychain 持久化 fallback UUID

11. 首页状态与手动操作
- 首页左下角 iOS 纯文本状态支持：`VPN 授权中 / VPN 重试中 / VPN 启动失败，点击重试`
- `HomeViewModel` 监听 `trafficStream / runningStateStream / iosVpnStartupPhaseStream`
- iOS 手动开关/切模式前先等 tunnel ready，再执行 `switchMode`

12. 当前验证结论
- Windows 环境下 `flutter analyze`、`flutter test` 已通过
- 当前 iOS 代码侧状态：架构、错误透传、session 隔离、启动时序与常见真机坑规避已基本到位
- 当前剩余重点：macOS + Xcode + 真机环境下完成 Packet Tunnel 拉起、签名、权限弹窗与稳定性联调
