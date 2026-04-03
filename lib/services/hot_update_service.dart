import 'dart:convert';
import 'dart:io';

import 'package:app/services/api_service.dart';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum HotUpdateStage {
  idle,
  checking,
  downloading,
  extracting,
  applying,
  restarting,
  completed,
  failed,
}

class HotUpdateProgress {
  final HotUpdateStage stage;
  final String title;
  final String detail;
  final double downloadProgress;
  final double extractProgress;
  final double applyProgress;

  const HotUpdateProgress({
    required this.stage,
    required this.title,
    required this.detail,
    this.downloadProgress = 0,
    this.extractProgress = 0,
    this.applyProgress = 0,
  });
}

class HotUpdateExecutionResult {
  final bool shouldContinue;
  final bool appliedUpdate;
  final bool requiresRestart;
  final String message;

  const HotUpdateExecutionResult({
    required this.shouldContinue,
    required this.appliedUpdate,
    this.requiresRestart = false,
    required this.message,
  });
}

class HotUpdateService {
  static const int _defaultAppliedVersion = 100;
  static const String _runtimeBundleDirectoryName = 'runtime_bundle';
  static const String _storedVersionKey = 'hot_update_applied_version';
  static const String _hotUpdateMethodChannelName = 'com.accelerator.tg/hot_update';
  static final MethodChannel _hotUpdateMethodChannel = MethodChannel(
    _hotUpdateMethodChannelName,
  );
  static final HotUpdateService _instance = HotUpdateService._internal();

  factory HotUpdateService() {
    return _instance;
  }

  HotUpdateService._internal();

  Future<AssetBundle> resolveRuntimeAssetBundle() async {
    if (kDebugMode || kIsWeb || !Platform.isAndroid) {
      return rootBundle;
    }
    final currentDir = await _resolveReadableCurrentBundleDirectory('android');
    if (currentDir == null) {
      return rootBundle;
    }
    final assetDir = Directory(p.join(currentDir.path, 'flutter_assets'));
    if (!await _hasFlutterAssetsMarkers(assetDir) ||
        !await _hasEnoughFlutterAssetsContent(assetDir)) {
      return rootBundle;
    }
    return _HotUpdateFileAssetBundle(
      rootDirectory: assetDir,
      fallbackBundle: rootBundle,
    );
  }

  Future<ByteData> loadRuntimeAsset(String key) async {
    final bundle = await resolveRuntimeAssetBundle();
    return bundle.load(key);
  }

  Future<HotUpdateExecutionResult> performStartupUpdate({
    required ValueChanged<HotUpdateProgress> onProgress,
  }) async {
    if (kDebugMode) {
      return const HotUpdateExecutionResult(
        shouldContinue: true,
        appliedUpdate: false,
        message: '调试包已关闭热更新',
      );
    }
    final env = _resolveEnv();
    if (env == null) {
      return const HotUpdateExecutionResult(
        shouldContinue: true,
        appliedUpdate: false,
        message: '当前平台不支持热更新',
      );
    }
    final packageInfo = await PackageInfo.fromPlatform();
    await _purgeBrokenBundlesIfNeeded(env: env);
    final version = await _resolveVersionForCheck(packageInfo);
    final hotUpdateRoot = await _hotUpdateWorkspaceDirectory();
    final workDir = Directory(
      p.join(
        hotUpdateRoot.path,
        'work',
        '${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
    await workDir.create(recursive: true);
    onProgress(
      HotUpdateProgress(
        stage: HotUpdateStage.checking,
        title: '检查热更新',
        detail: '正在检查本地版本 $version 是否需要更新',
      ),
    );
    try {
      final zipFile = File(p.join(workDir.path, 'update.zip'));
      final result = await ApiService().checkAppUpdate(
        env: env,
        version: version,
        downloadFile: zipFile,
        onDownloadProgress: (received, total) {
          final progress = total != null && total > 0 ? received / total : 0.0;
          onProgress(
            HotUpdateProgress(
              stage: HotUpdateStage.downloading,
              title: '下载更新包',
              detail: total != null && total > 0
                  ? '已下载 ${(progress * 100).toStringAsFixed(0)}%'
                  : '正在下载更新包',
              downloadProgress: _normalizeProgress(progress),
            ),
          );
        },
      );
      if (!result.needUpdate || result.zipFile == null) {
        await _safeDelete(workDir);
        onProgress(
          HotUpdateProgress(
            stage: HotUpdateStage.completed,
            title: '已是最新版本',
            detail: result.msg,
            downloadProgress: 1,
            extractProgress: 1,
            applyProgress: 1,
          ),
        );
        return HotUpdateExecutionResult(
          shouldContinue: true,
          appliedUpdate: false,
          message: result.msg,
        );
      }
      final extractedDir = Directory(p.join(workDir.path, 'extracted'));
      await extractedDir.create(recursive: true);
      await _extractZip(
        zipFile: result.zipFile!,
        targetDir: extractedDir,
        onProgress: (progress, detail) {
          onProgress(
            HotUpdateProgress(
              stage: HotUpdateStage.extracting,
              title: '解压更新包',
              detail: '已解压 ${(progress * 100).toStringAsFixed(0)}%',
              downloadProgress: 1,
              extractProgress: progress,
            ),
          );
        },
      );
      await _preparePendingBundle(
        env: env,
        extractedDir: extractedDir,
        latestVersion: result.latestVersion,
        onProgress: (progress, detail) {
          onProgress(
            HotUpdateProgress(
              stage: HotUpdateStage.applying,
              title: '覆盖热更新文件',
              detail: '已覆盖 ${(progress * 100).toStringAsFixed(0)}%',
              downloadProgress: 1,
              extractProgress: 1,
              applyProgress: progress,
            ),
          );
        },
      );
      await _storeAppliedVersion(result.latestVersion);
      await _safeDelete(workDir);
      onProgress(
        HotUpdateProgress(
          stage: HotUpdateStage.completed,
          title: '更新完成',
          detail: '新版本[${result.latestVersion}]已更新，请重启APP生效',
          downloadProgress: 1,
          extractProgress: 1,
          applyProgress: 1,
        ),
      );
      return const HotUpdateExecutionResult(
        shouldContinue: false,
        appliedUpdate: true,
        requiresRestart: true,
        message: '更新完成，请重启应用',
      );
    } catch (e) {
      await _safeDelete(workDir);
      onProgress(
        HotUpdateProgress(
          stage: HotUpdateStage.failed,
          title: '热更新失败',
          detail: e.toString(),
        ),
      );
      rethrow;
    }
  }

  Future<String> _resolveVersionForCheck(PackageInfo packageInfo) async {
    final packageVersion = packageInfo.buildNumber.trim().isNotEmpty
        ? packageInfo.buildNumber.trim()
        : packageInfo.version.trim();
    final storedVersion = await _readStoredVersion();
    final packageVersionInt = int.tryParse(packageVersion);
    if (packageVersionInt == null || storedVersion >= packageVersionInt) {
      return storedVersion.toString();
    }
    return packageVersion;
  }

  Future<int> _readStoredVersion() async {
    final preferences = await SharedPreferences.getInstance();
    final storedVersion = preferences.getInt(_storedVersionKey);
    if (storedVersion != null) {
      return storedVersion;
    }
    final storedValue = preferences.getString(_storedVersionKey);
    return int.tryParse(storedValue ?? '') ?? _defaultAppliedVersion;
  }

  Future<void> _storeAppliedVersion(int version) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_storedVersionKey, version);
  }

  Future<void> _clearStoredVersion() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_storedVersionKey);
  }

  String? _resolveEnv() {
    if (kIsWeb) {
      return null;
    }
    if (Platform.isAndroid) {
      return 'android';
    }
    if (Platform.isIOS) {
      return 'ios';
    }
    if (Platform.isWindows) {
      return 'windows';
    }
    return null;
  }

  Future<Directory> _hotUpdateWorkspaceDirectory() async {
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.trim().isNotEmpty) {
        return Directory(
          p.join(
            localAppData,
            p.basenameWithoutExtension(Platform.resolvedExecutable),
            'hot_update',
          ),
        );
      }
      return Directory(
        p.join(File(Platform.resolvedExecutable).parent.path, 'hot_update'),
      );
    }
    final supportDirectory = await getApplicationSupportDirectory();
    return Directory(p.join(supportDirectory.path, 'hot_update'));
  }

  Future<Directory> _hotUpdateBundleRootDirectory() async {
    final workspace = await _hotUpdateWorkspaceDirectory();
    return Directory(p.join(workspace.path, _runtimeBundleDirectoryName));
  }

  Future<Directory?> _legacyHotUpdateBundleRootDirectory() async {
    if (Platform.isWindows) {
      return Directory(
        p.join(File(Platform.resolvedExecutable).parent.path, 'hot_update'),
      );
    }
    return _hotUpdateWorkspaceDirectory();
  }

  Future<Directory?> _resolveReadableCurrentBundleDirectory(String env) async {
    final candidateRoots = <Directory>[await _hotUpdateBundleRootDirectory()];
    final legacyRoot = await _legacyHotUpdateBundleRootDirectory();
    if (legacyRoot != null &&
        p.normalize(legacyRoot.path) !=
            p.normalize(candidateRoots.first.path)) {
      candidateRoots.add(legacyRoot);
    }
    for (final root in candidateRoots) {
      final currentDir = Directory(p.join(root.path, 'current'));
      if (await _isPreparedBundleValid(env: env, stagingDir: currentDir)) {
        return currentDir;
      }
    }
    return null;
  }

  Future<void> _purgeBrokenBundlesIfNeeded({required String env}) async {
    final bundleRoot = await _hotUpdateBundleRootDirectory();
    final legacyRoot = await _legacyHotUpdateBundleRootDirectory();
    final roots = <Directory>[bundleRoot];
    if (legacyRoot != null &&
        p.normalize(legacyRoot.path) != p.normalize(bundleRoot.path)) {
      roots.add(legacyRoot);
    }

    var purged = false;
    for (final root in roots) {
      final currentDir = Directory(p.join(root.path, 'current'));
      if (await currentDir.exists() &&
          !await _isPreparedBundleValid(env: env, stagingDir: currentDir)) {
        await _safeDelete(currentDir);
        purged = true;
      }
      final pendingDir = Directory(p.join(root.path, 'pending'));
      if (await pendingDir.exists() &&
          !await _isPreparedBundleValid(env: env, stagingDir: pendingDir)) {
        await _safeDelete(pendingDir);
        purged = true;
      }
    }

    if (purged) {
      await _clearStoredVersion();
    }
  }

  Future<void> _extractZip({
    required File zipFile,
    required Directory targetDir,
    required void Function(double progress, String detail) onProgress,
  }) async {
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    _debugHotUpdate(
      '开始解压: zip=${zipFile.path}, target=${targetDir.path}, entries=${archive.files.length}',
    );
    _debugHotUpdate(
      'ZIP 条目预览: ${archive.files.take(20).map((file) => _normalizeArchivePath(file.name)).join(' | ')}',
    );
    final totalBytes = archive.files
        .where((file) => file.isFile)
        .fold<int>(0, (sum, file) => sum + (file.size as int? ?? 0));
    var completedBytes = 0;
    if (archive.files.isEmpty) {
      throw Exception('更新包为空');
    }
    for (final file in archive.files) {
      final normalizedArchivePath = _normalizeArchivePath(file.name);
      final outputPath = p.normalize(p.join(targetDir.path, normalizedArchivePath));
      if (!p.isWithin(targetDir.path, outputPath) &&
          outputPath != p.normalize(targetDir.path)) {
        throw Exception('更新包包含非法路径');
      }
      if (file.isFile) {
        final outputFile = File(outputPath);
        await outputFile.parent.create(recursive: true);
        await outputFile.writeAsBytes(file.content as List<int>, flush: true);
        completedBytes += file.size as int? ?? 0;
      } else {
        await Directory(outputPath).create(recursive: true);
      }
      final progress = totalBytes > 0 ? completedBytes / totalBytes : 1.0;
      onProgress(
        _normalizeProgress(progress),
        '正在解压 ${p.basename(normalizedArchivePath)}',
      );
    }
  }

  Future<void> _preparePendingBundle({
    required String env,
    required Directory extractedDir,
    required int latestVersion,
    required void Function(double progress, String detail) onProgress,
  }) async {
    final root = await _hotUpdateBundleRootDirectory();
    final pendingDir = Directory(p.join(root.path, 'pending'));
    final stagingDir = Directory(
      p.join(root.path, 'staging', latestVersion.toString()),
    );
    await _safeDelete(pendingDir);
    await _safeDelete(stagingDir);
    await stagingDir.create(recursive: true);
    await _seedStagingDirectory(
      env: env,
      stagingDir: stagingDir,
    );
    final tasks = await _buildCopyTasks(
      env: env,
      extractedDir: extractedDir,
      destinationRoot: stagingDir,
    );
    final totalBytes = tasks.fold<int>(0, (sum, task) => sum + task.length);
    var completedBytes = 0;
    for (final task in tasks) {
      await task.destination.parent.create(recursive: true);
      await task.destination.writeAsBytes(
        await task.source.readAsBytes(),
        flush: true,
      );
      if (!await task.destination.exists() ||
          await task.destination.length() != task.length) {
        throw Exception('覆盖失败: ${p.basename(task.destination.path)}');
      }
      completedBytes += task.length;
      final progress = totalBytes > 0 ? completedBytes / totalBytes : 1.0;
      onProgress(
        _normalizeProgress(progress),
        '正在覆盖 ${p.basename(task.destination.path)}',
      );
    }
    final metaFile = File(p.join(stagingDir.path, 'meta.json'));
    await metaFile.writeAsString(
      json.encode({
        'version': latestVersion,
        'env': env,
        'updated_at': DateTime.now().toIso8601String(),
      }),
      flush: true,
    );
    if (!await _isPreparedBundleValid(env: env, stagingDir: stagingDir)) {
      throw Exception('热更新资源校验失败');
    }
    await stagingDir.rename(pendingDir.path);
  }

  Future<void> _seedStagingDirectory({
    required String env,
    required Directory stagingDir,
  }) async {
    if (env == 'android') {
      _debugHotUpdate('Android 每次都基于内置 APK 全量资源做增量覆盖');
      await _seedBuiltInBundle(
        env: env,
        stagingDir: stagingDir,
      );
      return;
    }
    final seedSourceDir = await _resolveReadableCurrentBundleDirectory(env);
    if (seedSourceDir != null) {
      _debugHotUpdate(
        '基于现有热更新目录增量覆盖: current=${seedSourceDir.path}, staging=${stagingDir.path}',
      );
      await _copyDirectoryContents(
        sourceDir: seedSourceDir,
        destinationDir: stagingDir,
      );
      return;
    }
    _debugHotUpdate('当前无已生效热更新目录，改为基于内置资源增量覆盖');
    await _seedBuiltInBundle(
      env: env,
      stagingDir: stagingDir,
    );
  }

  Future<void> _seedBuiltInBundle({
    required String env,
    required Directory stagingDir,
  }) async {
    if (env == 'android') {
      final destinationRoot = Directory(p.join(stagingDir.path, 'flutter_assets'));
      await _exportBundledFlutterAssetsAndroid(destinationRoot: destinationRoot);
      return;
    }
    if (env == 'ios') {
      final builtInFrameworkDir = Directory(
        p.join(
          File(Platform.resolvedExecutable).parent.path,
          'Frameworks',
          'App.framework',
        ),
      );
      await _ensureExists(builtInFrameworkDir, '缺少内置 App.framework');
      await _copyDirectoryContents(
        sourceDir: builtInFrameworkDir,
        destinationDir: Directory(p.join(stagingDir.path, 'App.framework')),
      );
      return;
    }
    if (env == 'windows') {
      final builtInDataDir = Directory(
        p.join(File(Platform.resolvedExecutable).parent.path, 'data'),
      );
      await _ensureExists(builtInDataDir, '缺少内置 data 目录');
      await _copyDirectoryContents(
        sourceDir: builtInDataDir,
        destinationDir: stagingDir,
      );
    }
  }

  Future<void> _exportBundledFlutterAssetsAndroid({
    required Directory destinationRoot,
  }) async {
    await destinationRoot.create(recursive: true);
    try {
      await _hotUpdateMethodChannel.invokeMethod('exportBundledFlutterAssets', {
        'destination': destinationRoot.path,
      });
      await _validateBundledFlutterAssetsFromManifest(destinationRoot);
      if (!await _hasFlutterAssetsMarkers(destinationRoot) ||
          !await _hasEnoughFlutterAssetsContent(destinationRoot)) {
        throw Exception('导出 flutter_assets 后校验失败');
      }
      return;
    } catch (e) {
      _debugHotUpdate('导出内置 flutter_assets 失败，回退 Dart 侧拷贝: $e');
      await _safeDelete(destinationRoot);
      await destinationRoot.create(recursive: true);
      await _seedBundledFlutterAssets(destinationRoot: destinationRoot);
      await _validateBundledFlutterAssetsFromManifest(destinationRoot);
    }
  }

  Future<void> _validateBundledFlutterAssetsFromManifest(
    Directory destinationRoot,
  ) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final requiredKeys = <String>{};
    for (final assetKey in manifest.listAssets()) {
      requiredKeys.add(assetKey);
      final variants = manifest.getAssetVariants(assetKey);
      if (variants != null) {
        for (final variant in variants) {
          requiredKeys.add(variant.key);
        }
      }
    }
    var missing = 0;
    for (final key in requiredKeys) {
      final file = File(p.join(destinationRoot.path, key));
      if (!await file.exists()) {
        missing += 1;
        if (missing >= 20) {
          break;
        }
      }
    }
    if (missing > 0) {
      throw Exception('内置资源导出不完整(missing=$missing)');
    }
  }

  Future<void> _seedBundledFlutterAssets({
    required Directory destinationRoot,
  }) async {
    await destinationRoot.create(recursive: true);
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assetKeys = <String>{};
    for (final assetKey in manifest.listAssets()) {
      assetKeys.add(assetKey);
      final variants = manifest.getAssetVariants(assetKey);
      if (variants != null) {
        for (final variant in variants) {
          assetKeys.add(variant.key);
        }
      }
    }
    for (final assetKey in assetKeys) {
      final byteData = await rootBundle.load(assetKey);
      final destinationFile = File(p.join(destinationRoot.path, assetKey));
      await destinationFile.parent.create(recursive: true);
      await destinationFile.writeAsBytes(
        byteData.buffer.asUint8List(),
        flush: true,
      );
    }
    const markerFiles = [
      'AssetManifest.bin',
      'AssetManifest.bin.json',
      'AssetManifest.json',
      'FontManifest.json',
      'NativeAssetsManifest.json',
      'NOTICES.Z',
    ];
    for (final marker in markerFiles) {
      try {
        final byteData = await rootBundle.load(marker);
        final destinationFile = File(p.join(destinationRoot.path, marker));
        await destinationFile.parent.create(recursive: true);
        await destinationFile.writeAsBytes(
          byteData.buffer.asUint8List(),
          flush: true,
        );
      } catch (_) {
      }
    }
    const extraFiles = [
      'isolate_snapshot_data',
      'vm_snapshot_data',
      'kernel_blob.bin',
      'platform_strong.dill',
      'native_assets.json',
    ];
    for (final name in extraFiles) {
      try {
        final byteData = await rootBundle.load(name);
        final destinationFile = File(p.join(destinationRoot.path, name));
        await destinationFile.parent.create(recursive: true);
        await destinationFile.writeAsBytes(
          byteData.buffer.asUint8List(),
          flush: true,
        );
      } catch (_) {
      }
    }
  }

  Future<bool> _isPreparedBundleValid({
    required String env,
    required Directory stagingDir,
  }) async {
    if (!await stagingDir.exists()) {
      return false;
    }
    if (env == 'android') {
      final libappFile = File(p.join(stagingDir.path, 'libapp.so'));
      final assetsDir = Directory(p.join(stagingDir.path, 'flutter_assets'));
      return await libappFile.exists() &&
          await _hasFlutterAssetsMarkers(assetsDir) &&
          await _hasEnoughFlutterAssetsContent(assetsDir);
    }
    if (env == 'ios') {
      final appFile = File(p.join(stagingDir.path, 'App.framework', 'App'));
      final assetsDir = Directory(
        p.join(stagingDir.path, 'App.framework', 'flutter_assets'),
      );
      return await appFile.exists() &&
          await _hasFlutterAssetsMarkers(assetsDir) &&
          await _hasEnoughFlutterAssetsContent(assetsDir);
    }
    if (env == 'windows') {
      final appFile = File(p.join(stagingDir.path, 'app.so'));
      final icuFile = File(p.join(stagingDir.path, 'icudtl.dat'));
      final assetsDir = Directory(p.join(stagingDir.path, 'flutter_assets'));
      return await appFile.exists() &&
          await icuFile.exists() &&
          await _hasFlutterAssetsMarkers(assetsDir) &&
          await _hasEnoughFlutterAssetsContent(assetsDir);
    }
    return false;
  }

  Future<bool> _hasFlutterAssetsMarkers(Directory assetsDir) async {
    if (!await assetsDir.exists()) {
      return false;
    }
    const markers = [
      'AssetManifest.bin',
      'AssetManifest.json',
      'FontManifest.json',
      'NOTICES.Z',
    ];
    for (final marker in markers) {
      if (await File(p.join(assetsDir.path, marker)).exists()) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _hasEnoughFlutterAssetsContent(Directory assetsDir) async {
    if (!await assetsDir.exists()) {
      return false;
    }
    const markerBasenames = {
      'AssetManifest.bin',
      'AssetManifest.bin.json',
      'AssetManifest.json',
      'FontManifest.json',
      'NativeAssetsManifest.json',
      'NOTICES.Z',
    };
    var contentFileCount = 0;
    await for (final entity in assetsDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      if (markerBasenames.contains(p.basename(entity.path))) {
        continue;
      }
      contentFileCount += 1;
      if (contentFileCount >= 1) {
        return true;
      }
    }
    return false;
  }

  Future<void> _copyDirectoryContents({
    required Directory sourceDir,
    required Directory destinationDir,
  }) async {
    _debugHotUpdate(
      '复制目录内容: source=${sourceDir.path}, destination=${destinationDir.path}',
    );
    await for (final entity in sourceDir.list(
      recursive: true,
      followLinks: false,
    )) {
      final relativePath = p.relative(entity.path, from: sourceDir.path);
      final destinationPath = p.join(destinationDir.path, relativePath);
      if (entity is Directory) {
        await Directory(destinationPath).create(recursive: true);
        continue;
      }
      if (entity is File) {
        final destinationFile = File(destinationPath);
        await destinationFile.parent.create(recursive: true);
        await destinationFile.writeAsBytes(
          await entity.readAsBytes(),
          flush: true,
        );
      }
    }
  }

  Future<List<_CopyTask>> _buildCopyTasks({
    required String env,
    required Directory extractedDir,
    required Directory destinationRoot,
  }) async {
    _debugHotUpdate(
      '构建复制任务: env=$env, extractedDir=${extractedDir.path}, destinationRoot=${destinationRoot.path}',
    );
    if (env == 'android') {
      final sourceLib = await _findRequiredFile(
        root: extractedDir,
        pathSuffixSegments: const ['libapp.so'],
        errorMessage: '当前为 Android 发布包，更新包必须包含 libapp.so',
      );
      return [
        _CopyTask(
          source: sourceLib,
          destination: File(p.join(destinationRoot.path, 'libapp.so')),
          length: await sourceLib.length(),
        ),
        ...await _buildFlutterAssetsCopyTasks(
          root: extractedDir,
          destinationRoot: Directory(
            p.join(destinationRoot.path, 'flutter_assets'),
          ),
        ),
      ];
    }
    if (env == 'ios') {
      final sourceBinary = await _findRequiredFile(
        root: extractedDir,
        pathSuffixSegments: const ['App'],
        errorMessage: '缺少 App',
      );
      final stagingRoot = Directory(
        p.join(destinationRoot.path, 'App.framework'),
      );
      return [
        _CopyTask(
          source: sourceBinary,
          destination: File(p.join(stagingRoot.path, 'App')),
          length: await sourceBinary.length(),
        ),
        ...await _buildFlutterAssetsCopyTasks(
          root: extractedDir,
          destinationRoot: Directory(
            p.join(stagingRoot.path, 'flutter_assets'),
          ),
        ),
      ];
    }
    if (env == 'windows') {
      final sourceBinary = await _findRequiredFile(
        root: extractedDir,
        pathSuffixSegments: const ['app.so'],
        errorMessage: '缺少 app.so',
      );
      final stagingRoot = destinationRoot;
      return [
        _CopyTask(
          source: sourceBinary,
          destination: File(p.join(stagingRoot.path, 'app.so')),
          length: await sourceBinary.length(),
        ),
        ...await _buildFlutterAssetsCopyTasks(
          root: extractedDir,
          destinationRoot: Directory(
            p.join(stagingRoot.path, 'flutter_assets'),
          ),
        ),
      ];
    }
    throw Exception('不支持的热更新平台');
  }

  Future<File> _findRequiredFile({
    required Directory root,
    required List<String> pathSuffixSegments,
    required String errorMessage,
  }) async {
    final normalizedSuffix = p.normalize(p.joinAll(pathSuffixSegments));
    _debugHotUpdate(
      '查找文件: suffix=$normalizedSuffix, root=${root.path}',
    );
    final previewPaths = <String>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final normalizedRelativePath = p.normalize(
        _normalizeArchivePath(p.relative(entity.path, from: root.path)),
      );
      if (previewPaths.length < 20) {
        previewPaths.add(normalizedRelativePath);
      }
      if (normalizedRelativePath == normalizedSuffix ||
          normalizedRelativePath.endsWith(
            '${p.separator}$normalizedSuffix',
          )) {
        _debugHotUpdate('命中文件: $normalizedRelativePath');
        return entity;
      }
    }
    _debugHotUpdate(
      '未找到文件: suffix=$normalizedSuffix, files=${previewPaths.join(' | ')}',
    );
    throw Exception(errorMessage);
  }

  Future<List<_CopyTask>> _buildFlutterAssetsCopyTasks({
    required Directory root,
    required Directory destinationRoot,
  }) async {
    final tasks = <_CopyTask>[];
    final assetPreviewPaths = <String>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final relativePath = p.normalize(p.relative(entity.path, from: root.path));
      final normalizedRelativePath = _normalizeArchivePath(relativePath);
      final segments = p.posix.split(normalizedRelativePath);
      final matchIndex = segments.indexWhere(
        (segment) => segment.toLowerCase() == 'flutter_assets',
      );
      if (matchIndex < 0 || matchIndex == segments.length - 1) {
        continue;
      }
      final assetRelativePath = p.joinAll(segments.skip(matchIndex + 1));
      if (assetPreviewPaths.length < 20) {
        assetPreviewPaths.add('$normalizedRelativePath -> $assetRelativePath');
      }
      tasks.add(
        _CopyTask(
          source: entity,
          destination: File(p.join(destinationRoot.path, assetRelativePath)),
          length: await entity.length(),
        ),
      );
    }
    if (tasks.isNotEmpty) {
      _debugHotUpdate(
        'flutter_assets 命中 ${tasks.length} 个文件: ${assetPreviewPaths.join(' | ')}',
      );
      return tasks;
    }
    const flutterAssetMarkerFiles = [
      'AssetManifest.bin',
      'AssetManifest.json',
      'FontManifest.json',
      'NativeAssetsManifest.json',
      'NOTICES.Z',
    ];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final basename = p.basename(entity.path);
      if (!flutterAssetMarkerFiles.contains(basename)) {
        continue;
      }
      final assetRoot = entity.parent;
      _debugHotUpdate(
        '通过标记文件推断 flutter_assets 根目录: ${assetRoot.path}, marker=$basename',
      );
      return _buildDirectoryCopyTasks(
        sourceRoot: assetRoot,
        destinationRoot: destinationRoot,
      );
    }
    final previewPaths = await _listRelativeFiles(root: root, limit: 30);
    _debugHotUpdate(
      '未找到 flutter_assets, root=${root.path}, files=${previewPaths.join(' | ')}',
    );
    throw Exception('缺少 flutter_assets');
  }

  Future<List<String>> _listRelativeFiles({
    required Directory root,
    required int limit,
  }) async {
    final paths = <String>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      paths.add(p.normalize(p.relative(entity.path, from: root.path)));
      paths[paths.length - 1] = _normalizeArchivePath(paths.last);
      if (paths.length >= limit) {
        break;
      }
    }
    return paths;
  }

  String _normalizeArchivePath(String path) {
    return p.posix.normalize(path.replaceAll('\\', '/'));
  }

  void _debugHotUpdate(String message) {
    debugPrint('[hot_update] $message');
  }

  Future<List<_CopyTask>> _buildDirectoryCopyTasks({
    required Directory sourceRoot,
    required Directory destinationRoot,
  }) async {
    final tasks = <_CopyTask>[];
    await for (final entity in sourceRoot.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      final relativePath = p.relative(entity.path, from: sourceRoot.path);
      tasks.add(
        _CopyTask(
          source: entity,
          destination: File(p.join(destinationRoot.path, relativePath)),
          length: await entity.length(),
        ),
      );
    }
    return tasks;
  }

  Future<void> _ensureExists(FileSystemEntity entity, String message) async {
    if (!await entity.exists()) {
      throw Exception(message);
    }
  }

  Future<void> _safeDelete(FileSystemEntity entity) async {
    if (await entity.exists()) {
      await entity.delete(recursive: true);
    }
  }

  double _normalizeProgress(num value) {
    return value.clamp(0.0, 1.0).toDouble();
  }
}

class _HotUpdateFileAssetBundle extends CachingAssetBundle {
  final Directory rootDirectory;
  final AssetBundle fallbackBundle;

  _HotUpdateFileAssetBundle({
    required this.rootDirectory,
    required this.fallbackBundle,
  });

  @override
  Future<ByteData> load(String key) async {
    final normalizedKey = p.posix.normalize(key);
    final file = File(p.join(rootDirectory.path, normalizedKey));
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      return ByteData.sublistView(bytes);
    }
    return fallbackBundle.load(key);
  }

  @override
  Future<void> evict(String key) async {
    super.evict(key);
    fallbackBundle.evict(key);
  }
}

class _CopyTask {
  final File source;
  final File destination;
  final int length;

  const _CopyTask({
    required this.source,
    required this.destination,
    required this.length,
  });
}
