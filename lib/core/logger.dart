import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

class AppLogger {
  static const int _maxLogs = 500;
  static final List<String> _logs = <String>[];
  static final ValueNotifier<int> _changes = ValueNotifier<int>(0);
  static final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 5,
      lineLength: 80,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.none,
    ),
    // 仅在 Debug 模式下输出日志，Release 模式下彻底关闭
    level: kReleaseMode ? Level.off : Level.debug,
  );

  static void d(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    final text = _format(message);
    _append('D', text);
    _logger.d(text, error: error, stackTrace: stackTrace);
  }

  static void i(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    final text = _format(message);
    _append('I', text);
    _logger.i(text, error: error, stackTrace: stackTrace);
  }

  static void w(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    final text = _format(message);
    _append('W', text);
    _logger.w(text, error: error, stackTrace: stackTrace);
  }

  static void e(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    final text = _format(message);
    _append('E', text);
    _logger.e(text, error: error, stackTrace: stackTrace);
  }

  static String dumpLogs() => _logs.join('\n');

  static ValueListenable<int> get changes => _changes;

  static void clearLogs() {
    _logs.clear();
    _changes.value++;
  }

  static void _append(String level, String message) {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    _logs.add('[$h:$m:$s][$level] $message');
    if (_logs.length > _maxLogs) {
      _logs.removeRange(0, _logs.length - _maxLogs);
    }
    _changes.value++;
  }

  // 统一的日志格式化和脱敏处理
  static String _format(dynamic message) {
    if (message == null) return 'null';
    String str = message.toString();

    // 在非 Debug 模式下，或者即使在 Debug 模式下也可能需要脱敏一些极度敏感的信息（如 Token）
    // 但用户建议提到 "仅在 Debug 模式下输出敏感信息"，这意味着 Debug 模式下可能不需要完全脱敏 URL？
    // 为了安全起见，我们保留 Bearer Token 的脱敏，但可以放宽 URL 的显示（如果是 debug）。

    // 统一脱敏逻辑：
    // 1. Bearer Token 始终脱敏
    str = str.replaceAll(
      RegExp(r'Bearer\s+[A-Za-z0-9\-._~+/]+=*'),
      'Bearer [REDACTED]',
    );

    // 2. URL 脱敏 (可选，视调试需求而定，这里保持一致性，但允许在 Debug 时通过特殊标记绕过如果需要)
    // str = str.replaceAll(RegExp(r'https?://[^\s]+'), '[REDACTED_URL]');

    return str;
  }
}
