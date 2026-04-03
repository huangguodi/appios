import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:app/core/constants.dart';
import 'package:app/core/logger.dart';
import 'package:app/services/api_service.dart'; // Import ApiService
import 'package:app/services/hot_update_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

enum IosVpnStartupPhase { idle, authorizing, retrying, failed }

class MihomoService {
  static const MethodChannel _channel = MethodChannel(
    'com.accelerator.tg/mihomo',
  );
  static const bool _verboseNativeLogs = bool.fromEnvironment(
    'MIHOMO_VERBOSE_NATIVE_LOGS',
    defaultValue: false,
  );
  static const Duration _proxyCacheTtl = Duration(seconds: 12);
  static const Duration _statusCacheTtl = Duration(seconds: 2);
  static const Duration _daemonCheckInterval = Duration(seconds: 5);
  static const Duration _initialDaemonCheckDelay = Duration(seconds: 3);
  static const Duration _windowsStatusQueryCooldown = Duration(
    milliseconds: 900,
  );
  static const Duration _startupReadyProbeTimeout = Duration(milliseconds: 900);
  static const Duration _startupReadyPollInterval = Duration(milliseconds: 350);
  static const Duration _windowsProxyRetryInterval = Duration(
    milliseconds: 700,
  );
  static const Duration _windowsProxyRetryTimeout = Duration(seconds: 8);
  static const int _maxRecentNativeLogs = 200;
  static const int _nativeChannelReadyAttempts = 10;
  static const Duration _nativeChannelRetryDelay = Duration(milliseconds: 200);
  static const Duration _nativeChannelReadyCallTimeout = Duration(
    milliseconds: 800,
  );
  static const Duration _iosTunnelStatusTimeout = Duration(milliseconds: 900);
  static const Duration _iosWorkingDirectoryTimeout = Duration(seconds: 2);
  static const Duration _iosStartInvokeTimeout = Duration(seconds: 12);
  static final MihomoService _instance = MihomoService._internal();

  factory MihomoService() {
    return _instance;
  }

  MihomoService._internal();

  bool _isRunning = false;
  Directory? _workingDir;
  String? _lastSubscribeUrl;
  Timer? _daemonTimer;
  int _restartCount = 0;
  int _daemonConsecutiveFailures = 0;
  String? _lastSelectedGlobalProxy;
  bool? _cachedIsRunning;
  DateTime? _cachedIsRunningAt;
  String? _cachedMode;
  DateTime? _cachedModeAt;
  final Map<String, String> _cachedSelectedProxyByGroup = {};
  final Map<String, DateTime> _cachedSelectedProxyAtByGroup = {};
  Future<bool>? _pendingIsRunningRequest;
  Future<String>? _pendingModeRequest;
  final Map<String, Future<String?>> _pendingSelectedProxyRequestsByGroup = {};
  Future<Map<String, dynamic>>? _pendingProxiesRequest;
  bool _isDaemonCheckActive = false;
  bool _isDaemonCheckInFlight = false;
  DateTime? _deferNonCriticalStatusQueriesUntil;

  // Cache proxies to avoid first-time lag
  Map<String, dynamic>? _cachedProxies;
  DateTime? _cachedProxiesAt;

  // ignore: unused_field
  int _suppressedNativeConnectionLogCount = 0;
  StreamSubscription<dynamic>? _nativeLogsSubscription;
  final ListQueue<String> _recentNativeLogs = ListQueue<String>();
  final StreamController<bool> _runningStateController =
      StreamController<bool>.broadcast();
  final StreamController<IosVpnStartupPhase> _iosVpnStartupPhaseController =
      StreamController<IosVpnStartupPhase>.broadcast();
  IosVpnStartupPhase _iosVpnStartupPhase = IosVpnStartupPhase.idle;
  String? _iosVpnStartupFailure;
  String? _activeIosSessionId;

  bool get isRunning => _isRunning;
  Stream<bool> get runningStateStream => _runningStateController.stream;
  IosVpnStartupPhase get iosVpnStartupPhase => _iosVpnStartupPhase;
  String? get iosVpnStartupFailure => _iosVpnStartupFailure;
  Stream<IosVpnStartupPhase> get iosVpnStartupPhaseStream =>
      _iosVpnStartupPhaseController.stream;
  String? get lastSelectedGlobalProxy => _lastSelectedGlobalProxy;
  Map<String, dynamic>? get cachedProxies {
    if (!_isProxyCacheFresh) {
      return null;
    }
    return _cachedProxies;
  }

  Stream<dynamic>? _trafficStream;

  Stream<dynamic> get trafficStream {
    _trafficStream ??= const EventChannel(
      'com.accelerator.tg/mihomo/traffic',
    ).receiveBroadcastStream();
    return _trafficStream!;
  }

  Duration get nonCriticalStatusQueryDelay {
    final until = _deferNonCriticalStatusQueriesUntil;
    if (until == null) {
      return Duration.zero;
    }
    final remaining = until.difference(DateTime.now());
    if (remaining.isNegative || remaining == Duration.zero) {
      _deferNonCriticalStatusQueriesUntil = null;
      return Duration.zero;
    }
    return remaining;
  }

  bool get _isProxyCacheFresh {
    final cachedAt = _cachedProxiesAt;
    final cachedProxies = _cachedProxies;
    if (cachedAt == null || cachedProxies == null || cachedProxies.isEmpty) {
      return false;
    }
    return DateTime.now().difference(cachedAt) <= _proxyCacheTtl;
  }

  void _updateProxyCache(Map<String, dynamic> proxies) {
    _cachedProxies = proxies;
    _cachedProxiesAt = DateTime.now();
  }

  void _invalidateProxyCache() {
    _cachedProxies = null;
    _cachedProxiesAt = null;
  }

  bool _isStatusCacheFresh(DateTime? cachedAt) {
    if (cachedAt == null) {
      return false;
    }
    return DateTime.now().difference(cachedAt) <= _statusCacheTtl;
  }

  void _cacheRunningState(bool isRunning) {
    final changed = _isRunning != isRunning;
    _cachedIsRunning = isRunning;
    _cachedIsRunningAt = DateTime.now();
    _isRunning = isRunning;
    if (changed && !_runningStateController.isClosed) {
      _runningStateController.add(isRunning);
    }
  }

  void _cacheMode(String mode) {
    _cachedMode = mode;
    _cachedModeAt = DateTime.now();
  }

  void _cacheSelectedProxy(String groupName, String proxyName) {
    _cachedSelectedProxyByGroup[groupName] = proxyName;
    _cachedSelectedProxyAtByGroup[groupName] = DateTime.now();
  }

  void _invalidateLightweightStatusCache() {
    _cachedMode = null;
    _cachedModeAt = null;
    _cachedSelectedProxyByGroup.clear();
    _cachedSelectedProxyAtByGroup.clear();
  }

  void _deferNonCriticalStatusQueries(Duration duration) {
    final until = DateTime.now().add(duration);
    final current = _deferNonCriticalStatusQueriesUntil;
    if (current == null || until.isAfter(current)) {
      _deferNonCriticalStatusQueriesUntil = until;
    }
  }

  void _setIosVpnStartupPhase(
    IosVpnStartupPhase phase, {
    String? failure,
  }) {
    final failureChanged = _iosVpnStartupFailure != failure;
    if (_iosVpnStartupPhase == phase && !failureChanged) {
      return;
    }
    _iosVpnStartupPhase = phase;
    _iosVpnStartupFailure = failure;
    if (!_iosVpnStartupPhaseController.isClosed) {
      _iosVpnStartupPhaseController.add(phase);
    }
  }

  Future<Map<String, dynamic>?> _getIosTunnelStatus() async {
    if (!Platform.isIOS) {
      return null;
    }
    try {
      final raw = await _channel
          .invokeMethod<dynamic>('getTunnelStatus')
          .timeout(_iosTunnelStatusTimeout);
      if (raw is Map) {
        return raw.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (e) {
      AppLogger.w('MihomoService: getTunnelStatus error: $e');
    }
    return null;
  }

  String? _normalizeIosFailureMessage(String? message) {
    if (message == null) {
      return null;
    }
    var normalized = message.trim();
    if (normalized.isEmpty) {
      return null;
    }
    if (normalized.startsWith('Native Start Error: ')) {
      normalized = normalized.substring('Native Start Error: '.length).trim();
    }
    if (normalized.startsWith('Start Exception: ')) {
      normalized = normalized.substring('Start Exception: '.length).trim();
    }
    if (normalized.startsWith('Exception: ')) {
      normalized = normalized.substring('Exception: '.length).trim();
    }
    normalized = normalized
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join(' · ');
    return normalized.isEmpty ? null : normalized;
  }

  Future<String?> _resolveIosSharedFailure({
    String? expectedSessionId,
  }) async {
    final status = await _getIosTunnelStatus();
    if (status == null) {
      return null;
    }
    final updatedAtRaw = status['updatedAt'];
    final updatedAt = updatedAtRaw is num
        ? updatedAtRaw.toDouble()
        : double.tryParse(updatedAtRaw?.toString() ?? '');
    if (updatedAt == null || updatedAt <= 0) {
      return null;
    }
    final ageSeconds = DateTime.now().millisecondsSinceEpoch / 1000 - updatedAt;
    if (ageSeconds > 12) {
      return null;
    }
    final sessionId = status['sessionId']?.toString().trim() ?? '';
    if (expectedSessionId != null &&
        expectedSessionId.isNotEmpty &&
        sessionId != expectedSessionId) {
      return null;
    }
    final lastError = _normalizeIosFailureMessage(
      status['lastError']?.toString(),
    );
    if (lastError == null) {
      return null;
    }
    final state = status['status']?.toString().trim() ?? '';
    if (state == 'failed' || state == 'stopped' || state == 'starting') {
      return lastError;
    }
    return null;
  }

  Future<String?> _resolveIosStartupFailure(
    String fallback, {
    String? expectedSessionId,
  }) async {
    final sharedFailure = await _resolveIosSharedFailure(
      expectedSessionId: expectedSessionId,
    );
    return sharedFailure ?? _normalizeIosFailureMessage(fallback);
  }

  Future<bool> _waitForNativeChannelReady() async {
    if (!Platform.isIOS) {
      return true;
    }
    for (var attempt = 0; attempt < _nativeChannelReadyAttempts; attempt++) {
      try {
        final ready = await (_channel.invokeMethod<bool>('isReady'))
                .timeout(_nativeChannelReadyCallTimeout) ??
            true;
        if (ready) {
          return true;
        }
      } catch (_) {}
      if (attempt + 1 < _nativeChannelReadyAttempts) {
        await Future.delayed(_nativeChannelRetryDelay);
      }
    }
    return false;
  }

  Future<void> waitForNonCriticalStatusQueryWindow() async {
    final delay = nonCriticalStatusQueryDelay;
    if (delay <= Duration.zero) {
      return;
    }
    await Future.delayed(delay);
  }

  Future<void> init() async {
    _listenToNativeLogs();
    if (kIsWeb ||
        !(Platform.isAndroid || Platform.isWindows || Platform.isIOS)) {
      return;
    }
    final directory = await _getWorkingDir();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    await _ensureGeoDatabase(directory);
  }

  /// Listen to native logs
  void _listenToNativeLogs() {
    if (kIsWeb ||
        !(Platform.isAndroid || Platform.isWindows) ||
        _nativeLogsSubscription != null) {
      return;
    }
    _nativeLogsSubscription =
        const EventChannel(
          'com.accelerator.tg/mihomo/logs',
        ).receiveBroadcastStream().listen(
          (event) {
            final message = (event ?? '').toString();
            _rememberNativeLog(message);
            if (!_verboseNativeLogs && _isNoisyConnectionLog(message)) {
              _suppressedNativeConnectionLogCount++;
              if (_suppressedNativeConnectionLogCount % 50 == 0) {
                AppLogger.d(
                  "NATIVE_LOG: suppressed=$_suppressedNativeConnectionLogCount",
                );
              }
              return;
            }
            AppLogger.d("NATIVE_LOG: $message");
          },
          onError: (error) {
            AppLogger.e("NATIVE_LOG_ERROR: $error");
          },
        );
    AppLogger.d("MihomoService: native log stream attached");
  }

  void _rememberNativeLog(String message) {
    final normalized = message.trim();
    if (normalized.isEmpty) {
      return;
    }
    _recentNativeLogs.addLast(normalized);
    while (_recentNativeLogs.length > _maxRecentNativeLogs) {
      _recentNativeLogs.removeFirst();
    }
  }

  Future<String> getRecentNativeLogs({int maxLines = 30}) async {
    final effectiveMaxLines = maxLines <= 0 ? 30 : maxLines;
    var lines = _recentNativeLogs.toList(growable: false);
    if (!kIsWeb && Platform.isWindows) {
      try {
        final snapshot =
            await _channel.invokeMethod<String>('getRecentNativeLogs') ?? '';
        final nativeLines = const LineSplitter()
            .convert(snapshot)
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .toList(growable: false);
        if (nativeLines.isNotEmpty) {
          lines = nativeLines;
        }
      } catch (e) {
        AppLogger.w("MihomoService: getRecentNativeLogs error: $e");
      }
    }
    if (lines.isEmpty) {
      return '';
    }
    final start = lines.length > effectiveMaxLines
        ? lines.length - effectiveMaxLines
        : 0;
    return lines.sublist(start).join('\n');
  }

  Future<String> buildNativeLogDetails({
    String title = '最近 Mihomo 日志',
    int maxLines = 30,
  }) async {
    final logs = await getRecentNativeLogs(maxLines: maxLines);
    if (logs.isEmpty) {
      return '';
    }
    return '$title：\n$logs';
  }

  bool _isNoisyConnectionLog(String message) {
    final lower = message.toLowerCase();
    // Common noisy patterns in Clash kernel logs
    if (lower.contains(" match ") && lower.contains(" using ")) return true;
    if (lower.contains("dns query")) return true;
    if (lower.contains("connection from")) return true;
    if (lower.contains("dial")) return true;
    if (lower.contains("connect")) return true;
    if (lower.contains("inbound")) return true;
    if (lower.contains("outbound")) return true;
    if (lower.contains("tcp")) return true;
    if (lower.contains("udp")) return true;
    return false;
  }

  Future<Directory> _getWorkingDir() async {
    final cached = _workingDir;
    if (cached != null) {
      return cached;
    }
    if (Platform.isIOS) {
      final channelReady = await _waitForNativeChannelReady();
      if (!channelReady) {
        throw StateError('iOS native channel not ready');
      }
      final path = await _channel
          .invokeMethod<String>('getWorkingDirectory')
          .timeout(_iosWorkingDirectoryTimeout);
      if (path == null || path.isEmpty) {
        throw StateError('iOS shared working directory unavailable');
      }
      final resolved = Directory(path);
      _workingDir = resolved;
      return resolved;
    }
    if (Platform.isWindows) {
      final resolved = await _resolveWindowsWorkingDir();
      _workingDir = resolved;
      return resolved;
    }
    final resolved = await getApplicationSupportDirectory();
    _workingDir = resolved;
    return resolved;
  }

  Future<Directory> _resolveWindowsWorkingDir() async {
    final List<Directory> candidates = [];

    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.trim().isNotEmpty) {
      candidates.add(
        Directory('$localAppData\\com.accelerator.tg\\mihomo_runtime'),
      );
    }

    candidates.add(
      Directory(
        '${Directory.systemTemp.path}\\com.accelerator.tg\\mihomo_runtime',
      ),
    );

    candidates.add(
      Directory(
        '${File(Platform.resolvedExecutable).parent.path}\\mihomo_runtime',
      ),
    );

    for (final candidate in candidates) {
      if (await _canUseWorkingDir(candidate)) {
        return candidate;
      }
    }

    final fallback = candidates.first;
    await fallback.create(recursive: true);
    return fallback;
  }

  Future<bool> _canUseWorkingDir(Directory directory) async {
    try {
      await directory.create(recursive: true);
      final probe = File('${directory.path}\\.__probe__');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String> _saveConfig(String content) async {
    final directory = await _getWorkingDir();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    await _ensureGeoDatabase(directory);
    final file = File('${directory.path}/config.yaml');
    if (await file.exists()) {
      final existing = await file.readAsString();
      if (existing == content) {
        return file.path;
      }
    }
    await file.writeAsString(content);
    return file.path;
  }

  String _prepareConfigForCurrentPlatform(String content) {
    if (!kIsWeb && Platform.isIOS) {
      return _injectIosTunConfig(content);
    }
    return content;
  }

  String _injectIosTunConfig(String content) {
    final useCrlf = content.contains('\r\n');
    final normalized = content.replaceAll('\r\n', '\n');
    final lines = normalized.split('\n');

    bool isTopLevelKeyLine(String line) {
      if (line.isEmpty) {
        return false;
      }
      if (line.startsWith(' ') || line.startsWith('\t')) {
        return false;
      }
      final trimmed = line.trim();
      if (trimmed.startsWith('-') || trimmed.startsWith('#')) {
        return false;
      }
      return RegExp(r'^[A-Za-z0-9_-]+:\s*').hasMatch(trimmed);
    }

    String leadingWhitespace(String line) {
      final match = RegExp(r'^[ \t]*').firstMatch(line);
      return match?.group(0) ?? '';
    }

    var tunIndex = -1;
    for (var i = 0; i < lines.length; i++) {
      final rawLine = lines[i];
      final line = rawLine.startsWith('\u{FEFF}')
          ? rawLine.substring(1)
          : rawLine;
      if (line.trim() == 'tun:' &&
          !line.startsWith(' ') &&
          !line.startsWith('\t')) {
        tunIndex = i;
        break;
      }
    }

    String finish(String value) {
      return useCrlf ? value.replaceAll('\n', '\r\n') : value;
    }

    if (tunIndex == -1) {
      final suffix = normalized.isEmpty || normalized.endsWith('\n')
          ? ''
          : '\n';
      return finish(
        '$normalized${suffix}tun:\n'
        '  enable: true\n'
        '  stack: system\n'
        '  auto-route: false\n'
        '  auto-detect-interface: false\n'
        '  dns-hijack: []\n',
      );
    }

    var blockEnd = lines.length;
    for (var i = tunIndex + 1; i < lines.length; i++) {
      if (isTopLevelKeyLine(lines[i])) {
        blockEnd = i;
        break;
      }
    }

    var indent = '  ';
    for (var i = tunIndex + 1; i < blockEnd; i++) {
      final trimmed = lines[i].trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        continue;
      }
      final candidate = leadingWhitespace(lines[i]);
      if (candidate.isNotEmpty) {
        indent = candidate;
        break;
      }
    }

    final forcedLineBuilders = <String, String Function()>{
      'enable': () => '${indent}enable: true',
      'stack': () => '${indent}stack: system',
    };
    final defaultOnlyIfMissingLineBuilders = <String, String Function()>{
      'auto-route': () => '${indent}auto-route: false',
      'auto-detect-interface': () => '${indent}auto-detect-interface: false',
      'dns-hijack': () => '${indent}dns-hijack: []',
    };
    final foundKeys = <String>{};
    for (var i = tunIndex + 1; i < blockEnd; i++) {
      final trimmed = lines[i].trim();
      for (final entry in forcedLineBuilders.entries) {
        if (trimmed.startsWith('${entry.key}:')) {
          lines[i] = entry.value();
          foundKeys.add(entry.key);
          break;
        }
      }
      for (final entry in defaultOnlyIfMissingLineBuilders.entries) {
        if (trimmed.startsWith('${entry.key}:')) {
          foundKeys.add(entry.key);
          break;
        }
      }
    }

    var insertAt = tunIndex + 1;
    while (insertAt < blockEnd) {
      final trimmed = lines[insertAt].trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        insertAt++;
        continue;
      }
      break;
    }

    final pendingLines = <String>[];
    for (final entry in forcedLineBuilders.entries) {
      if (!foundKeys.contains(entry.key)) pendingLines.add(entry.value());
    }
    for (final entry in defaultOnlyIfMissingLineBuilders.entries) {
      if (!foundKeys.contains(entry.key)) pendingLines.add(entry.value());
    }
    if (pendingLines.isNotEmpty) {
      lines.insertAll(insertAt, pendingLines);
    }

    return finish(lines.join('\n'));
  }

  Future<void> _ensureGeoDatabase(Directory directory) async {
    if (kIsWeb ||
        !(Platform.isAndroid || Platform.isWindows || Platform.isIOS)) {
      return;
    }
    final mmdbFile = File('${directory.path}/Country.mmdb');
    if (await mmdbFile.exists()) {
      final length = await mmdbFile.length();
      if (length > 0) {
        return;
      }
    }
    try {
      final byteData = await HotUpdateService().loadRuntimeAsset(
        'assets/Country.mmdb',
      );
      final bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      await mmdbFile.writeAsBytes(bytes, flush: true);
      AppLogger.d('MihomoService: Country.mmdb prepared at ${mmdbFile.path}');
    } catch (e) {
      AppLogger.w('MihomoService: prepare Country.mmdb failed: $e');
    }
  }

  Future<void> _updateConfigFileMode(String mode) async {
    try {
      final directory = await _getWorkingDir();
      final configFile = File('${directory.path}/config.yaml');
      if (await configFile.exists()) {
        final originalContent = await configFile.readAsString();
        String nextContent = originalContent;
        if (nextContent.contains(RegExp(r'^mode:', multiLine: true))) {
          nextContent = nextContent.replaceAll(
            RegExp(r'^mode:.*$', multiLine: true),
            'mode: $mode',
          );
        } else {
          nextContent = 'mode: $mode\n$nextContent';
        }
        if (nextContent == originalContent) {
          return;
        }
        await configFile.writeAsString(nextContent);
        AppLogger.d("MihomoService: Config file updated for persistence.");
      }
    } catch (e) {
      AppLogger.e("Error updating config file: $e");
    }
  }

  Future<bool> persistMode(String mode) async {
    try {
      await _updateConfigFileMode(mode);
      final storedMode = await readStoredMode();
      if (storedMode == mode) {
        _cacheMode(mode);
        return true;
      }
      AppLogger.w(
        "MihomoService: persistMode verification failed. expected=$mode actual=$storedMode",
      );
      return false;
    } catch (e) {
      AppLogger.e("MihomoService: persistMode error: $e");
      return false;
    }
  }

  Future<String?> readStoredMode() async {
    try {
      final directory = await _getWorkingDir();
      final configFile = File('${directory.path}/config.yaml');
      if (!await configFile.exists()) {
        return null;
      }
      final content = await configFile.readAsString();
      final mode = _extractModeFromConfig(content);
      if (mode != null && mode.isNotEmpty) {
        _cacheMode(mode);
      }
      return mode;
    } catch (e) {
      AppLogger.e("MihomoService: readStoredMode error: $e");
      return null;
    }
  }

  Future<String?> start({required String subscribeUrl}) async {
    try {
      final normalizedUrl = _normalizeSubscribeUrl(subscribeUrl);
      if (normalizedUrl == null) {
        return "Invalid subscribe url";
      }
      AppLogger.d("MihomoService: Starting with URL: $normalizedUrl");
      _lastSubscribeUrl = normalizedUrl;

      // Download config using ApiService.sharedClient to ensure consistent SSL policy
      final response = await ApiService.sharedClient
          .get(Uri.parse(normalizedUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return "Config download failed: ${response.statusCode}";
      }

      var configContent = utf8.decode(response.bodyBytes);
      final trimmed = configContent.trimLeft();
      if (trimmed.startsWith('{') || trimmed.startsWith('<')) {
        return "Config payload is invalid";
      }
      if (!configContent.contains('proxies:') &&
          !configContent.contains('proxy-groups:')) {
        return "Config format invalid";
      }
      configContent = _prepareConfigForCurrentPlatform(configContent);

      final configPath = await _saveConfig(configContent);

      final error = await _startNative(configPath, configContent);
      if (error != null) {
        await _showStartErrorDialog(error);
      }
      return error;
    } catch (e) {
      AppLogger.e("MihomoService: Start error: $e");
      final error = e.toString();
      await _showStartErrorDialog(error);
      return error;
    }
  }

  String? _normalizeSubscribeUrl(String raw) {
    var url = raw.trim().replaceAll('`', '');
    while (url.endsWith(',') || url.endsWith('，') || url.endsWith(';')) {
      url = url.substring(0, url.length - 1).trimRight();
    }
    if (url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri.toString();
  }

  Future<String?> _startNative(
    String configPath,
    String configContent, {
    bool restartDaemonCheck = true,
  }) async {
    try {
      AppLogger.d("MihomoService: Invoking native start.");
      if (Platform.isIOS) {
        _activeIosSessionId = null;
      }
      final dynamic startResult = Platform.isIOS
          ? await _channel.invokeMethod('start', {
              'configPath': configPath,
              'configContent': configContent,
            }).timeout(_iosStartInvokeTimeout)
          : await _channel.invokeMethod('start', {
              'configPath': configPath,
              'configContent': configContent,
            });
      if (Platform.isIOS && startResult is Map) {
        final sessionId = startResult['sessionId']?.toString().trim();
        if (sessionId != null && sessionId.isNotEmpty) {
          _activeIosSessionId = sessionId;
        }
      }
      if (Platform.isWindows) {
        final proxyEnsured = await ensureSystemProxyEnabled();
        AppLogger.d(
          "MihomoService: Windows proxy verification after start=$proxyEnsured",
        );
      }

      _restartCount = 0;
      if (Platform.isIOS) {
        _cacheRunningState(false);
      } else {
        _cacheRunningState(true);
      }
      await _restoreRoutingFromConfig(configContent);
      final restoredMode = _extractModeFromConfig(configContent);
      if (restoredMode != null) {
        _cacheMode(restoredMode);
      }
      final restoredSelection = _extractPrimarySelection(configContent);
      final restoredProxyName = restoredSelection?['name'];
      if (restoredProxyName != null && restoredProxyName.isNotEmpty) {
        _lastSelectedGlobalProxy = restoredProxyName;
        _cacheSelectedProxy('GLOBAL', restoredProxyName);
      }
      _invalidateProxyCache();
      if (restartDaemonCheck) {
        _startDaemonCheck();
      }
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!_isRunning) {
          return;
        }
        unawaited(getProxies(forceRefresh: true));
      });

      return null;
    } on PlatformException catch (e) {
      _isRunning = false;
      _cachedIsRunning = null;
      _cachedIsRunningAt = null;
      final message = "Native Start Error: ${e.message}";
      if (Platform.isIOS) {
        return _resolveIosStartupFailure(
          message,
          expectedSessionId: _activeIosSessionId,
        );
      }
      if (!kIsWeb && Platform.isWindows) {
        final details = await buildNativeLogDetails(maxLines: 20);
        if (details.isNotEmpty) {
          return '$message\n\n$details';
        }
      }
      return message;
    } catch (e) {
      _isRunning = false;
      _cachedIsRunning = null;
      _cachedIsRunningAt = null;
      final message = "Start Exception: $e";
      if (Platform.isIOS) {
        return _resolveIosStartupFailure(
          message,
          expectedSessionId: _activeIosSessionId,
        );
      }
      if (!kIsWeb && Platform.isWindows) {
        final details = await buildNativeLogDetails(maxLines: 20);
        if (details.isNotEmpty) {
          return '$message\n\n$details';
        }
      }
      return message;
    }
  }

  Future<void> _showStartErrorDialog(String message) async {
    AppLogger.e("MihomoService: start failed: $message");
  }

  Future<bool> ensureIosStarted({
    String? subscribeUrl,
    bool isRetry = false,
  }) async {
    if (!Platform.isIOS) {
      return false;
    }
    final rawUrl =
        subscribeUrl?.trim().isNotEmpty == true
        ? subscribeUrl!.trim()
        : _lastSubscribeUrl ??
              ApiService().userInfo?['subscribe_url']?.toString();
    final normalizedUrl = rawUrl == null ? null : _normalizeSubscribeUrl(rawUrl);
    if (normalizedUrl == null) {
      _setIosVpnStartupPhase(
        IosVpnStartupPhase.failed,
        failure: 'subscribe url missing',
      );
      return false;
    }

    _lastSubscribeUrl = normalizedUrl;
    _activeIosSessionId = null;
    _setIosVpnStartupPhase(
      isRetry ? IosVpnStartupPhase.retrying : IosVpnStartupPhase.authorizing,
    );

    try {
      await init();
      final running = await checkIsRunning(forceRefresh: true);
      if (running) {
        final ready = await waitUntilReady(timeout: const Duration(seconds: 2));
        if (ready) {
          final status = await _getIosTunnelStatus();
          final sessionId = status?['sessionId']?.toString().trim();
          if (sessionId != null && sessionId.isNotEmpty) {
            _activeIosSessionId = sessionId;
          }
          _setIosVpnStartupPhase(IosVpnStartupPhase.idle);
          return true;
        }
        await stop();
        await Future.delayed(const Duration(milliseconds: 300));
      }

      final startError = await start(subscribeUrl: normalizedUrl);
      if (startError != null) {
        _setIosVpnStartupPhase(
          IosVpnStartupPhase.failed,
          failure: await _resolveIosStartupFailure(
            startError,
            expectedSessionId: _activeIosSessionId,
          ),
        );
        return false;
      }

      for (int i = 0; i < 10; i++) {
        final ready = await waitUntilReady(
          timeout: const Duration(milliseconds: 900),
        );
        if (ready) {
          _setIosVpnStartupPhase(IosVpnStartupPhase.idle);
          return true;
        }
        final sharedFailure = await _resolveIosSharedFailure(
          expectedSessionId: _activeIosSessionId,
        );
        if (sharedFailure != null) {
          _setIosVpnStartupPhase(
            IosVpnStartupPhase.failed,
            failure: sharedFailure,
          );
          return false;
        }
        await Future.delayed(const Duration(milliseconds: 250));
      }

      _setIosVpnStartupPhase(
        IosVpnStartupPhase.failed,
        failure: await _resolveIosStartupFailure(
          'startup probe timeout',
          expectedSessionId: _activeIosSessionId,
        ),
      );
      return false;
    } catch (e) {
      _setIosVpnStartupPhase(
        IosVpnStartupPhase.failed,
        failure: _normalizeIosFailureMessage(e.toString()),
      );
      return false;
    }
  }

  Future<void> _restoreRoutingFromConfig(String configContent) async {
    final mode = _extractModeFromConfig(configContent);
    if (mode != null) {
      try {
        await _channel.invokeMethod('changeMode', {'mode': mode});
      } catch (e) {
        AppLogger.w("MihomoService: restore mode failed: $e");
      }
    }

    final selection = _extractPrimarySelection(configContent);
    if (selection != null) {
      try {
        await _channel.invokeMethod('selectProxyByGroup', selection);
      } catch (e) {
        AppLogger.w("MihomoService: restore group selection failed: $e");
      }
    }
  }

  String? _extractModeFromConfig(String configContent) {
    final match = RegExp(
      r'^mode:\s*([A-Za-z]+)\s*$',
      multiLine: true,
    ).firstMatch(configContent);
    if (match == null) return null;
    final mode = (match.group(1) ?? '').trim().toLowerCase();
    if (mode == 'rule' || mode == 'global' || mode == 'direct') return mode;
    return null;
  }

  Map<String, String>? _extractPrimarySelection(String configContent) {
    final lines = const LineSplitter().convert(configContent);
    var inProxyGroups = false;
    String? currentGroup;

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final trimmed = raw.trim();

      if (!inProxyGroups) {
        if (trimmed == 'proxy-groups:') {
          inProxyGroups = true;
        }
        continue;
      }

      if (trimmed.isEmpty) continue;
      if (!raw.startsWith(' ') && !raw.startsWith('\t')) break;

      if (trimmed.startsWith('- name:')) {
        currentGroup = trimmed
            .substring(7)
            .trim()
            .replaceAll('"', '')
            .replaceAll("'", '');
        continue;
      }

      if (currentGroup == null || trimmed != 'proxies:') {
        continue;
      }

      for (var j = i + 1; j < lines.length; j++) {
        final itemRaw = lines[j];
        final itemTrimmed = itemRaw.trim();
        if (itemTrimmed.isEmpty) continue;
        if (!itemRaw.startsWith('  ') && !itemRaw.startsWith('\t')) {
          break;
        }
        if (!itemTrimmed.startsWith('- ')) {
          break;
        }

        final proxyName = itemTrimmed
            .substring(2)
            .trim()
            .replaceAll('"', '')
            .replaceAll("'", '');
        if (proxyName.isNotEmpty) {
          return {'groupName': currentGroup, 'name': proxyName};
        }
      }
    }

    return null;
  }

  Future<void> stop() async {
    try {
      _daemonTimer?.cancel();
      _daemonTimer = null;
      _isDaemonCheckActive = false;
      AppPollingTaskRegistry.instance.setTaskActive('daemon_watchdog', false);
      _daemonConsecutiveFailures = 0;
      await _channel.invokeMethod('stop');
      if (Platform.isIOS) {
        _activeIosSessionId = null;
      }
      _cacheRunningState(false);
      _invalidateLightweightStatusCache();
      _invalidateProxyCache();
      AppLogger.d("MihomoService: Stopped.");
    } catch (e) {
      AppLogger.e("MihomoService: Stop error: $e");
    }
  }

  Future<bool> ensureSystemProxyEnabled() async {
    if (kIsWeb || !Platform.isWindows) {
      return true;
    }
    try {
      final dynamic result = await _channel.invokeMethod('ensureSystemProxy');
      final success = result is bool ? result : true;
      if (!success) {
        AppLogger.w("MihomoService: ensureSystemProxy returned false");
      }
      return success;
    } catch (e) {
      AppLogger.e("MihomoService: ensureSystemProxy error: $e");
      return false;
    }
  }

  Future<bool> checkIsRunning({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _isStatusCacheFresh(_cachedIsRunningAt) &&
        _cachedIsRunning != null) {
      return _cachedIsRunning!;
    }
    final pending = forceRefresh ? null : _pendingIsRunningRequest;
    if (pending != null) {
      return pending;
    }
    final future = _checkIsRunningNative();
    if (!forceRefresh) {
      _pendingIsRunningRequest = future;
    }
    try {
      return await future;
    } finally {
      if (!forceRefresh && identical(_pendingIsRunningRequest, future)) {
        _pendingIsRunningRequest = null;
      }
    }
  }

  Future<bool> _checkIsRunningNative() async {
    try {
      final bool? result = await _channel.invokeMethod('isRunning');
      final resolved = result ?? false;
      _cacheRunningState(resolved);
      return resolved;
    } catch (e) {
      _cacheRunningState(false);
      return false;
    }
  }

  Future<int?> urlTestProxy(String proxyName) async {
    try {
      final dynamic result = await _channel.invokeMethod('urlTest', {
        'name': proxyName,
      });
      if (result is int) return result;
      if (result is String) {
        if (result.isEmpty) return null;

        // Clean up string: remove 'ms', spaces, etc. to get pure number
        // Allow digits and minus sign
        final cleanResult = result.replaceAll(RegExp(r'[^0-9-]'), '');
        if (cleanResult.isEmpty) return null;

        final asInt = int.tryParse(cleanResult);
        if (asInt != null) return asInt;

        // Try to parse as JSON (if original string was JSON)
        try {
          final Map<String, dynamic> map = json.decode(result);
          if (map.containsKey('delay')) return map['delay'] as int?;
          if (map.containsKey('mean')) return map['mean'] as int?;
        } catch (_) {}
      }
      return null;
    } catch (e) {
      AppLogger.e("MihomoService: urlTest error: $e");
      return null;
    }
  }

  Future<bool> switchMode(String mode) async {
    try {
      await _channel.invokeMethod('changeMode', {'mode': mode});
      await _updateConfigFileMode(mode);
      _cacheMode(mode);
      _invalidateProxyCache();
      return true;
    } catch (e) {
      AppLogger.e("MihomoService: switchMode error: $e");
      return false;
    }
  }

  Future<bool> selectProxy(String proxyName) async {
    try {
      final dynamic ok = await _channel.invokeMethod('selectProxy', {
        'name': proxyName,
      });
      final success = ok is bool ? ok : true;
      if (success) {
        _lastSelectedGlobalProxy = proxyName;
        _cacheSelectedProxy('GLOBAL', proxyName);
        _invalidateProxyCache();
      }
      return success;
    } catch (e) {
      AppLogger.e("MihomoService: selectProxy error: $e");
      return false;
    }
  }

  Future<String> getMode({bool forceRefresh = false, Duration? timeout}) async {
    if (!forceRefresh &&
        _isStatusCacheFresh(_cachedModeAt) &&
        _cachedMode != null) {
      return _cachedMode!;
    }
    final pending = forceRefresh ? null : _pendingModeRequest;
    if (pending != null) {
      return pending;
    }
    final future = _getModeNative(timeout: timeout);
    if (!forceRefresh) {
      _pendingModeRequest = future;
    }
    try {
      return await future;
    } finally {
      if (!forceRefresh && identical(_pendingModeRequest, future)) {
        _pendingModeRequest = null;
      }
    }
  }

  Future<String?> probeMode({Duration? timeout}) async {
    try {
      final request = _channel.invokeMethod<String>('getMode');
      final mode = timeout == null
          ? await request
          : await request.timeout(timeout);
      final resolvedMode = mode?.trim();
      if (resolvedMode == null || resolvedMode.isEmpty) {
        return null;
      }
      _cacheMode(resolvedMode);
      return resolvedMode;
    } catch (e) {
      AppLogger.e("MihomoService: getMode error: $e");
      return null;
    }
  }

  Future<String> _getModeNative({Duration? timeout}) async {
    final mode = await probeMode(timeout: timeout);
    return mode ?? 'rule';
  }

  Future<bool> waitUntilReady({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final running = await checkIsRunning(forceRefresh: true);
      if (running) {
        final mode = await probeMode(timeout: _startupReadyProbeTimeout);
        if (mode != null && mode.isNotEmpty) {
          _cacheRunningState(true);
          return true;
        }
      }
      await Future.delayed(_startupReadyPollInterval);
    }
    _cachedIsRunning = null;
    _cachedIsRunningAt = null;
    return false;
  }

  Future<String?> getSelectedProxy(String groupName) async {
    final cachedSelected = _cachedSelectedProxyByGroup[groupName];
    final cachedSelectedAt = _cachedSelectedProxyAtByGroup[groupName];
    if (cachedSelected != null && _isStatusCacheFresh(cachedSelectedAt)) {
      return cachedSelected;
    }
    final pending = _pendingSelectedProxyRequestsByGroup[groupName];
    if (pending != null) {
      return pending;
    }
    final future = _getSelectedProxyNative(groupName);
    _pendingSelectedProxyRequestsByGroup[groupName] = future;
    try {
      return await future;
    } finally {
      if (identical(_pendingSelectedProxyRequestsByGroup[groupName], future)) {
        _pendingSelectedProxyRequestsByGroup.remove(groupName);
      }
    }
  }

  Future<String?> _getSelectedProxyNative(String groupName) async {
    try {
      if (Platform.isWindows) {
        final result = await _channel.invokeMethod('getSelectedProxySync', {
          'groupName': groupName,
        });
        if (result is String && result.isNotEmpty) {
          _cacheSelectedProxy(groupName, result);
          return result;
        }
      }

      final result = await _channel.invokeMethod('getSelectedProxy', {
        'groupName': groupName,
      });
      final resolved = result as String?;
      if (resolved != null && resolved.isNotEmpty) {
        _cacheSelectedProxy(groupName, resolved);
      }
      return resolved;
    } catch (e) {
      AppLogger.e("MihomoService: getSelectedProxy error: $e");
      return null;
    }
  }

  Future<Map<String, dynamic>?> getSelectedProxyInfo(String groupName) async {
    try {
      if (Platform.isAndroid) {
        final dynamic result = await _channel.invokeMethod(
          'getSelectedProxyInfo',
          {'groupName': groupName},
        );
        if (result is Map) {
          final info = result.map(
            (key, value) => MapEntry(key.toString(), value),
          );
          final name = info['name']?.toString().trim() ?? '';
          if (name.isEmpty) {
            return null;
          }
          final type = info['type']?.toString().trim();
          final country = info['country']?.toString().trim();
          final udpRaw = info['udp'];
          final udp =
              udpRaw == true || udpRaw?.toString().toLowerCase() == 'true';
          _lastSelectedGlobalProxy = name;
          _cacheSelectedProxy(groupName, name);
          return {
            'name': name,
            'type': (type == null || type.isEmpty) ? 'Unknown' : type,
            'country': (country == null || country.isEmpty)
                ? 'Unknown'
                : country,
            'udp': udp,
          };
        }
        return null;
      }
      if (Platform.isIOS) {
        final proxies = await getProxies(forceRefresh: true);
        final info = _extractSelectedProxyInfoFromPayload(proxies, groupName);
        final name = info?['name']?.toString().trim() ?? '';
        if (name.isEmpty) {
          return null;
        }
        _lastSelectedGlobalProxy = name;
        _cacheSelectedProxy(groupName, name);
        return info;
      }
      if (!Platform.isWindows) {
        return null;
      }
      final String? result = await _channel.invokeMethod(
        'getSelectedProxyInfoSync',
        {'groupName': groupName},
      );
      if (result == null || result.isEmpty) {
        return null;
      }
      final parts = result.split('|');
      if (parts.length < 4) {
        return null;
      }
      final name = parts[0].trim();
      if (name.isEmpty) {
        return null;
      }
      final type = parts[1].trim().isEmpty ? 'Unknown' : parts[1].trim();
      final country = parts[2].trim().isEmpty ? 'Unknown' : parts[2].trim();
      final udpRaw = parts[3].trim().toLowerCase();
      final udp = udpRaw == 'true' || udpRaw == '1';
      _lastSelectedGlobalProxy = name;
      _cacheSelectedProxy(groupName, name);
      return {'name': name, 'type': type, 'country': country, 'udp': udp};
    } catch (e) {
      AppLogger.e("MihomoService: getSelectedProxyInfo error: $e");
      return null;
    }
  }

  Map<String, dynamic>? _extractSelectedProxyInfoFromPayload(
    Map<String, dynamic> proxies,
    String groupName,
  ) {
    final proxyMapRaw = proxies['proxies'];
    if (proxyMapRaw is! Map) {
      return null;
    }
    final proxyMap = proxyMapRaw.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    if (proxyMap.isEmpty) {
      return null;
    }
    final groupRaw = proxies[groupName];
    if (groupRaw is! Map) {
      return null;
    }
    final group = groupRaw.map((key, value) => MapEntry(key.toString(), value));
    final selectedName = group['now']?.toString().trim() ?? '';
    if (selectedName.isEmpty) {
      return null;
    }
    final selectedRaw = proxyMap[selectedName];
    if (selectedRaw is! Map) {
      return {
        'name': selectedName,
        'type': 'Unknown',
        'country': 'Unknown',
        'udp': false,
      };
    }
    final selected = selectedRaw.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    final type = selected['type']?.toString().trim();
    final country = selected['country']?.toString().trim();
    final udpRaw = selected['udp'];
    final udp = udpRaw == true || udpRaw?.toString().toLowerCase() == 'true';
    return {
      'name': selectedName,
      'type': (type == null || type.isEmpty) ? 'Unknown' : type,
      'country': (country == null || country.isEmpty) ? 'Unknown' : country,
      'udp': udp,
    };
  }

  Future<Map<String, dynamic>> getProxies({bool forceRefresh = false}) async {
    // Return cached if available and not forced
    if (!forceRefresh && _isProxyCacheFresh) {
      return _cachedProxies!;
    }
    final pending = _pendingProxiesRequest;
    if (pending != null) {
      return pending;
    }
    final future = _getProxiesWithStartupGuard();
    _pendingProxiesRequest = future;
    try {
      return await future;
    } finally {
      if (identical(_pendingProxiesRequest, future)) {
        _pendingProxiesRequest = null;
      }
    }
  }

  Future<Map<String, dynamic>> _getProxiesWithStartupGuard() async {
    if (!Platform.isWindows) {
      return _getProxiesNative();
    }
    final deadline = DateTime.now().add(_windowsProxyRetryTimeout);
    Map<String, dynamic> lastPayload = <String, dynamic>{};
    while (true) {
      final payload = await _getProxiesNative();
      lastPayload = payload;
      if (_hasUsableWindowsProxyPayload(payload)) {
        return payload;
      }
      if (DateTime.now().isAfter(deadline)) {
        AppLogger.w(
          "MihomoService: Windows proxies still empty after retry window",
        );
        return lastPayload;
      }
      await Future.delayed(_windowsProxyRetryInterval);
    }
  }

  Future<Map<String, dynamic>> _getProxiesNative() async {
    try {
      if (Platform.isWindows) {
        final String? listStr = await _channel.invokeMethod('getProxyListStr');
        if (listStr != null && listStr.isNotEmpty) {
          AppLogger.d(
            "MihomoService: getProxyListStr payload bytes=${listStr.length}",
          );
          final parsed = await compute(_parseProxyListStr, listStr);
          _updateProxyCache(parsed);
          _syncLightweightCacheFromProxies(parsed);
          return parsed;
        }
        AppLogger.w(
          "MihomoService: getProxyListStr empty, fallback to getProxies",
        );
      }

      final dynamic result = await _channel.invokeMethod('getProxies');
      if (result is String) {
        AppLogger.d("MihomoService: getProxies string bytes=${result.length}");
        if (Platform.isWindows && result.length <= 80) {
          AppLogger.w("MihomoService: getProxies raw=$result");
        }
        final parsed = await compute(_parseProxiesPayload, result);
        _updateProxyCache(parsed);
        _syncLightweightCacheFromProxies(parsed);
        return parsed;
      } else if (result is Map) {
        final parsed = _normalizeProxiesObject(result);
        _updateProxyCache(parsed);
        _syncLightweightCacheFromProxies(parsed);
        return parsed;
      }
      return {};
    } catch (e) {
      AppLogger.e("MihomoService: getProxies error: $e");
      return {};
    }
  }

  bool _hasUsableWindowsProxyPayload(Map<String, dynamic> payload) {
    final globalRaw = payload['GLOBAL'];
    if (globalRaw is Map) {
      final all = globalRaw['all'];
      if (all is List) {
        for (final item in all) {
          final value = item.toString().trim();
          if (value.isNotEmpty && value.toUpperCase() != 'DIRECT') {
            return true;
          }
        }
      }
    }
    final proxiesRaw = payload['proxies'];
    if (proxiesRaw is Map) {
      for (final entry in proxiesRaw.entries) {
        final name = entry.key.toString().trim();
        if (name.isEmpty) continue;
        final upper = name.toUpperCase();
        if (upper == 'DIRECT' ||
            upper == 'REJECT' ||
            upper == 'REJECT-DROP' ||
            upper == 'COMPATIBLE' ||
            upper == 'PASS' ||
            upper == 'GLOBAL') {
          continue;
        }
        return true;
      }
    }
    return false;
  }

  void _syncLightweightCacheFromProxies(Map<String, dynamic> proxies) {
    final globalRaw = proxies['GLOBAL'];
    if (globalRaw is! Map) {
      return;
    }
    final now = globalRaw['now']?.toString().trim() ?? '';
    if (now.isEmpty) {
      return;
    }
    _lastSelectedGlobalProxy = now;
    _cacheSelectedProxy('GLOBAL', now);
  }

  // Helper to parse the pipe-separated string format
  static Map<String, dynamic> _parseProxyListStr(String listStr) {
    final Map<String, dynamic> proxies = {};
    // Format: name-type-adds-country-udp|...
    final items = listStr.split('|');

    // Construct a fake "proxies" map and "GLOBAL" group
    final allNames = <String>[];

    for (final item in items) {
      if (item.isEmpty) continue;

      // Split by '-' but be careful about names containing '-'
      // We know the last 4 fields are fixed: type, server, country, udp
      // So we split and take from end.
      // Actually, simple split might fail if name has dashes.
      // Let's assume the user's format implies simple structure or we find last 4 dashes.

      // Safer approach: reverse string, find first 4 dashes.
      // item: "My-Proxy-Node-Shadowsocks-1.2.3.4-Unknown-true"

      final parts = item.split('-');
      if (parts.length < 5) continue;

      final udp = parts.last == 'true';
      final country = parts[parts.length - 2];
      final server = parts[parts.length - 3];
      final type = parts[parts.length - 4];

      // Name is everything before type
      final nameParts = parts.sublist(0, parts.length - 4);
      final name = nameParts.join('-');

      allNames.add(name);

      proxies[name] = {
        'name': name,
        'type': type,
        'server': server, // Using server as "adds" (address)
        'country': country,
        'udp': udp,
        // 'country': country // Not standard field in proxies map usually, but can add
        // Add extra fields expected by UI
        'history': [],
        'now': '',
      };
    }

    return {
      'proxies': proxies,
      'GLOBAL': {
        'all': allNames,
        'type': 'Selector',
        'now': allNames.isNotEmpty ? allNames.first : '',
      },
    };
  }

  static Map<String, dynamic> _parseProxiesPayload(String payload) {
    final raw = payload.trim();
    if (raw.isEmpty) return {};
    if (raw.startsWith('{') || raw.startsWith('[')) {
      final decoded = json.decode(raw);
      return _normalizeProxiesObject(decoded);
    }
    return _parseCommaSeparatedProxyList(raw);
  }

  static Map<String, dynamic> _normalizeProxiesObject(dynamic decoded) {
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    if (decoded is List) {
      return _parseProxyArray(decoded);
    }
    return {};
  }

  static Map<String, dynamic> _parseCommaSeparatedProxyList(String listStr) {
    final proxies = <String, dynamic>{};
    final allNames = <String>[];
    for (final raw in listStr.split(',')) {
      final name = raw.trim();
      if (name.isEmpty) continue;
      proxies[name] = {'name': name, 'type': 'Unknown', 'history': []};
      final upper = name.toUpperCase();
      if (upper != 'DIRECT' &&
          upper != 'REJECT' &&
          upper != 'REJECT-DROP' &&
          upper != 'PASS' &&
          upper != 'COMPATIBLE' &&
          upper != 'GLOBAL') {
        allNames.add(name);
      }
    }
    return {
      'proxies': proxies,
      'GLOBAL': {
        'all': allNames,
        'type': 'Selector',
        'now': allNames.isNotEmpty ? allNames.first : '',
      },
    };
  }

  static Map<String, dynamic> _parseProxyArray(List<dynamic> list) {
    final proxies = <String, dynamic>{};
    String? selectorName;
    final allNames = <String>[];

    for (final item in list) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final name = (map['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final type = (map['type'] ?? '').toString();
      final countryRaw = (map['country'] ?? '').toString().trim();
      final normalized = <String, dynamic>{
        'name': name,
        'type': type,
        'server': (map['server'] ?? map['adds'] ?? '').toString(),
        'country': countryRaw.isNotEmpty
            ? countryRaw
            : _inferCountryFromName(name),
        'udp': map['udp'] == true,
        'history': map['history'] is List ? map['history'] : <dynamic>[],
      };
      proxies[name] = normalized;

      final isSelector = type.toLowerCase() == 'selector';
      if (isSelector && selectorName == null) {
        selectorName = name;
      }
      if (!isSelector) {
        final upper = name.toUpperCase();
        if (upper != 'REJECT' &&
            upper != 'REJECT-DROP' &&
            upper != 'PASS' &&
            upper != 'COMPATIBLE') {
          allNames.add(name);
        }
      }
    }

    final groupNow = allNames.isNotEmpty ? allNames.first : '';
    final globalGroup = {'all': allNames, 'type': 'Selector', 'now': groupNow};
    final result = <String, dynamic>{'proxies': proxies, 'GLOBAL': globalGroup};
    final selector = selectorName;
    if (selector != null && selector != 'GLOBAL') {
      result[selector] = globalGroup;
    }
    return result;
  }

  static String _inferCountryFromName(String name) {
    final n = name.toLowerCase();
    if (n.contains('hk') || n.contains('hong') || name.contains('香港')) {
      return 'HK';
    }
    if (n.contains('jp') || n.contains('japan') || name.contains('日本')) {
      return 'JP';
    }
    if (n.contains('sg') || n.contains('singapore') || name.contains('新加坡')) {
      return 'SG';
    }
    if (n.contains('tw') || n.contains('taiwan') || name.contains('台湾')) {
      return 'TW';
    }
    if (n.contains('kr') || n.contains('korea') || name.contains('韩国')) {
      return 'KR';
    }
    if (n.contains('us') ||
        n.contains('usa') ||
        n.contains('america') ||
        name.contains('美国')) {
      return 'US';
    }
    if (n.contains('gb') ||
        n.contains('uk') ||
        n.contains('britain') ||
        name.contains('英国')) {
      return 'GB';
    }
    if (n.contains('de') || n.contains('germany') || name.contains('德国')) {
      return 'DE';
    }
    if (n.contains('fr') || n.contains('france') || name.contains('法国')) {
      return 'FR';
    }
    if (n.contains('nl') || n.contains('netherlands') || name.contains('荷兰')) {
      return 'NL';
    }
    if (n.contains('ca') || n.contains('canada') || name.contains('加拿大')) {
      return 'CA';
    }
    if (n.contains('au') || n.contains('australia') || name.contains('澳大利亚')) {
      return 'AU';
    }
    if (n.contains('in') || n.contains('india') || name.contains('印度')) {
      return 'IN';
    }
    if (n.contains('ru') || n.contains('russia') || name.contains('俄罗斯')) {
      return 'RU';
    }
    if (n.contains('cn') || n.contains('china') || name.contains('中国')) {
      return 'CN';
    }
    return '--';
  }

  void ensureTrafficMonitor() {
    // No-op: traffic stream is initialized on access
  }

  void _startDaemonCheck() {
    _daemonTimer?.cancel();
    _isDaemonCheckActive = true;
    _restartCount = 0;
    _daemonConsecutiveFailures = 0;
    AppPollingTaskRegistry.instance.registerTask(
      id: 'daemon_watchdog',
      interval: _daemonCheckInterval,
      initialDelay: _initialDaemonCheckDelay,
      owner: 'mihomo_service',
      active: true,
    );
    _scheduleNextDaemonCheck(initial: true);
  }

  void _scheduleNextDaemonCheck({required bool initial}) {
    _daemonTimer?.cancel();
    if (!_isDaemonCheckActive) {
      AppPollingTaskRegistry.instance.setTaskActive('daemon_watchdog', false);
      return;
    }
    AppPollingTaskRegistry.instance.registerTask(
      id: 'daemon_watchdog',
      interval: _daemonCheckInterval,
      initialDelay: _initialDaemonCheckDelay,
      owner: 'mihomo_service',
      active: true,
    );
    final delay = initial ? _initialDaemonCheckDelay : _daemonCheckInterval;
    _daemonTimer = Timer(delay, () async {
      await _runDaemonCheckTick();
      if (_isDaemonCheckActive) {
        _scheduleNextDaemonCheck(initial: false);
      }
    });
  }

  Future<void> _runDaemonCheckTick() async {
    if (!_isDaemonCheckActive || _isDaemonCheckInFlight) {
      return;
    }
    _isDaemonCheckInFlight = true;
    try {
      AppPollingTaskRegistry.instance.markTaskExecuted('daemon_watchdog');
      if (Platform.isWindows) {
        _deferNonCriticalStatusQueries(_windowsStatusQueryCooldown);
      }
      final running = await checkIsRunning();
      if (!running) {
        _daemonConsecutiveFailures++;
        AppLogger.w(
          "MihomoService: Daemon check failed ($_daemonConsecutiveFailures/3).",
        );

        if (_daemonConsecutiveFailures >= 3) {
          _cacheRunningState(false);
          _restartCount++;
          AppLogger.e(
            "MihomoService: Daemon check failed 3 times. Marking as not running. Restart count: $_restartCount",
          );

          if (_restartCount <= 3) {
            AppLogger.i("MihomoService: Attempting auto-restart...");
            if (_lastSubscribeUrl != null) {
              try {
                final directory = await _getWorkingDir();
                final file = File('${directory.path}/config.yaml');
                if (await file.exists()) {
                  final configContent = await file.readAsString();
                  await _startNative(
                    file.path,
                    configContent,
                    restartDaemonCheck: false,
                  );
                  _daemonConsecutiveFailures = 0;
                } else {
                  AppLogger.e(
                    "MihomoService: Config file not found for restart.",
                  );
                }
              } catch (e) {
                AppLogger.e("MihomoService: Restart error $e");
              }
            }
          } else {
            AppLogger.e("MihomoService: Restart failed 3 times. Exiting app.");
            _isDaemonCheckActive = false;
            _cacheRunningState(false);
          }
        } else {
          _cacheRunningState(false);
        }
      } else {
        _cacheRunningState(true);
        _restartCount = 0;
        _daemonConsecutiveFailures = 0;
      }
    } finally {
      _isDaemonCheckInFlight = false;
    }
  }
}
