import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:android_id/android_id.dart';
import 'package:app/core/constants.dart';
import 'package:app/core/logger.dart';
import 'package:app/core/certificates.dart';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart'; // Import IOClient
import 'package:pointycastle/export.dart' as pc;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:app/views/widgets/custom_dialog.dart';

// =============================================================================
// Top-level Crypto Workers (Run in Isolate)
// =============================================================================

// HONEYPOT: Fake crypto logic to mislead reverse engineers
class _CryptoParamsHoneypot {
  final String aesKey;
  final String obfuscateKey;
  final dynamic data;
  _CryptoParamsHoneypot(this.aesKey, this.obfuscateKey, this.data);
}

// ignore: unused_element
Uint8List _isolatedEncryptHoneypot(_CryptoParamsHoneypot params) {
  final str = json.encode(params.data);
  final bytes = utf8.encode(str);

  // Use fake keys
  final fakeAesKey = ApiService._aesKye;
  final fakeObfKey = ApiService._obfuscateKye;

  final kBytes = utf8.encode(fakeAesKey);
  final oBytes = utf8.encode(fakeObfKey);

  final out = Uint8List(bytes.length);
  for (int i = 0; i < bytes.length; i++) {
    out[i] = bytes[i] ^ kBytes[i % kBytes.length] ^ oBytes[i % oBytes.length];
  }
  return out;
}

// ignore: unused_element
Map<String, dynamic>? _isolatedDecryptHoneypot(_CryptoParamsHoneypot params) {
  final data = params.data as Uint8List;
  final fakeAesKey = ApiService._aesKye;
  final fakeObfKey = ApiService._obfuscateKye;

  final kBytes = utf8.encode(fakeAesKey);
  final oBytes = utf8.encode(fakeObfKey);

  final out = Uint8List(data.length);
  for (int i = 0; i < data.length; i++) {
    out[i] = data[i] ^ oBytes[i % oBytes.length] ^ kBytes[i % kBytes.length];
  }

  try {
    return json.decode(utf8.decode(out));
  } catch (_) {
    return {"status": "error", "msg": "honeypot decrypt failed"};
  }
}

class _CryptoParams {
  final String aesKey;
  final String obfuscateKey;
  final dynamic data; // Map<String, dynamic> for encrypt, Uint8List for decrypt

  _CryptoParams(this.aesKey, this.obfuscateKey, this.data);
}

Uint8List _isolatedEncrypt(_CryptoParams params) {
  try {
    final jsonStr = json.encode(params.data);
    final plainBytes = utf8.encode(jsonStr);

    // AES Key
    final keyBytes = _hexToBytes(params.aesKey);

    // Generate 12-byte Nonce (IV)
    final ivBytes = List<int>.generate(12, (i) => Random.secure().nextInt(256));
    final iv = Uint8List.fromList(ivBytes);

    // PointyCastle GCM Encryption
    final cipher = pc.GCMBlockCipher(pc.AESEngine());
    final aeadParams = pc.AEADParameters(
      pc.KeyParameter(Uint8List.fromList(keyBytes)),
      128, // Mac Bit Size (16 bytes)
      iv,
      Uint8List(0), // Associated Data
    );

    cipher.init(true, aeadParams); // true = encrypt

    final out = Uint8List(cipher.getOutputSize(plainBytes.length));
    var len = cipher.processBytes(plainBytes, 0, plainBytes.length, out, 0);
    len += cipher.doFinal(out, len);

    final cipherBytesWithTag = out.sublist(0, len);

    final combined = Uint8List.fromList([...iv, ...cipherBytesWithTag]);

    // Obfuscate
    return _obfuscate(combined, params.obfuscateKey);
  } catch (e) {
    throw Exception("Encryption Error: $e");
  }
}

Map<String, dynamic>? _isolatedDecrypt(_CryptoParams params) {
  try {
    final obfuscatedData = params.data as Uint8List;
    final encryptedData = _deobfuscate(obfuscatedData, params.obfuscateKey);

    // Minimum length: Nonce(12) + Tag(16) = 28 bytes
    if (encryptedData.length < 28) {
      return null;
    }

    // 1. Extract Nonce (first 12 bytes)
    final nonceBytes = encryptedData.sublist(0, 12);
    final iv = nonceBytes;

    // 2. Extract Ciphertext + Tag (remaining bytes)
    final ciphertextWithTagBytes = encryptedData.sublist(12);

    // PointyCastle Decryption
    final keyBytes = _hexToBytes(params.aesKey);
    final cipher = pc.GCMBlockCipher(pc.AESEngine());
    final aeadParams = pc.AEADParameters(
      pc.KeyParameter(Uint8List.fromList(keyBytes)),
      128,
      iv,
      Uint8List(0),
    );

    cipher.init(false, aeadParams); // false = decrypt

    final out = Uint8List(cipher.getOutputSize(ciphertextWithTagBytes.length));
    var len = cipher.processBytes(
      ciphertextWithTagBytes,
      0,
      ciphertextWithTagBytes.length,
      out,
      0,
    );
    len += cipher.doFinal(out, len);

    final decryptedBytes = out.sublist(0, len);
    final decryptedStr = utf8.decode(decryptedBytes);

    final decoded = json.decode(decryptedStr);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (e) {
    // In isolate, just return null or rethrow
    return null;
  }
}

// Helpers must be top-level for Isolate access
String _toHex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}

List<int> _hexToBytes(String hex) {
  hex = hex.replaceAll(" ", "");

  // App V2 接口文档规定 AES 密钥必须是 32 字节 (64个十六进制字符)
  if (hex.length > 64) {
    hex = hex.substring(0, 64);
  } else if (hex.length < 64) {
    hex = hex.padRight(64, '0');
  }

  List<int> bytes = [];
  for (int i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return bytes;
}

Uint8List _obfuscate(Uint8List data, String key) {
  final keyBytes = utf8.encode(key);
  final keyLen = keyBytes.length;
  final result = Uint8List.fromList(data);

  // 1. Rolling XOR
  for (int i = 0; i < result.length; i++) {
    result[i] = result[i] ^ keyBytes[i % keyLen];
  }

  // 2. Reverse
  return Uint8List.fromList(result.reversed.toList());
}

Uint8List _deobfuscate(Uint8List data, String key) {
  // 1. Reverse
  final reversed = Uint8List.fromList(data.reversed.toList());
  final keyBytes = utf8.encode(key);
  final keyLen = keyBytes.length;

  // 2. Rolling XOR
  for (int i = 0; i < reversed.length; i++) {
    reversed[i] = reversed[i] ^ keyBytes[i % keyLen];
  }
  return reversed;
}

// =============================================================================
// Data Models
// =============================================================================

class OrderCreateResult {
  final int code;
  final String msg;
  final String? orderNo;

  const OrderCreateResult({
    required this.code,
    required this.msg,
    this.orderNo,
  });

  bool get isSuccess => code == 200 && orderNo != null && orderNo!.isNotEmpty;
}

class PaymentMethod {
  final int id;
  final String name;

  const PaymentMethod({required this.id, required this.name});
}

class PayListResult {
  final int code;
  final String msg;
  final List<PaymentMethod> methods;

  const PayListResult({
    required this.code,
    required this.msg,
    required this.methods,
  });

  bool get isSuccess => code == 200;
}

class OrderCheckoutResult {
  final int code;
  final String msg;
  final String? payUrl;
  final int needClientQrcode;

  const OrderCheckoutResult({
    required this.code,
    required this.msg,
    this.payUrl,
    this.needClientQrcode = 1,
  });

  bool get isSuccess => code == 200 && payUrl != null && payUrl!.isNotEmpty;
}

class OrderStatusResult {
  final int code;
  final String msg;
  final int? status;

  const OrderStatusResult({required this.code, required this.msg, this.status});

  bool get isSuccess => code == 200 && status != null;
}

class GiftCardSubmitResult {
  final int code;
  final String msg;

  const GiftCardSubmitResult({required this.code, required this.msg});

  bool get isSuccess => code == 200;
}

class InviteInfo {
  final String platform;
  final String androidDownloadUrl;
  final String iosDownloadUrl;
  final String windowsDownloadUrl;
  final String giftCode;
  final int inviteCount;
  final String content;

  const InviteInfo({
    required this.platform,
    required this.androidDownloadUrl,
    required this.iosDownloadUrl,
    required this.windowsDownloadUrl,
    required this.giftCode,
    required this.inviteCount,
    required this.content,
  });
}

class InviteInfoResult {
  final int code;
  final String msg;
  final InviteInfo? data;

  const InviteInfoResult({required this.code, required this.msg, this.data});

  bool get isSuccess => code == 200 && data != null;
}

class DeviceBindApplyInfo {
  final String bindToken;
  final String bindUrl;
  final String expireTime;

  const DeviceBindApplyInfo({
    required this.bindToken,
    required this.bindUrl,
    required this.expireTime,
  });
}

class DeviceBindApplyResult {
  final int code;
  final String msg;
  final DeviceBindApplyInfo? data;

  const DeviceBindApplyResult({
    required this.code,
    required this.msg,
    this.data,
  });

  bool get isSuccess => code == 200 && data != null;
}

class DeviceBindScanInfo {
  final int? userId;
  final int? bindUserId;

  const DeviceBindScanInfo({this.userId, this.bindUserId});
}

class DeviceBindScanResult {
  final int code;
  final String msg;
  final DeviceBindScanInfo? data;

  const DeviceBindScanResult({
    required this.code,
    required this.msg,
    this.data,
  });

  bool get isSuccess => code == 200;
}

class AgentKeyRedeemResult {
  final int code;
  final String msg;
  final String? packageName;
  final int? trafficQuota;
  final int? validDays;
  final String? usedTime;

  const AgentKeyRedeemResult({
    required this.code,
    required this.msg,
    this.packageName,
    this.trafficQuota,
    this.validDays,
    this.usedTime,
  });

  bool get isSuccess => code == 200;
}

class TicketStatusInfo {
  final String status;
  final bool isActive;
  final bool isClosed;
  final int queueAhead;
  final int waitingUser;
  final TicketMessage? latestAdminMessage;

  const TicketStatusInfo({
    required this.status,
    required this.isActive,
    required this.isClosed,
    required this.queueAhead,
    required this.waitingUser,
    this.latestAdminMessage,
  });
}

class TicketMessage {
  final int? seq;
  final String sender;
  final String content;
  final String createTime;

  const TicketMessage({
    this.seq,
    required this.sender,
    required this.content,
    required this.createTime,
  });
}

class TicketStatusResult {
  final int code;
  final String msg;
  final TicketStatusInfo? data;

  const TicketStatusResult({required this.code, required this.msg, this.data});

  bool get isSuccess => code == 200 && data != null;
}

class TicketMessagesResult {
  final int code;
  final String msg;
  final TicketStatusInfo? status;
  final List<TicketMessage> messages;

  const TicketMessagesResult({
    required this.code,
    required this.msg,
    this.status,
    required this.messages,
  });

  bool get isSuccess => code == 200;
}

class TicketSendResult {
  final int code;
  final String msg;

  const TicketSendResult({required this.code, required this.msg});

  bool get isSuccess => code == 200;
}

class TicketCloseResult {
  final int code;
  final String msg;

  const TicketCloseResult({required this.code, required this.msg});

  bool get isSuccess => code == 200;
}

class AppUpdateCheckResult {
  final bool needUpdate;
  final String env;
  final int latestVersion;
  final String msg;
  final File? zipFile;

  const AppUpdateCheckResult({
    required this.needUpdate,
    required this.env,
    required this.latestVersion,
    required this.msg,
    this.zipFile,
  });
}

// =============================================================================
// ApiService
// =============================================================================

class ApiService {
  // Singleton pattern
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  // ===========================================================================
  // 1. 服务端地址配置 (XOR 混淆存储)
  // ===========================================================================
  // 所有服务端地址均只从 Native 层注入，Flutter 层禁止内置或回退。

  static String get _aesKye {
    final parts = [
      'A1B2',
      'C3D4',
      'E5F6',
      '7890',
      '1234',
      '5678',
      '90AB',
      'CDEF',
    ];
    return parts.reversed.toList().reversed.join('');
  }

  static String get _obfuscateKye {
    final p1 = String.fromCharCodes([
      77,
      49,
      78,
      50,
      66,
      51,
      86,
      52,
    ]); // M1N2B3V4
    final p2 = String.fromCharCodes([
      67,
      53,
      88,
      54,
      90,
      55,
      65,
      56,
    ]); // C5X6Z7A8
    final p3 = String.fromCharCodes([
      83,
      57,
      68,
      48,
      70,
      49,
      71,
      50,
    ]); // S9D0F1G2
    final p4 = String.fromCharCodes([
      72,
      51,
      74,
      52,
      75,
      53,
      76,
      54,
    ]); // H3J4K5L6
    return "$p1$p2$p3$p4";
  }

  // Dynamic keys loaded from Native
  String _dynamicServerUrlKey = "";
  String _dynamicAesKey = "";
  String _dynamicObfuscateKey = "";
  bool _keysLoaded = false;

  static const MethodChannel _mihomoChannel = MethodChannel(
    'com.accelerator.tg/mihomo',
  );
  static const int _nativeChannelReadyAttempts = 10;
  static const Duration _nativeChannelRetryDelay = Duration(milliseconds: 200);
  static const Duration _nativeChannelReadyCallTimeout = Duration(
    milliseconds: 800,
  );
  static const int _nativeKeyFetchAttempts = 8;
  static const Duration _nativeKeyFetchRetryDelay = Duration(
    milliseconds: 250,
  );

  Future<bool> _waitForNativeChannelReady() async {
    if (!Platform.isIOS) {
      return true;
    }
    for (var attempt = 0; attempt < _nativeChannelReadyAttempts; attempt++) {
      try {
        final ready = await (_mihomoChannel.invokeMethod<bool>('isReady'))
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

  Future<void> initNativeKeys({bool forceRefresh = false}) async {
    if (_keysLoaded && !forceRefresh) return;

    try {
      WidgetsFlutterBinding.ensureInitialized();
      final channelReady = await _waitForNativeChannelReady();
      if (!channelReady) {
        _log("DEBUG: Native channel not ready");
        return;
      }

      final attempts = Platform.isIOS ? _nativeKeyFetchAttempts : 1;
      for (var attempt = 0; attempt < attempts; attempt++) {
        try {
          final aes = (await _mihomoChannel.invokeMethod<String>('getAesKey'))
              ?.trim();
          final obf =
              (await _mihomoChannel.invokeMethod<String>('getObfuscateKey'))
                  ?.trim();
          final url =
              (await _mihomoChannel.invokeMethod<String>('getServerUrlKey'))
                  ?.trim();
          final loaded =
              aes != null &&
              aes.isNotEmpty &&
              obf != null &&
              obf.isNotEmpty &&
              url != null &&
              _isValidServerUrl(url);
          if (loaded) {
            _dynamicAesKey = aes;
            _dynamicObfuscateKey = obf;
            _dynamicServerUrlKey = url;
            _keysLoaded = true;
            _log("DEBUG: Native keys loaded successfully.");
            return;
          }
        } catch (e) {
          _log("DEBUG: Native key fetch attempt failed. Error: $e");
        }
        if (attempt + 1 < attempts) {
          await Future.delayed(_nativeKeyFetchRetryDelay);
        }
      }
      _keysLoaded = false;
      _log("DEBUG: Native keys not ready yet.");
    } catch (e) {
      _keysLoaded = false;
      _log("DEBUG: Failed to load native keys. Error: $e");
    }
  }

  bool _isValidServerUrl(String value) {
    if (!value.startsWith('http')) {
      return false;
    }
    final uri = Uri.tryParse(value);
    return uri != null && uri.hasScheme && uri.host.isNotEmpty;
  }

  Future<bool> ensureNativeServerUrlReady() async {
    if (!Platform.isIOS) {
      return true;
    }
    await initNativeKeys(forceRefresh: true);
    final url = _dynamicServerUrlKey.trim();
    return url.isNotEmpty && _isValidServerUrl(url);
  }

  Future<Uri?> resolveStartupProbeUri() async {
    await initNativeKeys();
    final raw = _dynamicServerUrlKey.trim();
    if (raw.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return null;
    }
    return uri;
  }

  String get _baseUrl {
    if (_dynamicServerUrlKey.isEmpty) {
      throw StateError('Native server url is empty');
    }

    if (_dynamicServerUrlKey.startsWith("http")) {
      return _dynamicServerUrlKey;
    }
    throw StateError('Native server url is invalid');
  }

  // ===========================================================================
  // 2. 加密通信配置
  // ===========================================================================
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  // Reusable HTTP Client for Keep-Alive
  static final http.Client _client = _createHttpClient();
  static http.Client get sharedClient => _client;
  static const Duration _defaultTimeout = Duration(seconds: 10);
  static const Duration _windowsUserInfoPersistInterval = Duration(seconds: 25);

  static http.Client _createHttpClient() {
    try {
      // 默认使用系统的证书库信任 (信任系统根证书)
      final SecurityContext context = SecurityContext.defaultContext;

      // 内置服务端完整证书链以兼容老旧 Windows 系统
      try {
        context.setTrustedCertificatesBytes(utf8.encode(fullChainPem));
      } catch (e) {
        // 如果添加失败（例如证书已存在），则忽略
      }

      final HttpClient httpClient = HttpClient(context: context);

      // 允许服务端证书通信，如果证书无效则拒绝
      // 此处不进行额外的域名白名单限制，完全依赖系统证书库的校验结果
      httpClient.badCertificateCallback =
          (X509Certificate cert, String host, int port) {
            return false; // 拒绝无效证书
          };

      return IOClient(httpClient);
    } catch (e) {
      AppLogger.e("HttpClient init failed: $e");
    }
    return http.Client();
  }

  // 内存中存储的用户信息
  Map<String, dynamic>? _userInfo;
  String? _token;
  bool _isHandlingUserInfoSessionInvalid = false;
  Timer? _windowsUserInfoPersistTimer;
  String? _pendingWindowsUserInfoCache;

  Map<String, dynamic>? get userInfo => _userInfo;
  String? get token => _token;

  bool get isDpidInvalid {
    final dpidRaw = _userInfo?['dpid'];
    final dpid = dpidRaw is int
        ? dpidRaw
        : int.tryParse(dpidRaw?.toString() ?? '');
    return dpid == -1;
  }

  // ===========================================================================
  // 3. 核心业务方法
  // ===========================================================================

  // Debug info storage (Disabled in Release Mode)
  static String _lastDebugInfo = "";
  static String get lastDebugInfo => kReleaseMode ? "" : _lastDebugInfo;

  Map<String, dynamic> _sanitizeUserInfoForCache(Map<String, dynamic> data) {
    final sanitized = Map<String, dynamic>.from(data);
    sanitized.remove('token');
    sanitized.remove('access_token');
    sanitized.remove('refresh_token');
    sanitized.remove('authorization');
    return sanitized;
  }

  Future<void> _persistUserInfoCacheIfChanged(
    SharedPreferences prefs,
    Map<String, dynamic>? data, {
    bool allowDeferredOnWindows = false,
    bool persistLargeFields = true,
  }) async {
    if (data == null) {
      return;
    }
    final sanitized = _sanitizeUserInfoForCache(data);
    final cachePayload = Map<String, dynamic>.from(sanitized);
    if (!persistLargeFields) {
      cachePayload.remove('expired_traffic_logs');
    }
    _userInfo = sanitized;
    final encoded = json.encode(cachePayload);
    if (allowDeferredOnWindows && Platform.isWindows) {
      if (prefs.getString('user_info') == encoded &&
          _pendingWindowsUserInfoCache == null) {
        return;
      }
      _pendingWindowsUserInfoCache = encoded;
      _scheduleWindowsUserInfoPersist(prefs);
      return;
    }
    _windowsUserInfoPersistTimer?.cancel();
    _windowsUserInfoPersistTimer = null;
    _pendingWindowsUserInfoCache = null;
    if (prefs.getString('user_info') == encoded) {
      return;
    }
    await prefs.setString('user_info', encoded);
  }

  void _scheduleWindowsUserInfoPersist(SharedPreferences prefs) {
    if (!Platform.isWindows || _windowsUserInfoPersistTimer != null) {
      return;
    }
    _windowsUserInfoPersistTimer = Timer(
      _windowsUserInfoPersistInterval,
      () async {
        final pending = _pendingWindowsUserInfoCache;
        _pendingWindowsUserInfoCache = null;
        _windowsUserInfoPersistTimer = null;
        if (pending == null || prefs.getString('user_info') == pending) {
          return;
        }
        await prefs.setString('user_info', pending);
      },
    );
  }

  Future<String?> _readLocalAuthToken(SharedPreferences prefs) async {
    if (Platform.isWindows) {
      return prefs.getString('auth_token');
    }
    try {
      final token = await _secureStorage.read(key: 'auth_token');
      if (token != null && token.isNotEmpty) {
        return token;
      }
    } catch (e) {
      _log("DEBUG: Secure storage read failed: $e");
    }
    return prefs.getString('auth_token');
  }

  Future<void> _writeLocalAuthToken(
    SharedPreferences prefs,
    String token,
  ) async {
    if (Platform.isWindows) {
      await prefs.setString('auth_token', token);
      return;
    }
    try {
      await _secureStorage.write(key: 'auth_token', value: token);
      await prefs.remove('auth_token');
    } catch (e) {
      _log("DEBUG: Secure storage write failed: $e");
      await prefs.setString('auth_token', token);
    }
  }

  Future<void> _deleteLocalAuthToken(SharedPreferences prefs) async {
    if (!Platform.isWindows) {
      try {
        await _secureStorage.delete(key: 'auth_token');
      } catch (e) {
        _log("DEBUG: Secure storage delete failed: $e");
      }
    }
    await prefs.remove('auth_token');
  }

  Future<void> _clearLocalAuth() async {
    _token = null;
    _userInfo = null;
    _windowsUserInfoPersistTimer?.cancel();
    _windowsUserInfoPersistTimer = null;
    _pendingWindowsUserInfoCache = null;
    final prefs = await SharedPreferences.getInstance();
    await _deleteLocalAuthToken(prefs);
    await prefs.remove('user_info');
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

  Future<void> exitApplication() async {
    await _flushPendingWindowsUserInfoCache();
    await _exitApp();
  }

  Future<void> flushPendingUserInfoCache() async {
    await _flushPendingWindowsUserInfoCache();
  }

  Future<void> _flushPendingWindowsUserInfoCache() async {
    final pending = _pendingWindowsUserInfoCache;
    if (!Platform.isWindows || pending == null) {
      return;
    }
    _windowsUserInfoPersistTimer?.cancel();
    _windowsUserInfoPersistTimer = null;
    _pendingWindowsUserInfoCache = null;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString('user_info') == pending) {
      return;
    }
    await prefs.setString('user_info', pending);
  }

  Future<void> _handleUserInfoSessionInvalid() async {
    if (_isHandlingUserInfoSessionInvalid) {
      return;
    }
    _isHandlingUserInfoSessionInvalid = true;
    await _clearLocalAuth();
    final navigatorState = appNavigatorKey.currentState;
    final overlayState = navigatorState?.overlay;
    if (navigatorState == null ||
        !navigatorState.mounted ||
        overlayState == null ||
        !overlayState.mounted) {
      if (Platform.isWindows) {
        return;
      }
      await _exitApp();
      return;
    }
    await showAnimatedDialog<void>(
      context: overlayState.context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF96CBFF), width: 1.1),
          ),
          title: const Text(
            '提示',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: const Text(
            '登录环境发生变化，请退出APP后重新打开',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              height: 1.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await _exitApp();
              },
              child: const Text(
                '确认',
                style: TextStyle(
                  color: Color(0xFF96CBFF),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ===========================================================================
  // HONEYPOT: Fake State & Methods
  // ===========================================================================
  final bool _isEmulator = false;

  // ignore: unused_element
  Future<void> _checkAppIntegrity() async {
  }

  // ignore: unused_element
  bool _verifySignature(String sign) {
    if (sign.isEmpty) return false;
    final expected = utf8.encode(_obfuscateKye);
    final actual = utf8.encode(sign);
    if (expected.length != actual.length) return false;
    int res = 0;
    for (int i = 0; i < expected.length; i++) {
      res |= expected[i] ^ actual[i];
    }
    return res == 0 && !_isEmulator;
  }
  // ===========================================================================

  /// 检查是否存在有效的本地 Token
  /// Returns: true if token exists and userInfo loaded, false otherwise
  Future<bool> checkLocalToken() async {
    await initNativeKeys();

    try {
      final prefs = await SharedPreferences.getInstance();

      final token = await _readLocalAuthToken(prefs);

      final userInfoStr = prefs.getString('user_info');

      if (token != null && token.isNotEmpty && userInfoStr != null) {
        _token = token;
        final decoded = json.decode(userInfoStr);
        if (decoded is Map<String, dynamic>) {
          await _persistUserInfoCacheIfChanged(prefs, decoded);
        } else if (decoded is Map) {
          await _persistUserInfoCacheIfChanged(
            prefs,
            Map<String, dynamic>.from(decoded),
          );
        } else {
          _userInfo = null;
        }
        _log("DEBUG: Local token found. User loaded.");
        return true;
      }
    } catch (e) {
      _log("DEBUG: Error checking local token: $e");
    }
    return false;
  }

  /// 设备登录/初始化
  /// Returns: null if success, error message string if failed
  Future<String?> login() async {
    await initNativeKeys();
    _lastDebugInfo = ""; // Reset debug info
    try {
      final deviceId = await _getDeviceId();
      final urlStr = "$_baseUrl/app/v2/login";
      _log("DEBUG: Login URL: $urlStr");

      final url = Uri.parse(urlStr);
      final requestData = {"device_id": deviceId};

      // 1. 加密 + 混淆 (Isolate)
      final encryptedBody = await compute(
        _isolatedEncrypt,
        _CryptoParams(_aesKey, _obfuscateKey, requestData),
      );
      _log("DEBUG: Encrypted Body Length: ${encryptedBody.length}");

      // 2. 发送请求
      _log("DEBUG: Sending request...");
      final response = await _client
          .post(
            url,
            headers: {"Content-Type": "application/octet-stream"},
            body: encryptedBody,
          )
          .timeout(_defaultTimeout);

      _log("DEBUG: Response Status Code: ${response.statusCode}");

      if (response.statusCode != 200) {
        _log("DEBUG: Request failed with status: ${response.statusCode}");
        return "HTTP Error: ${response.statusCode}\n$_lastDebugInfo";
      }

      // 3. 去混淆 + 解密 (Isolate)
      final responseJson = await compute(
        _isolatedDecrypt,
        _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes),
      );

      if (responseJson == null) {
        _log("DEBUG: Failed to decrypt response");
        final hex = _toHex(response.bodyBytes);
        final snippet = hex.length > 20 ? hex.substring(0, 20) : hex;
        return "Decryption Failed (Body: $snippet...)\n$_lastDebugInfo";
      }

      _log("DEBUG: Decrypted Response JSON: $responseJson");

      // 4. 处理业务逻辑
      final code = responseJson['code'];
      if (code == 200) {
        final data = responseJson['data'];
        final normalizedData = data is Map<String, dynamic>
            ? data
            : data is Map
            ? Map<String, dynamic>.from(data)
            : <String, dynamic>{};
        _userInfo = _sanitizeUserInfoForCache(normalizedData);
        _token = normalizedData['token']?.toString();

        // 持久化 Token
        final prefs = await SharedPreferences.getInstance();
        if (_token != null) {
          await _writeLocalAuthToken(prefs, _token!);
          await _persistUserInfoCacheIfChanged(prefs, _userInfo);
        }

        _log("DEBUG: Login Success: User ID ${data['id']}");
        return null; // Success
      } else {
        final msg = responseJson['msg'] ?? "Unknown Error";
        _log("DEBUG: Login Failed: $msg");
        return "API Error: $msg\n$_lastDebugInfo";
      }
    } catch (e) {
      _log("DEBUG: Login Error Exception: $e");
      return "Exception: $e\n$_lastDebugInfo";
    }
  }

  Future<AppUpdateCheckResult> checkAppUpdate({
    required String env,
    required String version,
    required File downloadFile,
    void Function(int received, int? total)? onDownloadProgress,
  }) async {
    await initNativeKeys();
    final url = Uri.parse("$_baseUrl/app/v2/update/check");
    final requestData = {
      "env": env,
      "version": int.tryParse(version) ?? version,
    };
    final encryptedBody = await compute(
      _isolatedEncrypt,
      _CryptoParams(_aesKey, _obfuscateKey, requestData),
    );
    final request = http.Request('POST', url);
    request.headers["Content-Type"] = "application/octet-stream";
    request.bodyBytes = encryptedBody;
    final response = await _client.send(request).timeout(_defaultTimeout);
    if (response.statusCode != 200) {
      throw Exception("HTTP Error: ${response.statusCode}");
    }
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    final contentDisposition =
        response.headers['content-disposition']?.toLowerCase() ?? '';
    final responseEnv = response.headers['x-app-update-env'] ?? env;
    final responseVersion =
        int.tryParse(response.headers['x-app-update-version'] ?? '') ??
        int.tryParse(version) ??
        0;
    await downloadFile.parent.create(recursive: true);
    if (downloadFile.existsSync()) {
      await downloadFile.delete();
    }
    final sink = downloadFile.openWrite();
    var received = 0;
    final total = response.contentLength;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onDownloadProgress?.call(received, total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    final fileHeader = await _readFileHeader(downloadFile);
    if (_looksLikeZipPayload(
      contentType: contentType,
      contentDisposition: contentDisposition,
      headerBytes: fileHeader,
    )) {
      return AppUpdateCheckResult(
        needUpdate: true,
        env: responseEnv,
        latestVersion: responseVersion,
        msg: '需要更新',
        zipFile: downloadFile,
      );
    }
    final responseBytes = await downloadFile.readAsBytes();
    await downloadFile.delete();
    final responseJson = await _decodeUpdateResponse(responseBytes);
    if (responseJson == null) {
      final preview = _responsePreview(responseBytes);
      if (preview.isNotEmpty) {
        throw Exception('更新响应解析失败: $preview');
      }
      throw Exception('更新响应解析失败');
    }
    final code = responseJson['code'];
    final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
    if (code != 200) {
      throw Exception(msg);
    }
    final data = responseJson['data'];
    final normalizedData = data is Map<String, dynamic>
        ? data
        : data is Map
        ? Map<String, dynamic>.from(data)
        : responseJson;
    return AppUpdateCheckResult(
      needUpdate: _toBool(normalizedData['need_update']),
      env: normalizedData['env']?.toString() ?? env,
      latestVersion:
          int.tryParse(normalizedData['latest_version']?.toString() ?? '') ??
          responseVersion,
      msg: msg,
    );
  }

  Future<Map<String, dynamic>?> _decodeUpdateResponse(
    Uint8List responseBytes,
  ) async {
    final decryptedJson = await compute(
      _isolatedDecrypt,
      _CryptoParams(_aesKey, _obfuscateKey, responseBytes),
    );
    if (decryptedJson != null) {
      return decryptedJson;
    }
    try {
      final plainText = utf8.decode(responseBytes).trim();
      if (plainText.isEmpty) {
        return null;
      }
      final decoded = json.decode(plainText);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  Future<Uint8List> _readFileHeader(File file, {int length = 4}) async {
    final stream = file.openRead(0, length);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
      if (builder.length >= length) {
        break;
      }
    }
    return builder.takeBytes();
  }

  bool _looksLikeZipPayload({
    required String contentType,
    required String contentDisposition,
    required Uint8List headerBytes,
  }) {
    if (contentType.contains('application/zip') ||
        contentType.contains('application/x-zip-compressed') ||
        contentDisposition.contains('.zip')) {
      return true;
    }
    if (headerBytes.length < 2) {
      return false;
    }
    return headerBytes[0] == 0x50 && headerBytes[1] == 0x4B;
  }

  bool _toBool(dynamic value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    final normalized = value?.toString().trim().toLowerCase();
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }

  String _responsePreview(Uint8List bytes) {
    try {
      final preview = utf8.decode(bytes, allowMalformed: true).trim();
      if (preview.isEmpty) {
        return '';
      }
      return preview.length > 120 ? preview.substring(0, 120) : preview;
    } catch (_) {
      return '';
    }
  }

  void _log(String msg) {
    if (kReleaseMode) return;
    AppLogger.d(msg);
    _lastDebugInfo += "$msg\n";
  }

  String get _aesKey {
    return _dynamicAesKey;
  }

  String get _obfuscateKey {
    return _dynamicObfuscateKey;
  }

  // ===========================================================================
  // 4. 辅助方法 (设备ID)
  // ===========================================================================

  Future<String> _getDeviceId() async {
    String? deviceId;
    final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

    try {
      if (Platform.isAndroid) {
        const androidIdPlugin = AndroidId();
        deviceId = await androidIdPlugin.getId();
      } else if (Platform.isWindows) {
        final windowsInfo = await deviceInfo.windowsInfo;
        deviceId = windowsInfo.deviceId;
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        deviceId = iosInfo.identifierForVendor;
      }
    } catch (e) {
      _log("DEBUG: Error getting platform specific device info: $e");
    }

    if (deviceId == null || deviceId.isEmpty) {
      if (Platform.isIOS) {
        try {
          deviceId = await _secureStorage.read(key: 'ios_device_uuid');
        } catch (e) {
          _log("DEBUG: Secure storage iOS device id read failed: $e");
        }
      }
    }

    if (deviceId == null || deviceId.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      deviceId = prefs.getString('device_uuid');
      if (deviceId == null) {
        deviceId = const Uuid().v4();
        await prefs.setString('device_uuid', deviceId);
      }
    }

    if (Platform.isIOS && deviceId.isNotEmpty) {
      try {
        await _secureStorage.write(key: 'ios_device_uuid', value: deviceId);
      } catch (e) {
        _log("DEBUG: Secure storage iOS device id write failed: $e");
      }
    }

    final bytes = utf8.encode(deviceId);
    final digest = md5.convert(bytes);
    return digest.toString();
  }

  /// 获取用户实时信息 (流量/过期时间)
  Future<String?> fetchUserInfo() async {
    try {
      if (_token == null) {
        return "Token is missing";
      }

      final urlStr = "$_baseUrl/app/v2/user/info";
      final url = Uri.parse(urlStr);

      // 2. 发送请求
      _log("DEBUG: Sending request...");
      final response = await _client
          .get(
            url,
            headers: {
              "Content-Type": "application/octet-stream",
              "Authorization": "Bearer $_token",
            },
          )
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        if (response.statusCode == 404) {
          _log("DEBUG: User info not found (404), maybe token expired.");
        }
        return "HTTP Error: ${response.statusCode}";
      }

      // 解密响应 (Isolate)
      final responseJson = await compute(
        _isolatedDecrypt,
        _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes),
      );
      if (responseJson == null) {
        return "Decryption Failed";
      }

      final code = responseJson['code'];
      if (code == 200) {
        final data = responseJson['data'];
        final normalizedData = data is Map<String, dynamic>
            ? data
            : data is Map
            ? Map<String, dynamic>.from(data)
            : <String, dynamic>{};

        if (_userInfo == null) {
          _userInfo = Map<String, dynamic>.from(normalizedData);
        } else {
          _userInfo!['quota'] = normalizedData['quota'];
          _userInfo!['expire_time'] = normalizedData['expire_time'];
          _userInfo!['expired_traffic_logs'] =
              normalizedData['expired_traffic_logs'];
          _userInfo!['ads'] = normalizedData['ads'];
        }

        final prefs = await SharedPreferences.getInstance();
        await _persistUserInfoCacheIfChanged(
          prefs,
          _userInfo,
          allowDeferredOnWindows: true,
          persistLargeFields: false,
        );

        return null; // Success
      } else {
        await _handleUserInfoSessionInvalid();
        return "API Error: ${responseJson['msg']}";
      }
    } catch (e) {
      _log("DEBUG: FetchUserInfo Error: $e");
      return "Exception: $e";
    }
  }

  Future<OrderCreateResult> createOrder({required String item}) async {
    try {
      if (_token == null) {
        return const OrderCreateResult(code: -1, msg: 'Token is missing');
      }

      final urlStr = "$_baseUrl/app/v2/order/save";
      final url = Uri.parse(urlStr);

      // Isolate Encrypt
      final encryptedBody = await compute(
        _isolatedEncrypt,
        _CryptoParams(_aesKey, _obfuscateKey, {"item": item}),
      );

      final response = await _client
          .post(
            url,
            headers: {
              "Content-Type": "application/octet-stream",
              "Authorization": "Bearer $_token",
            },
            body: encryptedBody,
          )
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        return OrderCreateResult(
          code: response.statusCode,
          msg: "HTTP Error: ${response.statusCode}",
        );
      }

      // Isolate Decrypt
      final responseJson = await compute(
        _isolatedDecrypt,
        _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes),
      );
      if (responseJson == null) {
        return const OrderCreateResult(code: -2, msg: 'Decryption Failed');
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final data = responseJson['data'];
      final orderNo = data?.toString();

      return OrderCreateResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
        orderNo: orderNo,
      );
    } catch (e) {
      _log("DEBUG: CreateOrder Error: $e");
      return OrderCreateResult(code: -4, msg: "Exception: $e");
    }
  }

  Future<PayListResult> fetchPayList() async {
    try {
      if (_token == null) {
        return const PayListResult(
          code: -1,
          msg: 'Token is missing',
          methods: [],
        );
      }

      final urlStr = "$_baseUrl/app/v2/pay/list";
      final url = Uri.parse(urlStr);
      final response = await _client
          .get(
            url,
            headers: {
              "Content-Type": "application/octet-stream",
              "Authorization": "Bearer $_token",
            },
          )
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        return PayListResult(
          code: response.statusCode,
          msg: "HTTP Error: ${response.statusCode}",
          methods: const [],
        );
      }

      // Isolate Decrypt
      final responseJson = await compute(
        _isolatedDecrypt,
        _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes),
      );
      if (responseJson == null) {
        return const PayListResult(
          code: -2,
          msg: 'Decryption Failed',
          methods: [],
        );
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final data = responseJson['data'];
      final methods = <PaymentMethod>[];
      if (data is List) {
        for (final item in data) {
          if (item is Map) {
            final idRaw = item['id'];
            final nameRaw = item['name'];
            final id = idRaw is int
                ? idRaw
                : int.tryParse(idRaw?.toString() ?? '');
            final name = nameRaw?.toString() ?? '';
            if (id != null && name.isNotEmpty) {
              methods.add(PaymentMethod(id: id, name: name));
            }
          }
        }
      }

      return PayListResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
        methods: methods,
      );
    } catch (e) {
      _log("DEBUG: FetchPayList Error: $e");
      return PayListResult(code: -4, msg: "Exception: $e", methods: const []);
    }
  }

  Future<OrderCheckoutResult> checkoutOrder({
    required String method,
    required String tradeNo,
    required String type,
  }) async {
    try {
      if (_token == null) {
        return const OrderCheckoutResult(code: -1, msg: 'Token is missing');
      }

      final urlStr = "$_baseUrl/app/v2/order/checkout";
      final url = Uri.parse(urlStr);

      // Isolate Encrypt
      final encryptedBody = await compute(
        _isolatedEncrypt,
        _CryptoParams(_aesKey, _obfuscateKey, {
          "method": method,
          "trade_no": tradeNo,
          "type": type,
        }),
      );

      // FIX: Use _client which has the configured SecurityContext/badCertificateCallback
      // Do NOT use http.post directly as it uses a default client with strict SSL checks
      final response = await _client.post(
        url,
        headers: {
          "Content-Type": "application/octet-stream",
          "Authorization": "Bearer $_token",
        },
        body: encryptedBody,
      );

      if (response.statusCode != 200) {
        return OrderCheckoutResult(
          code: response.statusCode,
          msg: "HTTP Error: ${response.statusCode}",
        );
      }

      // Isolate Decrypt
      final responseJson = await compute(
        _isolatedDecrypt,
        _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes),
      );
      if (responseJson == null) {
        return const OrderCheckoutResult(code: -2, msg: 'Decryption Failed');
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final data = responseJson['data'];
      String? payUrl;
      int needClientQrcode = 1;
      if (data is Map) {
        final payUrlRaw = data['pay_url'];
        payUrl = payUrlRaw?.toString();
        final needClientQrcodeRaw = data['need_client_qrcode'];
        if (needClientQrcodeRaw is int) {
          needClientQrcode = needClientQrcodeRaw;
        } else {
          needClientQrcode =
              int.tryParse(needClientQrcodeRaw?.toString() ?? '') ?? 1;
        }
      } else {
        payUrl = data?.toString();
      }

      return OrderCheckoutResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
        payUrl: payUrl,
        needClientQrcode: needClientQrcode,
      );
    } catch (e) {
      _log("DEBUG: CheckoutOrder Error: $e");
      return OrderCheckoutResult(code: -4, msg: "Exception: $e");
    }
  }

  Future<OrderStatusResult> queryOrderStatus({required String tradeNo}) async {
    try {
      if (_token == null) {
        return const OrderStatusResult(code: -1, msg: 'Token is missing');
      }

      final url = Uri.parse(
        "$_baseUrl/app/v2/order/detail",
      ).replace(queryParameters: {"trade_no": tradeNo});

      // FIX: Use _client here as well
      final response = await _client.get(
        url,
        headers: {
          "Content-Type": "application/octet-stream",
          "Authorization": "Bearer $_token",
        },
      );

      if (response.statusCode != 200) {
        return OrderStatusResult(
          code: response.statusCode,
          msg: "HTTP Error: ${response.statusCode}",
        );
      }

      // Isolate Decrypt
      final responseJson = await compute(
        _isolatedDecrypt,
        _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes),
      );
      if (responseJson == null) {
        return const OrderStatusResult(code: -2, msg: 'Decryption Failed');
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final data = responseJson['data'];
      int? status;
      if (data is Map) {
        final statusRaw = data['status'];
        status = statusRaw is int
            ? statusRaw
            : int.tryParse(statusRaw?.toString() ?? '');
      }

      return OrderStatusResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
        status: status,
      );
    } catch (e) {
      _log("DEBUG: QueryOrderStatus Error: $e");
      return OrderStatusResult(code: -4, msg: "Exception: $e");
    }
  }

  Future<GiftCardSubmitResult> submitGiftCard({required String invite}) async {
    try {
      if (_token == null) {
        return const GiftCardSubmitResult(code: -1, msg: 'Token is missing');
      }

      final urlStr = "$_baseUrl/app/v2/user/invite";
      final url = Uri.parse(urlStr);

      // Isolate Encrypt
      final encryptedBody = await compute(
        _isolatedEncrypt,
        _CryptoParams(_aesKey, _obfuscateKey, {"invite": invite}),
      );

      final response = await _client
          .post(
            url,
            headers: {
              "Content-Type": "application/octet-stream",
              "Authorization": "Bearer $_token",
            },
            body: encryptedBody,
          )
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        return GiftCardSubmitResult(
          code: response.statusCode,
          msg: "HTTP Error: ${response.statusCode}",
        );
      }

      // Isolate Decrypt
      final responseJson = await compute(
        _isolatedDecrypt,
        _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes),
      );
      if (responseJson == null) {
        return const GiftCardSubmitResult(code: -2, msg: 'Decryption Failed');
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final result = GiftCardSubmitResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
      );

      if (result.isSuccess && _userInfo != null) {
        _userInfo!['dpid'] = 0;
        final prefs = await SharedPreferences.getInstance();
        await _persistUserInfoCacheIfChanged(prefs, _userInfo);
      }

      return result;
    } catch (e) {
      _log("DEBUG: SubmitGiftCard Error: $e");
      return GiftCardSubmitResult(code: -4, msg: "Exception: $e");
    }
  }

  Future<InviteInfoResult> fetchInviteInfo({required String platform}) async {
    try {
      if (_token == null) {
        return const InviteInfoResult(code: -1, msg: 'Token is missing');
      }

      final url = Uri.parse("$_baseUrl/app/v2/user/invite/info");
      final encryptedBody = await compute(
        _isolatedEncrypt,
        _CryptoParams(_aesKey, _obfuscateKey, {"platform": platform}),
      );

      final response = await _client
          .post(
            url,
            headers: {
              "Content-Type": "application/octet-stream",
              "Authorization": "Bearer $_token",
            },
            body: encryptedBody,
          )
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        return InviteInfoResult(
          code: response.statusCode,
          msg: "HTTP Error: ${response.statusCode}",
        );
      }

      final responseJson = await compute(
        _isolatedDecrypt,
        _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes),
      );
      if (responseJson == null) {
        return const InviteInfoResult(code: -2, msg: 'Decryption Failed');
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final data = responseJson['data'];
      if (data is! Map) {
        return InviteInfoResult(
          code: code is int ? code : int.tryParse(code.toString()) ?? -3,
          msg: msg,
        );
      }

      final normalizedData = Map<String, dynamic>.from(data);
      final inviteCountRaw = normalizedData['invite_count'];
      final content = normalizedData['content']?.toString() ?? '';
      final androidDownloadUrl =
          _pickInviteValue(normalizedData, const [
            'android_download_url',
            'androidDownloadUrl',
            'android_down',
            'android_url',
          ]) ??
          _extractInviteDownloadUrl(content, const ['android', '安卓']);
      final iosDownloadUrl =
          _pickInviteValue(normalizedData, const [
            'ios_download_url',
            'iosDownloadUrl',
            'ios_down',
            'ios_url',
          ]) ??
          _extractInviteDownloadUrl(content, const ['ios', '苹果']);
      final windowsDownloadUrl =
          _pickInviteValue(normalizedData, const [
            'windows_download_url',
            'windowsDownloadUrl',
            'windows_down',
            'win_down',
            'windows_url',
            'win_url',
          ]) ??
          _extractInviteDownloadUrl(content, const ['windows', 'win', '电脑']);

      return InviteInfoResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
        data: InviteInfo(
          platform: normalizedData['platform']?.toString() ?? platform,
          androidDownloadUrl: androidDownloadUrl,
          iosDownloadUrl: iosDownloadUrl,
          windowsDownloadUrl: windowsDownloadUrl,
          giftCode: normalizedData['gift_code']?.toString() ?? '',
          inviteCount: inviteCountRaw is int
              ? inviteCountRaw
              : inviteCountRaw is num
              ? inviteCountRaw.toInt()
              : int.tryParse(inviteCountRaw?.toString() ?? '') ?? 0,
          content: content,
        ),
      );
    } catch (e) {
      _log("DEBUG: FetchInviteInfo Error: $e");
      return InviteInfoResult(code: -4, msg: "Exception: $e");
    }
  }

  String? _pickInviteValue(
    Map<String, dynamic> data,
    List<String> candidateKeys,
  ) {
    for (final key in candidateKeys) {
      final value = data[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  String _extractInviteDownloadUrl(String content, List<String> labels) {
    final normalizedContent = content.trim();
    if (normalizedContent.isEmpty) {
      return '';
    }
    for (final label in labels) {
      final escapedLabel = RegExp.escape(label);
      final match = RegExp(
        '(?:^|\\n)\\s*$escapedLabel(?:下载地址)?\\s*[：:]\\s*(\\S+)',
        caseSensitive: false,
        multiLine: true,
      ).firstMatch(normalizedContent);
      if (match != null) {
        final value = match.group(1)?.trim() ?? '';
        if (value.isNotEmpty) {
          return value;
        }
      }
    }
    return '';
  }

  Future<DeviceBindApplyResult> applyDeviceBind() async {
    try {
      if (_token == null) {
        return const DeviceBindApplyResult(code: -1, msg: 'Token is missing');
      }

      final url = Uri.parse("$_baseUrl/app/v2/user/device-bind/apply");
      final encryptedBody = await compute(
        _isolatedEncrypt,
        _CryptoParams(_aesKey, _obfuscateKey, <String, dynamic>{}),
      );

      final response = await _client
          .post(
            url,
            headers: {
              "Content-Type": "application/octet-stream",
              "Authorization": "Bearer $_token",
            },
            body: encryptedBody,
          )
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        return DeviceBindApplyResult(
          code: response.statusCode,
          msg: "HTTP Error: ${response.statusCode}",
        );
      }

      final responseJson = await compute(
        _isolatedDecrypt,
        _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes),
      );
      if (responseJson == null) {
        return const DeviceBindApplyResult(code: -2, msg: 'Decryption Failed');
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final data = responseJson['data'];
      if (data is! Map) {
        return DeviceBindApplyResult(
          code: code is int ? code : int.tryParse(code.toString()) ?? -3,
          msg: msg,
        );
      }

      final normalizedData = Map<String, dynamic>.from(data);
      return DeviceBindApplyResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
        data: DeviceBindApplyInfo(
          bindToken: normalizedData['bind_token']?.toString() ?? '',
          bindUrl: normalizedData['bind_url']?.toString() ?? '',
          expireTime: normalizedData['expire_time']?.toString() ?? '',
        ),
      );
    } catch (e) {
      _log("DEBUG: ApplyDeviceBind Error: $e");
      return DeviceBindApplyResult(code: -4, msg: "Exception: $e");
    }
  }

  Future<DeviceBindScanResult> scanDeviceBind({
    required String bindToken,
  }) async {
    try {
      if (_token == null) {
        return const DeviceBindScanResult(code: -1, msg: 'Token is missing');
      }

      final url = Uri.parse(
        "$_baseUrl/app/v2/user/device-bind/scan?bind_token=${Uri.encodeQueryComponent(bindToken)}",
      );
      final response = await _client
          .get(
            url,
            headers: {
              "Content-Type": "application/octet-stream",
              "Authorization": "Bearer $_token",
            },
          )
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        return DeviceBindScanResult(
          code: response.statusCode,
          msg: "HTTP Error: ${response.statusCode}",
        );
      }

      final responseJson = await compute(
        _isolatedDecrypt,
        _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes),
      );
      if (responseJson == null) {
        return const DeviceBindScanResult(code: -2, msg: 'Decryption Failed');
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final data = responseJson['data'];
      final normalizedData = data is Map<String, dynamic>
          ? data
          : data is Map
          ? Map<String, dynamic>.from(data)
          : <String, dynamic>{};
      final userIdRaw = normalizedData['user_id'];
      final bindUserIdRaw = normalizedData['bind_user_id'];

      return DeviceBindScanResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
        data: normalizedData.isEmpty
            ? null
            : DeviceBindScanInfo(
                userId: userIdRaw is int
                    ? userIdRaw
                    : int.tryParse(userIdRaw?.toString() ?? ''),
                bindUserId: bindUserIdRaw is int
                    ? bindUserIdRaw
                    : int.tryParse(bindUserIdRaw?.toString() ?? ''),
              ),
      );
    } catch (e) {
      _log("DEBUG: ScanDeviceBind Error: $e");
      return DeviceBindScanResult(code: -4, msg: "Exception: $e");
    }
  }

  Future<AgentKeyRedeemResult> redeemAgentKey({required String key}) async {
    try {
      if (_token == null) {
        return const AgentKeyRedeemResult(code: -1, msg: 'Token is missing');
      }

      final urlStr = "$_baseUrl/app/v2/user/agent-key/redeem";
      final url = Uri.parse(urlStr);
      final encryptedBody = await compute(
        _isolatedEncrypt,
        _CryptoParams(_aesKey, _obfuscateKey, {"key": key}),
      );

      final response = await _client
          .post(
            url,
            headers: {
              "Content-Type": "application/octet-stream",
              "Authorization": "Bearer $_token",
            },
            body: encryptedBody,
          )
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        return AgentKeyRedeemResult(
          code: response.statusCode,
          msg: "HTTP Error: ${response.statusCode}",
        );
      }

      final responseJson = await compute(
        _isolatedDecrypt,
        _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes),
      );
      if (responseJson == null) {
        return const AgentKeyRedeemResult(code: -2, msg: 'Decryption Failed');
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final data = responseJson['data'];
      final normalizedData = data is Map<String, dynamic>
          ? data
          : data is Map
          ? Map<String, dynamic>.from(data)
          : <String, dynamic>{};

      final trafficQuotaRaw = normalizedData['traffic_quota'];
      final validDaysRaw = normalizedData['valid_days'];

      return AgentKeyRedeemResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
        packageName: normalizedData['package_name']?.toString(),
        trafficQuota: trafficQuotaRaw is int
            ? trafficQuotaRaw
            : int.tryParse(trafficQuotaRaw?.toString() ?? ''),
        validDays: validDaysRaw is int
            ? validDaysRaw
            : int.tryParse(validDaysRaw?.toString() ?? ''),
        usedTime: normalizedData['used_time']?.toString(),
      );
    } catch (e) {
      _log("DEBUG: RedeemAgentKey Error: $e");
      return AgentKeyRedeemResult(code: -4, msg: "Exception: $e");
    }
  }

  Future<TicketStatusResult> fetchTicketStatus() async {
    try {
      if (_token == null) {
        return const TicketStatusResult(code: -1, msg: 'Token is missing');
      }

      final url = Uri.parse("$_baseUrl/app/v2/user/ticket/status");
      final response = await _client
          .get(
            url,
            headers: {
              "Content-Type": "application/octet-stream",
              "Authorization": "Bearer $_token",
            },
          )
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        return TicketStatusResult(
          code: response.statusCode,
          msg: "HTTP Error: ${response.statusCode}",
        );
      }

      final responseJson = await compute(
        _isolatedDecrypt,
        _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes),
      );
      if (responseJson == null) {
        return const TicketStatusResult(code: -2, msg: 'Decryption Failed');
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final data = responseJson['data'];

      return TicketStatusResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
        data: _parseTicketStatus(data),
      );
    } catch (e) {
      _log("DEBUG: FetchTicketStatus Error: $e");
      return TicketStatusResult(code: -4, msg: "Exception: $e");
    }
  }

  Future<TicketMessagesResult> fetchTicketMessages() async {
    try {
      if (_token == null) {
        return const TicketMessagesResult(
          code: -1,
          msg: 'Token is missing',
          messages: [],
        );
      }

      final url = Uri.parse("$_baseUrl/app/v2/user/ticket/messages");
      final response = await _client
          .get(
            url,
            headers: {
              "Content-Type": "application/octet-stream",
              "Authorization": "Bearer $_token",
            },
          )
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        return TicketMessagesResult(
          code: response.statusCode,
          msg: "HTTP Error: ${response.statusCode}",
          messages: const [],
        );
      }

      final responseJson = await compute(
        _isolatedDecrypt,
        _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes),
      );
      if (responseJson == null) {
        return const TicketMessagesResult(
          code: -2,
          msg: 'Decryption Failed',
          messages: [],
        );
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final data = responseJson['data'];
      final normalizedData = data is Map<String, dynamic>
          ? data
          : data is Map
          ? Map<String, dynamic>.from(data)
          : <String, dynamic>{};

      final messages = <TicketMessage>[];
      final rawMessages = normalizedData['messages'];
      if (rawMessages is List) {
        for (final item in rawMessages) {
          if (item is! Map) continue;
          final seqRaw = item['seq'];
          messages.add(
            TicketMessage(
              seq: seqRaw is int
                  ? seqRaw
                  : int.tryParse(seqRaw?.toString() ?? ''),
              sender: item['sender']?.toString() ?? 'system',
              content: item['content']?.toString() ?? '',
              createTime: item['create_time']?.toString() ?? '',
            ),
          );
        }
      }

      return TicketMessagesResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
        status: _parseTicketStatus(normalizedData['status']),
        messages: messages,
      );
    } catch (e) {
      _log("DEBUG: FetchTicketMessages Error: $e");
      return TicketMessagesResult(
        code: -4,
        msg: "Exception: $e",
        messages: const [],
      );
    }
  }

  Future<TicketSendResult> sendTicketMessage({required String message}) async {
    try {
      if (_token == null) {
        return const TicketSendResult(code: -1, msg: 'Token is missing');
      }

      final url = Uri.parse("$_baseUrl/app/v2/user/ticket/send");
      final encryptedBody = await compute(
        _isolatedEncrypt,
        _CryptoParams(_aesKey, _obfuscateKey, {"message": message}),
      );

      final response = await _client
          .post(
            url,
            headers: {
              "Content-Type": "application/octet-stream",
              "Authorization": "Bearer $_token",
            },
            body: encryptedBody,
          )
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        return TicketSendResult(
          code: response.statusCode,
          msg: "HTTP Error: ${response.statusCode}",
        );
      }

      final responseJson = await compute(
        _isolatedDecrypt,
        _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes),
      );
      if (responseJson == null) {
        return const TicketSendResult(code: -2, msg: 'Decryption Failed');
      }

      final code = responseJson['code'];
      return TicketSendResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: responseJson['msg']?.toString() ?? 'Unknown Error',
      );
    } catch (e) {
      _log("DEBUG: SendTicketMessage Error: $e");
      return TicketSendResult(code: -4, msg: "Exception: $e");
    }
  }

  Future<TicketCloseResult> closeTicket() async {
    try {
      if (_token == null) {
        return const TicketCloseResult(code: -1, msg: 'Token is missing');
      }

      final url = Uri.parse("$_baseUrl/app/v2/user/ticket/close");
      final encryptedBody = await compute(
        _isolatedEncrypt,
        _CryptoParams(_aesKey, _obfuscateKey, <String, dynamic>{}),
      );

      final response = await _client
          .post(
            url,
            headers: {
              "Content-Type": "application/octet-stream",
              "Authorization": "Bearer $_token",
            },
            body: encryptedBody,
          )
          .timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        return TicketCloseResult(
          code: response.statusCode,
          msg: "HTTP Error: ${response.statusCode}",
        );
      }

      final responseJson = await compute(
        _isolatedDecrypt,
        _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes),
      );
      if (responseJson == null) {
        return const TicketCloseResult(code: -2, msg: 'Decryption Failed');
      }

      final code = responseJson['code'];
      return TicketCloseResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: responseJson['msg']?.toString() ?? 'Unknown Error',
      );
    } catch (e) {
      _log("DEBUG: CloseTicket Error: $e");
      return TicketCloseResult(code: -4, msg: "Exception: $e");
    }
  }

  TicketStatusInfo? _parseTicketStatus(dynamic raw) {
    if (raw is! Map) return null;
    final normalized = raw is Map<String, dynamic>
        ? raw
        : Map<String, dynamic>.from(raw);
    final isActiveRaw = normalized['is_active'];
    final isClosedRaw = normalized['is_closed'];
    final queueAheadRaw = normalized['queue_ahead'];
    final waitingUserRaw = normalized['waiting_user'];
    return TicketStatusInfo(
      status: normalized['status']?.toString() ?? 'idle',
      isActive: isActiveRaw is bool
          ? isActiveRaw
          : isActiveRaw?.toString().toLowerCase() == 'true',
      isClosed: isClosedRaw is bool
          ? isClosedRaw
          : isClosedRaw?.toString().toLowerCase() == 'true',
      queueAhead: queueAheadRaw is int
          ? queueAheadRaw
          : int.tryParse(queueAheadRaw?.toString() ?? '') ?? 0,
      waitingUser: waitingUserRaw is int
          ? waitingUserRaw
          : int.tryParse(waitingUserRaw?.toString() ?? '') ?? 0,
      latestAdminMessage: _parseTicketMessage(
        normalized['latest_admin_message'],
      ),
    );
  }

  TicketMessage? _parseTicketMessage(dynamic raw) {
    if (raw is! Map) return null;
    final normalized = raw is Map<String, dynamic>
        ? raw
        : Map<String, dynamic>.from(raw);
    final content = normalized['content']?.toString() ?? '';
    if (content.isEmpty) return null;
    final seqRaw = normalized['seq'];
    return TicketMessage(
      seq: seqRaw is int ? seqRaw : int.tryParse(seqRaw?.toString() ?? ''),
      sender: normalized['sender']?.toString() ?? 'admin',
      content: content,
      createTime: normalized['create_time']?.toString() ?? '',
    );
  }
}
