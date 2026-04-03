enum AppFailureCategory { startup, login, vpnStart, hotUpdate }

enum AppFailureSurface { splash, homeVpnInline }

class AppFailurePresentation {
  final String code;
  final String title;
  final String detail;
  final String? rawDetail;

  const AppFailurePresentation({
    required this.code,
    required this.title,
    required this.detail,
    this.rawDetail,
  });
}

AppFailurePresentation mapAppFailure({
  required AppFailureCategory category,
  required AppFailureSurface surface,
  String? rawMessage,
}) {
  final normalized = _normalizeFailureMessage(rawMessage);
  final mapped = _resolveFailureCode(category, normalized);
  final title = _resolveFailureTitle(category, surface);
  final detail = _buildFailureDetail(
    code: mapped.code,
    summary: mapped.summary,
    rawDetail: normalized,
    appendRaw: mapped.appendRaw,
  );
  return AppFailurePresentation(
    code: mapped.code,
    title: title,
    detail: detail,
    rawDetail: normalized,
  );
}

class _MappedFailure {
  final String code;
  final String summary;
  final bool appendRaw;

  const _MappedFailure(this.code, this.summary, {this.appendRaw = false});
}

String _resolveFailureTitle(
  AppFailureCategory category,
  AppFailureSurface surface,
) {
  if (surface == AppFailureSurface.homeVpnInline) {
    return 'VPN 启动失败，点击重试';
  }
  switch (category) {
    case AppFailureCategory.login:
      return '登录失败';
    case AppFailureCategory.hotUpdate:
      return '热更新失败';
    case AppFailureCategory.startup:
    case AppFailureCategory.vpnStart:
      return '启动失败';
  }
}

_MappedFailure _resolveFailureCode(
  AppFailureCategory category,
  String? normalized,
) {
  final value = normalized?.toLowerCase() ?? '';
  final apiErrorMessage = _extractBetween(normalized, 'API Error:', '\n');
  final httpErrorCode = _extractHttpStatusCode(normalized);

  if (_isNetworkFailure(value)) {
    if (category == AppFailureCategory.hotUpdate) {
      return const _MappedFailure('HOTUPDATE-NETWORK', '热更新阶段网络不可用');
    }
    if (category == AppFailureCategory.login) {
      return const _MappedFailure('LOGIN-NETWORK', '登录阶段网络不可用');
    }
    return const _MappedFailure('NETWORK-UNAVAILABLE', '当前网络不可用');
  }

  if (value.contains('native channel not ready') ||
      value.contains('notimplemented') ||
      value.contains('channel-error')) {
    return const _MappedFailure('NATIVE-CHANNEL', '原生通道未就绪');
  }

  if (value.contains('native server url is empty') ||
      value.contains('native server url is invalid')) {
    return const _MappedFailure('SERVER-URL', '服务端地址未准备完成');
  }

  if (value.contains('subscribe url missing') ||
      value.contains('invalid subscribe url')) {
    return const _MappedFailure('CONFIG-SUBSCRIBE', '订阅地址缺失或无效');
  }

  if (value.contains('config download failed')) {
    final suffix = httpErrorCode == null ? '' : '（HTTP $httpErrorCode）';
    return _MappedFailure('CONFIG-DOWNLOAD', '订阅配置下载失败$suffix');
  }

  if (value.contains('config payload is invalid') ||
      value.contains('config format invalid')) {
    return const _MappedFailure('CONFIG-INVALID', '订阅配置内容无效');
  }

  if (value.contains('decryption failed')) {
    return const _MappedFailure('SERVER-PAYLOAD', '服务端响应解析失败');
  }

  if (value.contains('providerconfiguration invalid')) {
    return const _MappedFailure('VPN-PROVIDER', 'VPN 配置无效');
  }

  if (value.contains('starttunnel timeout') ||
      value.contains('startup probe timeout') ||
      value.contains('vpn authorization timeout')) {
    return const _MappedFailure('VPN-TIMEOUT', 'VPN 启动超时');
  }

  if (value.contains('failed to resolve tunnel file descriptor') ||
      value.contains('file descriptor')) {
    return const _MappedFailure('VPN-FD', 'VPN 隧道文件描述符获取失败');
  }

  if (value.contains('app group')) {
    return const _MappedFailure('IOS-APP-GROUP', 'App Group 共享目录不可用');
  }

  if (value.contains('network extension capability unavailable') ||
      value.contains('netunnelprovidersession unavailable')) {
    return const _MappedFailure('VPN-CAPABILITY', 'Network Extension 能力缺失或未正确嵌入');
  }

  if (value.contains('permission denied') ||
      value.contains('not entitled') ||
      value.contains('permission') ||
      value.contains('authorization') ||
      value.contains('denied')) {
    return const _MappedFailure('VPN-PERMISSION', 'VPN 权限或签名配置异常');
  }

  if (httpErrorCode != null) {
    if (category == AppFailureCategory.login) {
      return _MappedFailure('LOGIN-HTTP', '登录接口请求失败（HTTP $httpErrorCode）');
    }
    if (category == AppFailureCategory.hotUpdate) {
      return _MappedFailure(
        'HOTUPDATE-HTTP',
        '热更新请求失败（HTTP $httpErrorCode）',
      );
    }
    return _MappedFailure('HTTP-ERROR', '请求失败（HTTP $httpErrorCode）');
  }

  if (apiErrorMessage != null && apiErrorMessage.isNotEmpty) {
    if (category == AppFailureCategory.login) {
      return _MappedFailure('LOGIN-API', '登录接口返回：$apiErrorMessage');
    }
    return _MappedFailure('API-ERROR', '接口返回：$apiErrorMessage');
  }

  switch (category) {
    case AppFailureCategory.login:
      return const _MappedFailure(
        'LOGIN-UNKNOWN',
        '登录过程发生未知异常',
        appendRaw: true,
      );
    case AppFailureCategory.vpnStart:
      return const _MappedFailure(
        'VPN-UNKNOWN',
        'VPN 启动失败',
        appendRaw: true,
      );
    case AppFailureCategory.hotUpdate:
      return const _MappedFailure(
        'HOTUPDATE-UNKNOWN',
        '热更新执行失败',
        appendRaw: true,
      );
    case AppFailureCategory.startup:
      return const _MappedFailure(
        'STARTUP-UNKNOWN',
        '启动过程失败',
        appendRaw: true,
      );
  }
}

String _buildFailureDetail({
  required String code,
  required String summary,
  required String? rawDetail,
  required bool appendRaw,
}) {
  final prefix = '[$code] $summary';
  if (!appendRaw || rawDetail == null || rawDetail.isEmpty) {
    return prefix;
  }
  if (rawDetail == summary) {
    return prefix;
  }
  return '$prefix · $rawDetail';
}

String? _normalizeFailureMessage(String? rawMessage) {
  if (rawMessage == null) {
    return null;
  }
  var value = rawMessage.trim();
  if (value.isEmpty) {
    return null;
  }
  const prefixes = [
    'Native Start Error: ',
    'Start Exception: ',
    'Exception: ',
  ];
  for (final prefix in prefixes) {
    if (value.startsWith(prefix)) {
      value = value.substring(prefix.length).trim();
    }
  }
  final lines = value
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  if (lines.isEmpty) {
    return null;
  }
  return lines.join(' · ');
}

bool _isNetworkFailure(String value) {
  return value.contains('failed host lookup') ||
      value.contains('timeoutexception') ||
      value.contains('socketexception') ||
      value.contains('network is unreachable') ||
      value.contains('no address associated with hostname') ||
      value.contains('connection timed out') ||
      value.contains('connection reset by peer') ||
      value.contains('connection closed before full header was received');
}

String? _extractBetween(String? value, String prefix, String suffix) {
  if (value == null) {
    return null;
  }
  final start = value.indexOf(prefix);
  if (start < 0) {
    return null;
  }
  final rest = value.substring(start + prefix.length).trim();
  final end = rest.indexOf(suffix);
  final resolved = end >= 0 ? rest.substring(0, end).trim() : rest;
  return resolved.isEmpty ? null : resolved;
}

String? _extractHttpStatusCode(String? value) {
  if (value == null) {
    return null;
  }
  final match = RegExp(r'HTTP Error:\s*(\d{3})').firstMatch(value);
  return match?.group(1);
}
