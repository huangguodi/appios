import 'package:flutter/material.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

enum ConnectionMode { off, smart, global }

class AppColors {
  static const Color background = Color(0xFF101F2D);
  static const Color cardBackground = Color(0xFF1B2E40);

  // Connection Mode Colors
  static const Color modeOff = Color(0xFF2C3E50);
  static const Color modeSmart = Color(0xFF7FE3B1);
  static const Color modeGlobal = Color(0xFFFF9F1C);

  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Colors.grey;
}

class AppStrings {
  static const String modeOff = '关闭';
  static const String modeSmart = '智能';
  static const String modeGlobal = '全局';

  static const String trafficLabel = '流量包可用: 0.00GB';
  static const String expiryLabel = '获取中...';
  static const String countryName = 'Japan';
  static const String connectionStatus = 'automatic connection';
}

class AppAssets {
  // Helper to dynamically resolve Android-style DPI folders based on device pixel ratio
  static String resolveImage(BuildContext context, String fileName) {
    final double dpr = MediaQuery.of(context).devicePixelRatio;
    String folder;
    if (dpr >= 4.0) {
      folder = 'xxxhdpi';
    } else if (dpr >= 3.0) {
      folder =
          'xxxhdpi'; // Using xxxhdpi for 3.0+ as well if xxhdpi is strictly 2.0-3.0
    } else if (dpr >= 2.0) {
      folder = 'xxhdpi';
    } else if (dpr >= 1.5) {
      folder = 'xhdpi';
    } else {
      folder = 'mdpi';
    }
    return 'assets/images/$folder/$fileName';
  }

  // To use this, you must call AppAssets.resolveImage(context, 'logo.png') in your build methods.
  // For places where context is not available or you want a static fallback, we define static getters.
  // Note: static const cannot use context, so they will point to a default (e.g. xxxhdpi) if used directly without context.

  static const String icSettings = 'assets/images/settings.svg';
  static const String icUser = 'assets/images/user.svg';
  static const String icCountry = 'assets/country/japan.svg';
  static const String icChevronRight = 'assets/images/chevron-right.svg';
  static const String icClose = 'assets/images/close.svg';
  static const String icRedeem = 'assets/images/duihaun.svg';
  static const String icSupport = 'assets/images/kefu.svg';
  static const String icInvite = 'assets/images/yaoqing.svg';
  static const String icQrCode = 'assets/images/qrcode.svg';
}

class AppPollingTaskRegistry {
  AppPollingTaskRegistry._();

  static final AppPollingTaskRegistry instance = AppPollingTaskRegistry._();

  final Map<String, AppPollingTaskRecord> _tasks = {};

  void registerTask({
    required String id,
    required Duration interval,
    Duration? initialDelay,
    required String owner,
    required bool active,
  }) {
    final existing = _tasks[id];
    if (existing != null) {
      existing
        ..interval = interval
        ..initialDelay = initialDelay
        ..owner = owner
        ..active = active;
      return;
    }
    _tasks[id] = AppPollingTaskRecord(
      id: id,
      interval: interval,
      initialDelay: initialDelay,
      owner: owner,
      active: active,
    );
  }

  void setTaskActive(String id, bool active) {
    final task = _tasks[id];
    if (task == null) {
      return;
    }
    task.active = active;
  }

  void markTaskExecuted(String id) {
    final task = _tasks[id];
    if (task == null) {
      return;
    }
    task.lastExecutedAt = DateTime.now();
  }

  Map<String, Map<String, Object?>> snapshot() {
    return _tasks.map((key, value) => MapEntry(key, value.toJson()));
  }
}

class AppPollingTaskRecord {
  AppPollingTaskRecord({
    required this.id,
    required this.interval,
    required this.initialDelay,
    required this.owner,
    required this.active,
  });

  final String id;
  Duration interval;
  Duration? initialDelay;
  String owner;
  bool active;
  DateTime? lastExecutedAt;

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'intervalMs': interval.inMilliseconds,
      'initialDelayMs': initialDelay?.inMilliseconds,
      'owner': owner,
      'active': active,
      'lastExecutedAt': lastExecutedAt?.toIso8601String(),
    };
  }
}
