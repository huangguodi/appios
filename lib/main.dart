import 'dart:async';
import 'dart:io';
import 'package:app/core/constants.dart';
import 'package:app/core/logger.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/hot_update_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:window_manager/window_manager.dart';
import 'services/tray_service.dart';
import 'views/splash_page.dart';

const MethodChannel _securityChannel = MethodChannel(
  'com.accelerator.tg/security',
);
const Duration _securityWatchdogInterval = Duration(seconds: 5);
const Duration _initialSecurityWatchdogDelay = Duration(seconds: 4);
const bool _useWindowsTrayBehavior = true;
Timer? _securityWatchdog;
bool _isSecurityCheckInFlight = false;

bool get _shouldEnforceRuntimeSecurity => !kDebugMode;

class _DirectOnlyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'DIRECT';
    return client;
  }
}

Future<void> _enforceSecurity() async {
  if (!kIsWeb && (Platform.isWindows || !kDebugMode)) {
    HttpOverrides.global = _DirectOnlyHttpOverrides();
  }
  final isSupportedPlatform =
      !kIsWeb && (Platform.isAndroid || Platform.isWindows);
  if (!isSupportedPlatform) {
    return;
  }
  _securityWatchdog?.cancel();
  if (!_shouldEnforceRuntimeSecurity) {
    _scheduleNextSecurityCheck(initial: true);
    return;
  }
  try {
    final isDebuggerAttached =
        await _securityChannel.invokeMethod<bool>('isDebuggerAttached') ??
        false;
    final isAppDebuggable =
        await _securityChannel.invokeMethod<bool>('isAppDebuggable') ?? false;
    if (isDebuggerAttached || isAppDebuggable) {
      await SystemNavigator.pop();
      return;
    }
    _scheduleNextSecurityCheck(initial: true);
  } catch (_) {
    // Initial setup error, we can ignore to prevent false positive crashes
  }
}

void _scheduleNextSecurityCheck({required bool initial}) {
  final active = _shouldEnforceRuntimeSecurity;
  AppPollingTaskRegistry.instance.registerTask(
    id: 'security_watchdog',
    interval: _securityWatchdogInterval,
    initialDelay: _initialSecurityWatchdogDelay,
    owner: 'main',
    active: active,
  );
  if (!active) {
    return;
  }
  final delay = initial
      ? _initialSecurityWatchdogDelay
      : _securityWatchdogInterval;
  _securityWatchdog = Timer(delay, () async {
    await _runSecurityWatchdogCheck();
    _scheduleNextSecurityCheck(initial: false);
  });
}

Future<void> _runSecurityWatchdogCheck() async {
  if (!_shouldEnforceRuntimeSecurity) {
    return;
  }
  if (_isSecurityCheckInFlight) return;
  _isSecurityCheckInFlight = true;
  try {
    AppPollingTaskRegistry.instance.markTaskExecuted('security_watchdog');
    final attached =
        await _securityChannel.invokeMethod<bool>('isDebuggerAttached') ??
        false;
    final debuggable =
        await _securityChannel.invokeMethod<bool>('isAppDebuggable') ?? false;
    if (attached || debuggable) {
      await SystemNavigator.pop();
    }
  } catch (_) {
  } finally {
    _isSecurityCheckInFlight = false;
  }
}

Future<void> main() async {
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        AppLogger.e(
          details.exceptionAsString(),
          details.exception,
          details.stack,
        );
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        AppLogger.e(error.toString(), error, stack);
        return true;
      };

      await _enforceSecurity();

      if (!kIsWeb && Platform.isWindows) {
        await windowManager.ensureInitialized();

        WindowOptions windowOptions = const WindowOptions(
          size: Size(300, 520),
          minimumSize: Size(300, 520),
          maximumSize: Size(300, 520),
          center: true,
          backgroundColor: Colors.transparent,
          skipTaskbar: false,
          titleBarStyle: TitleBarStyle.normal,
          title: '加速器',
        );

        await windowManager.waitUntilReadyToShow(windowOptions, () async {
          await windowManager.setResizable(false);
          await windowManager.setMaximizable(false);
          await windowManager.setPreventClose(_useWindowsTrayBehavior);
          await windowManager.show();
          await windowManager.focus();
        });

        if (_useWindowsTrayBehavior) {
          await TrayService().init();
        }
      }

      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
      );

      final runtimeAssetBundle = await HotUpdateService()
          .resolveRuntimeAssetBundle();

      runApp(MyApp(assetBundle: runtimeAssetBundle));
    },
    (error, stack) {
      AppLogger.e(error.toString(), error, stack);
    },
  );
}

class MyApp extends StatefulWidget {
  final AssetBundle assetBundle;

  const MyApp({super.key, required this.assetBundle});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp>
    with WidgetsBindingObserver, WindowListener {
  Size get _designSize {
    if (!kIsWeb && Platform.isWindows) {
      return const Size(300, 520);
    }
    return const Size(360, 800);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb && Platform.isWindows) {
      windowManager.addListener(this);
      _initTray();
    }
  }

  Future<void> _initTray() async {}

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!kIsWeb && Platform.isWindows) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(ApiService().flushPendingUserInfoCache());
    }
  }

  @override
  void onWindowClose() async {
    if (!kIsWeb && Platform.isWindows) {
      final isPreventClose = await windowManager.isPreventClose();
      if (isPreventClose) {
        await ApiService().flushPendingUserInfoCache();
        await windowManager.hide();
      }
    }
    super.onWindowClose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultAssetBundle(
      bundle: widget.assetBundle,
      child: ScreenUtilInit(
        designSize: _designSize,
        minTextAdapt: true,
        splitScreenMode: true,
        child: const SplashPage(),
        builder: (context, child) {
          return MaterialApp(
            navigatorKey: appNavigatorKey,
            title: 'VPN App',
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF101F2D),
              ),
              useMaterial3: true,
              scaffoldBackgroundColor: const Color(0xFF101F2D),
            ),
            home: child ?? const SizedBox.shrink(),
            builder: (context, appChild) => appChild ?? const SizedBox.shrink(),
            debugShowCheckedModeBanner: false,
          );
        },
      ),
    );
  }
}
