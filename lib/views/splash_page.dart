import 'dart:async';
import 'dart:io';
import 'package:app/core/failure_mapper.dart';
import 'package:app/core/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/hot_update_service.dart';
import 'package:app/services/mihomo_service.dart';
import 'package:app/core/constants.dart';
import 'package:app/views/widgets/custom_dialog.dart';
import 'home_page.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  static const int _maxStartupLoginAttempts = 3;
  static const int _maxStartupHotUpdateAttempts = 3;
  static const String _startupNetworkProbeHost = 'vpnapis.com';
  static const Duration _startupNetworkPollInterval = Duration(seconds: 1);
  static const Duration _startupNetworkProbeTimeout = Duration(seconds: 2);
  static const Duration _startupHotUpdateNetworkWaitTimeout = Duration(
    seconds: 10,
  );
  static const List<Duration> _startupLoginRetryDelays = [
    Duration(milliseconds: 250),
    Duration(milliseconds: 500),
  ];
  HotUpdateProgress? _hotUpdateProgress;
  HotUpdateProgress? _lastStableHotUpdateProgress;
  bool _isClosingAfterHotUpdate = false;
  bool _isRetryingHotUpdate = false;
  bool _isWaitingForStartupNetwork = false;
  bool _isInitializingApp = false;
  bool _isRetryingStartup = false;
  String? _startupFailureTitle;
  String? _startupFailureDetail;
  String? _startupFailureDebugLog;
  List<({String host, int port})>? _cachedStartupProbeTargets;

  @override
  void initState() {
    super.initState();
    // 设置沉浸式导航栏
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    // 延迟一帧执行，确保上下文准备好
    // 缩短等待时间，提升启动速度
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) {
        _initApp();
      }
    });
  }

  Future<void> _initApp() async {
    if (_isInitializingApp) {
      return;
    }
    _isInitializingApp = true;
    _clearStartupFailure();
    AppLogger.d('Splash: init start');
    try {
      if (Platform.isIOS) {
        final serverReady = await ApiService().ensureNativeServerUrlReady();
        if (!serverReady) {
          _showStartupFailure(
            category: AppFailureCategory.hotUpdate,
            detail: 'Native server url is empty',
            debugLog: ApiService().nativeKeyDebugReport(),
          );
          return;
        }
      }
      final canContinue = await _runHotUpdateBeforeLogin();
      if (!canContinue || !mounted) {
        AppLogger.w('Splash: init interrupted before login');
        return;
      }

      final hasLocalToken = await ApiService().checkLocalToken();
      AppLogger.d('Splash: local token=$hasLocalToken');

      if (hasLocalToken) {
        await ApiService().fetchUserInfo();
      }

      final errorMsg = await _loginWithStartupRetry();

      if (!mounted) return;

      final success = errorMsg == null;

      if (success) {
        AppLogger.d('Splash: login success');
        final redeemed = await _ensureGiftCardRedeemed();
        if (!redeemed || !mounted) return;
        if (Platform.isIOS) {
          final initialMode = await _resolveInitialMode();
          if (!mounted) return;
          _scheduleDeferredStartupTasks();
          _navigateToHome(initialMode);
          unawaited(_startMihomoInBackground());
          return;
        }
        final startError = await _startMihomo();
        if (startError == null) {
          AppLogger.d('Splash: mihomo ready');
          final initialMode = await _resolveInitialMode();
          _scheduleDeferredStartupTasks();
          _navigateToHome(initialMode);
        } else {
          AppLogger.e('Splash: mihomo start failed $startError');
          _showStartupFailure(
            category: AppFailureCategory.vpnStart,
            detail: startError,
          );
        }
      } else {
        AppLogger.e('Splash: login failed $errorMsg');
        _showStartupFailure(
          category: AppFailureCategory.login,
          detail: errorMsg,
        );
      }
    } finally {
      _isInitializingApp = false;
    }
  }

  Future<void> _startMihomoInBackground() async {
    try {
      final userInfo = ApiService().userInfo;
      final subscribeUrl = userInfo?['subscribe_url']?.toString();
      final started = await MihomoService().ensureIosStarted(
        subscribeUrl: subscribeUrl,
      );
      if (started) {
        AppLogger.d('Splash: mihomo background ready');
      } else {
        AppLogger.e('Splash: mihomo background start failed');
      }
    } catch (e) {
      AppLogger.e('Splash: mihomo background start exception $e');
    }
  }

  Future<bool> _runHotUpdateBeforeLogin() async {
    String? lastError;
    while (mounted) {
      final hasNetwork = await _waitForStartupNetwork(
        stage: '热更新',
        maxWait: _startupHotUpdateNetworkWaitTimeout,
      );
      if (!mounted) return false;
      if (!hasNetwork) {
        AppLogger.w('Splash: skip hot update because startup network wait timed out');
        _clearStartupNetworkWaiting();
        _setHotUpdateProgress(null);
        return true;
      }
      for (var attempt = 0; attempt < _maxStartupHotUpdateAttempts; attempt++) {
        try {
          AppLogger.d('Splash: hot update attempt=${attempt + 1}');
          final result = await HotUpdateService().performStartupUpdate(
            onProgress: (progress) {
              _setHotUpdateProgress(progress);
            },
          );
          if (!mounted) return false;
          if (result.appliedUpdate ||
              result.requiresRestart ||
              !result.shouldContinue) {
            AppLogger.w(
              'Splash: hot update requires stop applied=${result.appliedUpdate} restart=${result.requiresRestart} continue=${result.shouldContinue}',
            );
            return false;
          }
          _setHotUpdateProgress(null);
          AppLogger.d('Splash: hot update finished');
          return true;
        } catch (e) {
          lastError = e.toString();
          AppLogger.e('Splash: hot update error $lastError');
          if (_shouldRetryStartupNetworkError(lastError)) {
            if (attempt < _startupLoginRetryDelays.length) {
              await Future.delayed(_startupLoginRetryDelays[attempt]);
              if (!mounted) {
                return false;
              }
              continue;
            }
            await _showStartupNetworkWaiting(detail: '当前网络不可用，连接后将自动继续检查更新');
            break;
          }
          if (!mounted) return false;
          final presentation = mapAppFailure(
            category: AppFailureCategory.hotUpdate,
            surface: AppFailureSurface.splash,
            rawMessage: lastError,
          );
          _setHotUpdateProgress(
            HotUpdateProgress(
              stage: HotUpdateStage.failed,
              title: presentation.title,
              detail: presentation.detail,
            ),
            rememberStable: false,
          );
          return false;
        }
      }
    }
    if (!mounted) return false;
    final presentation = mapAppFailure(
      category: AppFailureCategory.hotUpdate,
      surface: AppFailureSurface.splash,
      rawMessage: lastError ?? '未知错误',
    );
    _setHotUpdateProgress(
      HotUpdateProgress(
        stage: HotUpdateStage.failed,
        title: presentation.title,
        detail: presentation.detail,
      ),
      rememberStable: false,
    );
    return false;
  }

  Future<String?> _loginWithStartupRetry() async {
    String? lastError;
    while (mounted) {
      final hasNetwork = await _waitForStartupNetwork(stage: '登录');
      if (!mounted || !hasNetwork) {
        return lastError;
      }
      for (var attempt = 0; attempt < _maxStartupLoginAttempts; attempt++) {
        try {
          lastError = await ApiService().login();
        } catch (e) {
          lastError = "Exception: $e";
        }
        if (lastError == null || !_shouldRetryStartupNetworkError(lastError)) {
          return lastError;
        }
        if (attempt >= _startupLoginRetryDelays.length) {
          await _showStartupNetworkWaiting(detail: '当前网络不可用，连接后将自动继续登录');
          break;
        }
        await Future.delayed(_startupLoginRetryDelays[attempt]);
        if (!mounted) {
          return lastError;
        }
        await ApiService().initNativeKeys();
      }
    }
    return lastError;
  }

  Future<bool> _waitForStartupNetwork({
    required String stage,
    Duration? maxWait,
  }) async {
    final startedAt = DateTime.now();
    while (mounted) {
      final available = await _hasStartupNetwork();
      if (available) {
        if (_isWaitingForStartupNetwork) {
          AppLogger.d('Splash: network ready, continue $stage');
        }
        _clearStartupNetworkWaiting();
        return true;
      }
      if (maxWait != null &&
          DateTime.now().difference(startedAt) >= maxWait) {
        AppLogger.w('Splash: startup network wait timed out before $stage');
        return false;
      }
      if (!_isWaitingForStartupNetwork) {
        AppLogger.w('Splash: waiting for network before $stage');
      }
      await _showStartupNetworkWaiting(detail: '请先连接网络，连接成功后将自动继续$stage');
      await Future.delayed(_startupNetworkPollInterval);
    }
    return false;
  }

  Future<bool> _hasStartupNetwork() async {
    final targets = await _resolveStartupProbeTargets();
    for (final target in targets) {
      final available = await _probeStartupTarget(target.host, target.port);
      if (available) {
        return true;
      }
    }
    return false;
  }

  Future<List<({String host, int port})>> _resolveStartupProbeTargets() async {
    final cached = _cachedStartupProbeTargets;
    if (cached != null && cached.length > 1) {
      return cached;
    }
    final targets = <({String host, int port})>[
      (host: _startupNetworkProbeHost, port: 443),
    ];
    try {
      final apiProbeUri = await ApiService().resolveStartupProbeUri();
      if (apiProbeUri != null) {
        final port = apiProbeUri.hasPort
            ? apiProbeUri.port
            : (apiProbeUri.scheme.toLowerCase() == 'http' ? 80 : 443);
        targets.add((host: apiProbeUri.host, port: port));
      }
    } catch (e) {
      AppLogger.w('Splash: resolve startup probe uri failed $e');
    }
    final deduped = <({String host, int port})>[];
    final seen = <String>{};
    for (final target in targets) {
      final key = '${target.host}:${target.port}';
      if (target.host.trim().isEmpty || !seen.add(key)) {
        continue;
      }
      deduped.add(target);
    }
    if (cached == null || deduped.length >= cached.length) {
      _cachedStartupProbeTargets = deduped;
    }
    return deduped;
  }

  Future<bool> _probeStartupTarget(String host, int port) async {
    if (Platform.isWindows) {
      Socket? socket;
      try {
        socket = await Socket.connect(
          host,
          port,
          timeout: _startupNetworkProbeTimeout,
        );
        return true;
      } on SocketException {
        return false;
      } on TimeoutException {
        return false;
      } catch (e) {
        AppLogger.w('Splash: network probe error $host:$port $e');
        return false;
      } finally {
        socket?.destroy();
      }
    }

    SecureSocket? socket;
    try {
      socket = await SecureSocket.connect(
        host,
        port,
        timeout: _startupNetworkProbeTimeout,
      );
      return true;
    } on SocketException {
      return false;
    } on HandshakeException {
      return false;
    } on TimeoutException {
      return false;
    } catch (e) {
      AppLogger.w('Splash: network probe error $host:$port $e');
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _showStartupNetworkWaiting({required String detail}) async {
    _isWaitingForStartupNetwork = true;
    if (!mounted) {
      return;
    }
    _setHotUpdateProgress(
      HotUpdateProgress(
        stage: HotUpdateStage.idle,
        title: '等待网络连接',
        detail: detail,
      ),
      rememberStable: false,
    );
  }

  void _clearStartupNetworkWaiting() {
    final shouldClear =
        _hotUpdateProgress?.stage == HotUpdateStage.idle &&
        _hotUpdateProgress?.title == '等待网络连接';
    _isWaitingForStartupNetwork = false;
    if (!mounted || !shouldClear) {
      return;
    }
    _setHotUpdateProgress(null);
  }

  void _setHotUpdateProgress(
    HotUpdateProgress? progress, {
    bool rememberStable = true,
  }) {
    if (!mounted) {
      return;
    }
    setState(() {
      if (progress != null &&
          rememberStable &&
          progress.stage != HotUpdateStage.failed &&
          progress.stage != HotUpdateStage.idle) {
        _lastStableHotUpdateProgress = progress;
      }
      _hotUpdateProgress = progress;
    });
  }

  bool _shouldRetryStartupNetworkError(String? errorMsg) {
    if (errorMsg == null) {
      return false;
    }
    final normalized = errorMsg.toLowerCase();
    return normalized.contains('failed host lookup') ||
        normalized.contains('timeoutexception') ||
        normalized.contains('socketexception') ||
        normalized.contains(
          'connection closed before full header was received',
        ) ||
        normalized.contains('connection reset by peer');
  }

  Future<bool> _ensureGiftCardRedeemed() async {
    if (!mounted) return false;
    if (!ApiService().isDpidInvalid) return true;
    await _showGiftCardRedeemFullscreenDialog();
    return mounted;
  }

  Future<void> _showGiftCardTipDialog({
    required BuildContext dialogContext,
    required String message,
    bool isError = true,
  }) async {
    await showAnimatedDialog<void>(
      context: dialogContext,
      barrierDismissible: true,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF96CBFF), width: 1.1),
          ),
          titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  isError ? '兑换失败' : '提示',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(
                  Icons.close_rounded,
                  color: Colors.white60,
                  size: 20,
                ),
              ),
            ],
          ),
          content: Text(
            message,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                '确定',
                style: TextStyle(
                  color: isError ? Colors.redAccent : const Color(0xFF96CBFF),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showGiftCardRedeemFullscreenDialog() async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'gift_card_redeem',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, animation, secondaryAnimation) {
        final controller = TextEditingController();
        bool isSubmitting = false;

        return StatefulBuilder(
          builder: (context, setState) {
            final canRedeem = controller.text.trim().isNotEmpty;
            return PopScope(
              canPop: false,
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: Stack(
                  children: [
                    Positioned.fill(
                      child: Image.asset(
                        AppAssets.resolveImage(context, 'gradient3.png'),
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                      ),
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 22,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 28),
                            const Text(
                              '礼品卡兑换',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 9),
                            const Text(
                              '您将获得 100GB流量包,有效期5天，流量实时到账，立即生效使用',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                                height: 1.4,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 7),
                            const Text(
                              '获取方案：请联系推荐人获取礼品卡密',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                                height: 1.6,
                              ),
                            ),
                            const SizedBox(height: 24),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: controller,
                                    enabled: !isSubmitting,
                                    onChanged: (_) => setState(() {}),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                    ),
                                    decoration: InputDecoration(
                                      hintText: '礼品卡密',
                                      hintStyle: const TextStyle(
                                        color: Colors.white38,
                                      ),
                                      filled: true,
                                      fillColor: Colors.white.withValues(
                                        alpha: 0.09,
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: BorderSide(
                                          color: Colors.white.withValues(
                                            alpha: 0.24,
                                          ),
                                        ),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: const BorderSide(
                                          color: Color(0xFF96CBFF),
                                          width: 1.2,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                SizedBox(
                                  width: 33,
                                  height: 48,
                                  child: OutlinedButton.icon(
                                    onPressed: isSubmitting
                                        ? null
                                        : () async {
                                            final clipData =
                                                await Clipboard.getData(
                                                  'text/plain',
                                                );
                                            final text =
                                                clipData?.text?.trim() ?? '';
                                            if (text.isEmpty) return;
                                            controller.text = text;
                                            controller.selection =
                                                TextSelection.fromPosition(
                                                  TextPosition(
                                                    offset:
                                                        controller.text.length,
                                                  ),
                                                );
                                            setState(() {});
                                          },
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: const Color(0xFF96CBFF),
                                      side: const BorderSide(
                                        color: Color(0xFF96CBFF),
                                        width: 1,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                      ),
                                    ),
                                    label: const Text('粘贴'),
                                  ),
                                ),
                              ],
                            ),
                            const Spacer(),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: isSubmitting || !canRedeem
                                    ? null
                                    : () async {
                                        final invite = controller.text.trim();
                                        setState(() {
                                          isSubmitting = true;
                                        });
                                        final result = await ApiService()
                                            .submitGiftCard(invite: invite);
                                        if (!context.mounted) return;
                                        if (result.isSuccess) {
                                          final reloginError =
                                              await ApiService().login();
                                          if (!context.mounted) return;
                                          if (reloginError == null ||
                                              !ApiService().isDpidInvalid) {
                                            Navigator.of(context).pop();
                                            return;
                                          }
                                          setState(() {
                                            isSubmitting = false;
                                          });
                                          await _showGiftCardTipDialog(
                                            dialogContext: context,
                                            message: '卡密已提交，但账号状态未更新，请重试',
                                          );
                                          return;
                                        }
                                        setState(() {
                                          isSubmitting = false;
                                        });
                                        await _showGiftCardTipDialog(
                                          dialogContext: context,
                                          message: result.msg,
                                        );
                                      },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF96CBFF),
                                  foregroundColor: Colors.black,
                                  disabledBackgroundColor: const Color(
                                    0xFF96CBFF,
                                  ).withValues(alpha: 0.7),
                                  disabledForegroundColor: Colors.black54,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  elevation: 0,
                                ),
                                child: isSubmitting
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                          color: Colors.black87,
                                        ),
                                      )
                                    : const Text(
                                        '兑换',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.black,
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.05),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Future<String?> _startMihomo() async {
    try {
      AppLogger.d('Splash: mihomo init start');
      await MihomoService().init();

      final isRunning = await MihomoService().checkIsRunning(
        forceRefresh: true,
      );
      if (isRunning) {
        var ready = true;
        if (Platform.isWindows) {
          ready = await MihomoService().waitUntilReady(
            timeout: const Duration(seconds: 2),
          );
          AppLogger.d('Splash: existing Windows mihomo ready=$ready');
        }
        if (ready) {
          final proxyEnsured = await MihomoService().ensureSystemProxyEnabled();
          AppLogger.d(
            'Splash: reusing existing mihomo tunnel proxyReady=$proxyEnsured',
          );
          return null;
        }
        AppLogger.w('Splash: existing Windows mihomo state is stale, restarting');
        await MihomoService().stop();
        await Future.delayed(const Duration(milliseconds: 300));
      }

      final userInfo = ApiService().userInfo;
      if (userInfo != null) {
        final subscribeUrl = userInfo['subscribe_url'];
        if (subscribeUrl != null && subscribeUrl.toString().isNotEmpty) {
          final startError = await MihomoService().start(
            subscribeUrl: subscribeUrl.toString(),
          );
          if (startError != null) {
            AppLogger.e('Splash: mihomo start error $startError');
            return startError;
          }
          for (int i = 0; i < 10; i++) {
            final running = await MihomoService().waitUntilReady(
              timeout: const Duration(milliseconds: 900),
            );
            if (running) {
              AppLogger.d('Splash: mihomo running after ${i + 1} probes');
              return null;
            }
            await Future.delayed(const Duration(milliseconds: 250));
          }
          AppLogger.e('Splash: mihomo running probe timeout');
          if (Platform.isWindows) {
            final nativeLogDetails = await MihomoService().buildNativeLogDetails(
              title: '最近 Windows Mihomo 日志',
              maxLines: 20,
            );
            if (nativeLogDetails.isNotEmpty) {
              AppLogger.e(nativeLogDetails);
            }
          }
          return 'startup probe timeout';
        } else {
          AppLogger.e('Splash: subscribe url missing');
          return 'subscribe url missing';
        }
      }
      AppLogger.e('Splash: user info missing for mihomo start');
      return 'subscribe url missing';
    } on PlatformException catch (e) {
      AppLogger.e('Splash: mihomo start platform exception $e');
      return e.message ?? e.toString();
    } catch (e) {
      AppLogger.e('Splash: mihomo start unknown exception $e');
      return e.toString();
    }
  }

  void _showStartupFailure({
    required AppFailureCategory category,
    String? detail,
    String? debugLog,
  }) {
    if (!mounted) {
      return;
    }
    final presentation = mapAppFailure(
      category: category,
      surface: AppFailureSurface.splash,
      rawMessage: detail,
    );
    setState(() {
      _startupFailureTitle = presentation.title;
      _startupFailureDetail = presentation.detail;
      _startupFailureDebugLog = debugLog;
    });
  }

  void _clearStartupFailure() {
    if (!mounted) {
      return;
    }
    if (_startupFailureTitle == null && _startupFailureDetail == null) {
      return;
    }
    setState(() {
      _startupFailureTitle = null;
      _startupFailureDetail = null;
      _startupFailureDebugLog = null;
    });
  }

  Future<void> _exitApp() async {
    if (kIsWeb) return;
    if (Platform.isWindows) {
      exit(0);
    }
    if (Platform.isAndroid) {
      await SystemNavigator.pop();
      return;
    }
    exit(0);
  }

  Future<ConnectionMode> _resolveInitialMode() async {
    try {
      final isRunning = await MihomoService().checkIsRunning(
        forceRefresh: true,
      );
      if (!isRunning) return ConnectionMode.off;
      final mode = await MihomoService().getMode(
        forceRefresh: true,
        timeout: const Duration(seconds: 2),
      );
      AppLogger.d('Splash: resolved mode=$mode');
      if (mode == 'global') return ConnectionMode.global;
      if (mode == 'direct') return ConnectionMode.off;
      return ConnectionMode.smart;
    } catch (_) {
      AppLogger.e('Splash: resolve initial mode failed');
      return ConnectionMode.off;
    }
  }

  void _scheduleDeferredStartupTasks() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runDeferredStartupTasks());
    });
  }

  Future<void> _runDeferredStartupTasks() async {
    if (kIsWeb || !Platform.isAndroid) {
      return;
    }
    try {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
      if (await Permission.ignoreBatteryOptimizations.isDenied) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    } catch (e) {
      debugPrint('SplashPage deferred permission request skipped: $e');
    }
  }

  Future<void> _navigateToHome(ConnectionMode initialMode) async {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            HomePage(initialMode: initialMode),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 800),
      ),
    );
  }

  double _progressValue(double value) {
    return value.clamp(0.0, 1.0);
  }

  int _hotUpdateStepIndex(HotUpdateStage stage) {
    switch (stage) {
      case HotUpdateStage.checking:
        return 1;
      case HotUpdateStage.downloading:
        return 2;
      case HotUpdateStage.extracting:
      case HotUpdateStage.applying:
        return 3;
      case HotUpdateStage.completed:
      case HotUpdateStage.restarting:
        return 4;
      case HotUpdateStage.failed:
      case HotUpdateStage.idle:
        return 0;
    }
  }

  double _hotUpdateStepProgress(HotUpdateProgress progress) {
    switch (progress.stage) {
      case HotUpdateStage.checking:
        return 0.35;
      case HotUpdateStage.downloading:
        return _progressValue(progress.downloadProgress);
      case HotUpdateStage.extracting:
        return _progressValue(progress.extractProgress * 0.5);
      case HotUpdateStage.applying:
        return _progressValue(0.5 + progress.applyProgress * 0.5);
      case HotUpdateStage.completed:
      case HotUpdateStage.restarting:
        return 1;
      case HotUpdateStage.failed:
      case HotUpdateStage.idle:
        return 0;
    }
  }

  HotUpdateProgress _displayHotUpdateProgress(HotUpdateProgress progress) {
    if (progress.stage == HotUpdateStage.failed &&
        _lastStableHotUpdateProgress != null) {
      return _lastStableHotUpdateProgress!;
    }
    return progress;
  }

  double _overallHotUpdateProgress(HotUpdateProgress progress) {
    final displayProgress = _displayHotUpdateProgress(progress);
    final stepIndex = _hotUpdateStepIndex(displayProgress.stage);
    if (stepIndex <= 0) {
      return 0;
    }
    return _progressValue(
      ((stepIndex - 1) + _hotUpdateStepProgress(displayProgress)) / 4,
    );
  }

  bool _shouldShowCloseAction(HotUpdateProgress progress) {
    return progress.stage == HotUpdateStage.completed ||
        progress.stage == HotUpdateStage.restarting ||
        progress.stage == HotUpdateStage.failed;
  }

  Future<void> _closeAppForHotUpdate() async {
    if (_isClosingAfterHotUpdate) {
      return;
    }
    setState(() {
      _isClosingAfterHotUpdate = true;
    });
    await _exitApp();
  }

  Future<void> _retryHotUpdate() async {
    if (_isRetryingHotUpdate || _isClosingAfterHotUpdate) {
      return;
    }
    setState(() {
      _isRetryingHotUpdate = true;
      _hotUpdateProgress = null;
      _lastStableHotUpdateProgress = null;
    });
    try {
      await _initApp();
    } finally {
      if (mounted) {
        setState(() {
          _isRetryingHotUpdate = false;
        });
      }
    }
  }

  Future<void> _retryStartup() async {
    if (_isRetryingStartup || _isClosingAfterHotUpdate) {
      return;
    }
    setState(() {
      _isRetryingStartup = true;
      _startupFailureTitle = null;
      _startupFailureDetail = null;
      _startupFailureDebugLog = null;
    });
    try {
      await _initApp();
    } finally {
      if (mounted) {
        setState(() {
          _isRetryingStartup = false;
        });
      }
    }
  }

  Widget _buildHotUpdatePanel() {
    final progress = _hotUpdateProgress;
    if (progress == null) {
      return const SizedBox.shrink();
    }
    final overallProgress = _overallHotUpdateProgress(progress);
    final percentText = '${(overallProgress * 100).toStringAsFixed(0)}%';
    final isFailed = progress.stage == HotUpdateStage.failed;
    final statusText = _hotUpdateStatusText(progress);
    return SizedBox(
      width: double.infinity,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    statusText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isFailed ? const Color(0xFFFFD7D7) : Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  percentText,
                  style: TextStyle(
                    color: isFailed
                        ? const Color(0xFFFFB0B0)
                        : const Color(0xFF96CBFF),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: overallProgress,
                minHeight: 8,
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                valueColor: AlwaysStoppedAnimation(
                  isFailed ? const Color(0xFFFF8A8A) : const Color(0xFF96CBFF),
                ),
              ),
            ),
            if (isFailed) ...[
              const SizedBox(height: 14),
              TextButton(
                onPressed: _isRetryingHotUpdate ? null : _retryHotUpdate,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF96CBFF),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(
                  _isRetryingHotUpdate ? '正在重试...' : '重试更新',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            if (_shouldShowCloseAction(progress)) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: _isClosingAfterHotUpdate
                    ? null
                    : _closeAppForHotUpdate,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF96CBFF),
                  disabledForegroundColor: Colors.white38,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(
                  _isClosingAfterHotUpdate ? '正在关闭 App...' : '确认关闭 App',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _hotUpdateStatusText(HotUpdateProgress progress) {
    if (progress.stage == HotUpdateStage.failed) {
      return progress.detail;
    }
    if (progress.detail.trim().isNotEmpty) {
      return progress.detail;
    }
    return progress.title;
  }

  Widget _buildStartupFailurePanel() {
    final title = _startupFailureTitle;
    final detail = _startupFailureDetail;
    final debugLog = _startupFailureDebugLog;
    if (title == null || detail == null) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      width: double.infinity,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFFFFD7D7),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: _isRetryingStartup ? null : _retryStartup,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF96CBFF),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(
                _isRetryingStartup ? '正在重试...' : '重试启动',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (Platform.isIOS && (debugLog?.isNotEmpty ?? false)) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _showStartupDebugLogDialog,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF96CBFF),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text(
                  '查看调试日志',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _showStartupDebugLogDialog() async {
    final logText = _startupFailureDebugLog;
    if (logText == null || logText.isEmpty || !mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF13283C),
          title: const Text(
            'iOS 启动调试日志',
            style: TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: SelectableText(
                logText,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: logText));
              },
              child: const Text('复制日志'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFF101F2D),
        body: SafeArea(
          minimum: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Hero(
                  tag: 'app_logo',
                  child: Material(
                    color: Colors.transparent,
                    child: Image.asset(
                      AppAssets.resolveImage(context, 'logo.png'),
                      scale: 4.0,
                    ),
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: _hotUpdateProgress == null &&
                          _startupFailureTitle == null
                      ? const SizedBox(height: 0)
                      : const SizedBox(height: 26),
                ),
                _buildHotUpdatePanel(),
                if (_hotUpdateProgress == null) _buildStartupFailurePanel(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
