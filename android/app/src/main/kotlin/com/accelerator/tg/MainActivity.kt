package com.accelerator.tg

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.util.Log
import android.os.Debug
import android.os.Bundle
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.content.pm.ApplicationInfo
import android.os.Process
import java.io.File
import java.util.LinkedHashSet
import java.util.zip.ZipFile

class MainActivity : FlutterActivity() {
    private val HOT_UPDATE_TAG = "HotUpdate"
    private val CHANNEL = "com.accelerator.tg/mihomo"
    private val SECURITY_CHANNEL = "com.accelerator.tg/security"
    private val HOT_UPDATE_CHANNEL = "com.accelerator.tg/hot_update"
    private val VPN_REQUEST_CODE = 24
    private var pendingConfigPath: String? = null
    private var pendingResult: MethodChannel.Result? = null

    private var eventSink: io.flutter.plugin.common.EventChannel.EventSink? = null

    // Load the native library
    init {
        System.loadLibrary("crypto_keys")
    }

    // Native methods
    external fun getAesKey(): String
    external fun getObfuscateKey(): String
    external fun getServerUrlKey(): String

    override fun onCreate(savedInstanceState: Bundle?) {
        logHotUpdateState("onCreate.beforeActivate")
        activatePendingHotUpdate()
        logHotUpdateState("onCreate.afterActivate")
        super.onCreate(savedInstanceState)
    }

    override fun getAppBundlePath(): String {
        val fallbackPath = FlutterInjector.instance().flutterLoader().findAppBundlePath()
        hotUpdateLog("getAppBundlePath alwaysFallback=$fallbackPath")
        logHotUpdateState("getAppBundlePath.alwaysFallback")
        return fallbackPath
    }

    override fun getFlutterShellArgs(): FlutterShellArgs {
        val args = FlutterShellArgs.fromIntent(intent)
        if (!shouldUseHotUpdateBundle()) {
            hotUpdateLog("getFlutterShellArgs skipHotUpdate")
            return args
        }
        val hotUpdateLib = resolveHotUpdateLibFile()
        if (hotUpdateLib != null) {
            args.add("--aot-shared-library-name=${hotUpdateLib.absolutePath}")
            hotUpdateLog("getFlutterShellArgs lib=${hotUpdateLib.absolutePath}")
        } else {
            hotUpdateLog("getFlutterShellArgs lib=<null>")
        }
        logHotUpdateState("getFlutterShellArgs")
        return args
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MihomoVpnService.logCallback = { message ->
            runOnUiThread { eventSink?.success(message) }
        }

        io.flutter.plugin.common.EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.accelerator.tg/mihomo/logs")
            .setStreamHandler(object : io.flutter.plugin.common.EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: io.flutter.plugin.common.EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        io.flutter.plugin.common.EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.accelerator.tg/mihomo/traffic")
            .setStreamHandler(object : io.flutter.plugin.common.EventChannel.StreamHandler {
                private var workerThread: android.os.HandlerThread? = null
                private var workerHandler: android.os.Handler? = null
                private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
                private var runnable: Runnable? = null
                override fun onListen(arguments: Any?, events: io.flutter.plugin.common.EventChannel.EventSink?) {
                    workerThread?.quitSafely()
                    workerThread = android.os.HandlerThread("mihomo-traffic")
                    workerThread?.start()
                    workerHandler = workerThread?.looper?.let { android.os.Handler(it) }
                    runnable = object : Runnable {
                        override fun run() {
                            try {
                                if (MihomoManager.isRunning()) {
                                    val (up, down) = MihomoManager.getTraffic()
                                    mainHandler.post {
                                        events?.success(mapOf("up" to up, "down" to down))
                                    }
                                }
                            } catch (e: Exception) {
                                // ignore
                            }
                            workerHandler?.postDelayed(this, 1000)
                        }
                    }
                    workerHandler?.post(runnable!!)
                }

                override fun onCancel(arguments: Any?) {
                    runnable?.let { workerHandler?.removeCallbacks(it) }
                    workerHandler = null
                    workerThread?.quitSafely()
                    workerThread = null
                    runnable = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SECURITY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isDebuggerAttached" -> {
                    result.success(Debug.isDebuggerConnected() || Debug.waitingForDebugger())
                }
                "isAppDebuggable" -> {
                    val debuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
                    result.success(debuggable)
                }
                "isProxyDetected" -> {
                    val host = System.getProperty("http.proxyHost")
                    val httpsHost = System.getProperty("https.proxyHost")
                    val hasProxyHost = !host.isNullOrBlank() || !httpsHost.isNullOrBlank()
                    result.success(hasProxyHost)
                }
                "getAesKey" -> {
                    try {
                        result.success(getAesKey())
                    } catch (e: Exception) {
                        result.error("GET_AES_KEY_FAILED", e.message, null)
                    }
                }
                "getObfuscateKey" -> {
                    try {
                        result.success(getObfuscateKey())
                    } catch (e: Exception) {
                        result.error("GET_OBFUSCATE_KEY_FAILED", e.message, null)
                    }
                }
                "getServerUrlKey" -> {
                    try {
                        result.success(getServerUrlKey())
                    } catch (e: Exception) {
                        result.error("GET_SERVER_URL_KEY_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HOT_UPDATE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "exportBundledFlutterAssets" -> {
                    val destination = call.argument<String>("destination")
                    if (destination.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "destination is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        exportBundledFlutterAssets(destination)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("EXPORT_FAILED", e.message, null)
                    }
                }
                "restartApp" -> {
                    try {
                        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                        val componentName = launchIntent?.component
                        if (launchIntent == null || componentName == null) {
                            result.error("RESTART_FAILED", "Launch intent unavailable", null)
                            return@setMethodCallHandler
                        }
                        val restartIntent = Intent.makeRestartActivityTask(componentName)
                        restartIntent.putExtras(launchIntent)
                        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
                        } else {
                            PendingIntent.FLAG_CANCEL_CURRENT
                        }
                        val pendingIntent = PendingIntent.getActivity(
                            this,
                            2048,
                            restartIntent,
                            flags
                        )
                        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
                        alarmManager.setExact(
                            AlarmManager.RTC,
                            System.currentTimeMillis() + 300,
                            pendingIntent
                        )
                        result.success(true)
                        finishAffinity()
                        Process.killProcess(Process.myPid())
                    } catch (e: Exception) {
                        result.error("RESTART_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "initAssets") {
                try {
                    copyAssetToFiles("mihomo_android/mihomo", "mihomo")
                    result.success(true)
                } catch (e: Exception) {
                    result.error("INIT_FAILED", "Failed to copy assets: ${e.message}", null)
                }
            } else if (call.method == "getAesKey") {
                try {
                    result.success(getAesKey())
                } catch (e: Exception) {
                    result.error("GET_AES_KEY_FAILED", e.message, null)
                }
            } else if (call.method == "getObfuscateKey") {
                try {
                    result.success(getObfuscateKey())
                } catch (e: Exception) {
                    result.error("GET_OBFUSCATE_KEY_FAILED", e.message, null)
                }
            } else if (call.method == "getServerUrlKey") {
                try {
                    result.success(getServerUrlKey())
                } catch (e: Exception) {
                    result.error("GET_SERVER_URL_KEY_FAILED", e.message, null)
                }
            } else if (call.method == "startMihomo") {
                val configPath = call.argument<String>("configPath")
                val vpnIntent = VpnService.prepare(this)
                if (vpnIntent != null) {
                    pendingConfigPath = configPath
                    pendingResult = result
                    startActivityForResult(vpnIntent, VPN_REQUEST_CODE)
                } else {
                    startVpnService(configPath)
                    result.success(null)
                }
            } else if (call.method == "start") {
                val configPath = call.argument<String>("configPath")
                val vpnIntent = VpnService.prepare(this)
                if (vpnIntent != null) {
                    pendingConfigPath = configPath
                    pendingResult = result
                    startActivityForResult(vpnIntent, VPN_REQUEST_CODE)
                } else {
                    startVpnService(configPath)
                    result.success(null)
                }
            } else if (call.method == "stopMihomo") {
                val intent = Intent(this, MihomoVpnService::class.java)
                stopService(intent)
                result.success(null)
            } else if (call.method == "stop") {
                val intent = Intent(this, MihomoVpnService::class.java)
                stopService(intent)
                result.success(null)
            } else if (call.method == "queryTunnelState") {
                try {
                    if (!MihomoManager.isRunning()) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val mode = MihomoManager.getModeFallback()
                    val json = """{"mode":"$mode"}"""
                    result.success(json)
                } catch (e: Exception) {
                    result.error("QUERY_FAILED", e.message, null)
                }
            } else if (call.method == "isMihomoRunning") {
                result.success(MihomoManager.isRunning())
            } else if (call.method == "isRunning") {
                result.success(MihomoManager.isRunning())
            } else if (call.method == "queryTrafficNow") {
                try {
                    val (up, down) = MihomoManager.getTraffic()
                    val source = MihomoManager.getTrafficSource()
                    result.success(mapOf("up" to up, "down" to down, "source" to source))
                } catch (e: Exception) {
                    result.error("QUERY_FAILED", e.message, null)
                }
            } else if (call.method == "queryGroupNames") {
                result.success("[]")
            } else if (call.method == "queryGroup") {
                result.success("{}")
            } else if (call.method == "patchSelector") {
                result.success(false)
            } else if (call.method == "urlTest") {
                val name = call.argument<String>("name")
                if (name.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENT", "name cannot be empty", null)
                } else {
                    Thread {
                        try {
                            val latency = MihomoManager.testLatency(name)
                            runOnUiThread {
                                result.success(latency)
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("TEST_LATENCY_FAILED", e.message, null)
                            }
                        }
                    }.start()
                }
            } else if (call.method == "reloadConfig") {
                val ok = MihomoVpnService.instance?.reloadConfig() ?: false
                result.success(ok)
            } else if (call.method == "setModeNative") {
                try {
                    val mode = (call.argument<String>("mode") ?: "rule").lowercase()
                    if (mode != "rule" && mode != "global" && mode != "direct") {
                        result.error("INVALID_MODE", "Invalid mode: $mode", null)
                        return@setMethodCallHandler
                    }
                    val success = MihomoManager.setMode(mode)
                    if (success) {
                        result.success(true)
                    } else {
                        result.error("SET_MODE_FAILED", "Failed to set mode: $mode", null)
                    }
                } catch (e: Exception) {
                    result.error("SET_MODE_FAILED", e.message, null)
                }
            } else if (call.method == "getModeNative") {
                try {
                    result.success(MihomoManager.getMode())
                } catch (e: Exception) {
                    result.error("GET_MODE_FAILED", e.message, null)
                }
            } else if (call.method == "getMode") {
                try {
                    result.success(MihomoManager.getMode())
                } catch (e: Exception) {
                    result.error("GET_MODE_FAILED", e.message, null)
                }
            } else if (call.method == "getProxies") {
                try {
                    val proxies = MihomoManager.getProxies()
                    result.success(proxies)
                } catch (e: Exception) {
                    result.error("GET_PROXIES_FAILED", e.message, null)
                }
            } else if (call.method == "changeMode") {
                try {
                    val mode = (call.argument<String>("mode") ?: "rule").lowercase()
                    if (mode != "rule" && mode != "global" && mode != "direct") {
                        result.error("INVALID_MODE", "Invalid mode: $mode", null)
                        return@setMethodCallHandler
                    }
                    val success = MihomoManager.setMode(mode)
                    if (success) {
                        result.success(true)
                    } else {
                        result.error("SET_MODE_FAILED", "Failed to set mode: $mode", null)
                    }
                } catch (e: Exception) {
                    result.error("SET_MODE_FAILED", e.message, null)
                }
            } else if (call.method == "selectProxy") {
                try {
                    val proxyName = if (call.arguments is String) {
                        call.arguments as String
                    } else {
                        call.argument<String>("name") ?: call.argument<String>("proxyName")
                    }
                    
                    if (proxyName.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "proxyName cannot be empty (arg: ${call.arguments})", null)
                        return@setMethodCallHandler
                    }
                    val success = MihomoManager.selectProxy(proxyName)
                    result.success(success)
                } catch (e: Exception) {
                    result.error("SELECT_PROXY_FAILED", e.message, null)
                }
            } else if (call.method == "selectProxyByGroup") {
                try {
                    val groupName = call.argument<String>("groupName")
                    val proxyName = call.argument<String>("name") ?: call.argument<String>("proxyName")
                    if (groupName.isNullOrBlank() || proxyName.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "groupName/proxyName cannot be empty", null)
                        return@setMethodCallHandler
                    }
                    val success = MihomoManager.selectProxy(groupName, proxyName)
                    result.success(success)
                } catch (e: Exception) {
                    result.error("SELECT_PROXY_FAILED", e.message, null)
                }
            } else if (call.method == "getSelectedProxy") {
                val groupName = call.argument<String>("groupName")
                if (groupName.isNullOrBlank()) {
                     result.error("INVALID_ARGUMENT", "groupName cannot be empty", null)
                } else {
                     result.success(MihomoManager.getSelectedProxy(groupName))
                }
            } else if (call.method == "getSelectedProxyInfo") {
                val groupName = call.argument<String>("groupName")
                if (groupName.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENT", "groupName cannot be empty", null)
                } else {
                    result.success(MihomoManager.getSelectedProxyInfo(groupName))
                }
            } else if (call.method == "patchOverride") {
                val mode = call.argument<String>("mode")
                if (mode.isNullOrBlank()) {
                    result.error("INVALID_MODE", "Invalid mode: $mode", null)
                } else {
                    result.success(MihomoManager.setMode(mode))
                }
            } else if (call.method == "queryProviders") {
                result.success("{}")
            } else if (call.method == "updateNotification") {
                val content = call.argument<String>("content")
                if (content != null) {
                    MihomoVpnService.instance?.updateNotification(content)
                    result.success(true)
                } else {
                    result.error("INVALID_ARGUMENT", "Content cannot be null", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == RESULT_OK) {
                startVpnService(pendingConfigPath)
                pendingResult?.success(null)
            } else {
                pendingResult?.error("VPN_PERMISSION_DENIED", "User denied VPN permission", null)
            }
            pendingResult = null
            pendingConfigPath = null
        } else {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    private fun startVpnService(configPath: String?) {
        // Fix Path Traversal Risk
        if (configPath != null) {
            val file = File(configPath)
            if (!file.canonicalPath.startsWith(filesDir.canonicalPath)) {
                // Potential path traversal attack
                return
            }
        }

        val intent = Intent(this, MihomoVpnService::class.java).apply {
            putExtra("configPath", configPath)
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (e: Exception) {
            // Log removed to prevent leakage
        }
    }

    private fun hotUpdateRootDir(): File {
        return File(filesDir, "hot_update")
    }

    private fun hotUpdateBundleRootDir(): File {
        return File(hotUpdateRootDir(), "runtime_bundle")
    }

    private fun legacyHotUpdateRootDir(): File {
        return hotUpdateRootDir()
    }

    private fun hotUpdateCurrentDir(): File {
        return File(hotUpdateBundleRootDir(), "current")
    }

    private fun legacyHotUpdateCurrentDir(): File {
        return File(legacyHotUpdateRootDir(), "current")
    }

    private fun shouldUseHotUpdateBundle(): Boolean {
        return !isDebuggableBuild()
    }

    private fun hotUpdateLog(message: String) {
        Log.d(HOT_UPDATE_TAG, message)
    }

    private fun isDebuggableBuild(): Boolean {
        return (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    }

    private fun previewDirectory(root: File, limit: Int = 30): String {
        if (!root.exists()) {
            return "<missing>"
        }
        val entries = root.walkTopDown()
            .filter { it != root }
            .take(limit)
            .map {
                val relative = it.relativeTo(root).path.replace(File.separatorChar, '/')
                if (it.isDirectory) "$relative/" else relative
            }
            .toList()
        if (entries.isEmpty()) {
            return "<empty>"
        }
        return entries.joinToString(" | ")
    }

    private fun logHotUpdateState(stage: String) {
        val writableCurrent = hotUpdateCurrentDir()
        val legacyCurrent = legacyHotUpdateCurrentDir()
        val selectedCurrent = resolveReadableHotUpdateCurrentDir()
        val bundleDir = resolveHotUpdateBundleDir()
        val libFile = resolveHotUpdateLibFile()
        val selectedAssetsDir = bundleDir ?: File(writableCurrent, "flutter_assets")
        val manifestBin = File(selectedAssetsDir, "AssetManifest.bin")
        val manifestJson = File(selectedAssetsDir, "AssetManifest.json")
        val kernelBlob = File(selectedAssetsDir, "kernel_blob.bin")
        val vmSnapshot = File(selectedAssetsDir, "vm_snapshot_data")
        val isolateSnapshot = File(selectedAssetsDir, "isolate_snapshot_data")
        hotUpdateLog(
            "$stage writableCurrent=${writableCurrent.absolutePath} exists=${writableCurrent.exists()} " +
                "legacyCurrent=${legacyCurrent.absolutePath} exists=${legacyCurrent.exists()} " +
                "debuggable=${isDebuggableBuild()} " +
                "selectedCurrent=${selectedCurrent?.absolutePath ?: "<null>"} " +
                "bundleDir=${bundleDir?.absolutePath ?: "<null>"} " +
                "lib=${libFile?.absolutePath ?: "<null>"}"
        )
        hotUpdateLog(
            "$stage manifestBin=${manifestBin.absolutePath} exists=${manifestBin.exists()} " +
                "manifestJson=${manifestJson.absolutePath} exists=${manifestJson.exists()} " +
                "kernelBlob=${kernelBlob.exists()} vmSnapshot=${vmSnapshot.exists()} " +
                "isolateSnapshot=${isolateSnapshot.exists()} " +
                "selectedPreview=${selectedCurrent?.let { previewDirectory(it) } ?: "<null>"}"
        )
    }

    private fun isValidHotUpdateBundle(currentDir: File): Boolean {
        val assetsDir = File(currentDir, "flutter_assets")
        val libappFile = File(currentDir, "libapp.so")
        val assetManifestBin = File(assetsDir, "AssetManifest.bin")
        val assetManifestJson = File(assetsDir, "AssetManifest.json")
        val hasAssetManifest = assetManifestBin.isFile || assetManifestJson.isFile
        if (!assetsDir.isDirectory || !hasAssetManifest) {
            return false
        }
        return libappFile.isFile && hasEnoughHotUpdateAssets(assetsDir)
    }

    private fun hasEnoughHotUpdateAssets(assetsDir: File, minCount: Int = 1): Boolean {
        val markerNames = setOf(
            "AssetManifest.bin",
            "AssetManifest.bin.json",
            "AssetManifest.json",
            "FontManifest.json",
            "NativeAssetsManifest.json",
            "NOTICES.Z",
        )
        var count = 0
        for (file in assetsDir.walkTopDown()) {
            if (!file.isFile) {
                continue
            }
            if (markerNames.contains(file.name)) {
                continue
            }
            count += 1
            if (count >= minCount) {
                return true
            }
        }
        return false
    }

    private fun resolveReadableHotUpdateCurrentDir(): File? {
        val candidates = listOf(
            hotUpdateCurrentDir(),
            legacyHotUpdateCurrentDir(),
        )
        return candidates.firstOrNull { isValidHotUpdateBundle(it) }
    }

    private fun resolveHotUpdateBundleDir(): File? {
        val currentDir = resolveReadableHotUpdateCurrentDir() ?: return null
        return File(currentDir, "flutter_assets")
    }

    private fun resolveHotUpdateLibFile(): File? {
        val currentDir = resolveReadableHotUpdateCurrentDir() ?: return null
        val libappFile = File(currentDir, "libapp.so")
        return libappFile.takeIf { it.isFile }
    }

    private fun replaceDirectory(sourceDir: File, targetDir: File): Boolean {
        if (!sourceDir.exists()) {
            return false
        }
        if (targetDir.exists()) {
            targetDir.deleteRecursively()
        }
        targetDir.parentFile?.mkdirs()
        if (sourceDir.renameTo(targetDir)) {
            return true
        }
        sourceDir.copyRecursively(targetDir, overwrite = true)
        sourceDir.deleteRecursively()
        return true
    }

    private fun normalizeHotUpdatePermissions(currentDir: File) {
        File(currentDir, "libapp.so").apply {
            if (isFile) {
                setReadable(true, false)
                setExecutable(true, false)
            }
        }
    }

    private fun migrateLegacyCurrentIfNeeded() {
        val legacyCurrentDir = legacyHotUpdateCurrentDir()
        val currentDir = hotUpdateCurrentDir()
        if (currentDir.exists() || !legacyCurrentDir.exists()) {
            return
        }
        if (replaceDirectory(legacyCurrentDir, currentDir)) {
            normalizeHotUpdatePermissions(currentDir)
        }
    }

    private fun activatePendingHotUpdate() {
        try {
            val bundleRoot = hotUpdateBundleRootDir()
            if (!bundleRoot.exists()) {
                bundleRoot.mkdirs()
            }
            val pendingDir = File(bundleRoot, "pending")
            if (replaceDirectory(pendingDir, hotUpdateCurrentDir())) {
                normalizeHotUpdatePermissions(hotUpdateCurrentDir())
                hotUpdateLog("activatePendingHotUpdate activated writable pending=${pendingDir.absolutePath}")
                return
            }
            val legacyPendingDir = File(legacyHotUpdateRootDir(), "pending")
            if (replaceDirectory(legacyPendingDir, hotUpdateCurrentDir())) {
                normalizeHotUpdatePermissions(hotUpdateCurrentDir())
                hotUpdateLog("activatePendingHotUpdate migrated legacy pending=${legacyPendingDir.absolutePath}")
                return
            }
            migrateLegacyCurrentIfNeeded()
            hotUpdateLog(
                "activatePendingHotUpdate no pending writablePreview=${previewDirectory(bundleRoot)} " +
                    "legacyPreview=${previewDirectory(legacyHotUpdateRootDir())}"
            )
        } catch (_: Exception) {
        }
    }

    // copyAssetToFiles is no longer needed for mihomo, but kept if other assets need it
    private fun copyAssetToFiles(assetName: String, fileName: String) {
        // Fix Path Traversal Risk
        if (fileName.contains("..") || fileName.contains("/") || fileName.contains("\\")) {
            return
        }
        
        val file = File(filesDir, fileName)
        if (!file.canonicalPath.startsWith(filesDir.canonicalPath)) {
             return
        }

        if (!file.exists()) {
             assets.open(assetName).use { input ->
                 file.outputStream().use { output ->
                     input.copyTo(output)
                 }
             }
             // Fix Permission Risk: Only set executable for specific binaries if absolutely needed
             if (fileName == "mihomo" || fileName.endsWith(".so")) {
                 file.setExecutable(true)
             }
        } else {
             // Ensure executable even if exists
             if (fileName == "mihomo" || fileName.endsWith(".so")) {
                 file.setExecutable(true)
             }
        }
    }

    private fun exportBundledFlutterAssets(destinationPath: String) {
        val destinationDir = File(destinationPath)
        val canonicalDestination = destinationDir.canonicalFile
        val dataRoot = File(applicationInfo.dataDir).canonicalFile
        if (!canonicalDestination.path.startsWith(dataRoot.path)) {
            throw IllegalArgumentException("destination out of sandbox")
        }
        if (canonicalDestination.exists()) {
            canonicalDestination.deleteRecursively()
        }
        canonicalDestination.mkdirs()
        if (exportBundledFlutterAssetsFromInstalledApks(canonicalDestination)) {
            return
        }
        copyAssetDirectory("flutter_assets", canonicalDestination)
    }

    private fun exportBundledFlutterAssetsFromInstalledApks(destinationDir: File): Boolean {
        val apkPaths = LinkedHashSet<String>()
        applicationInfo.sourceDir?.let { apkPaths.add(it) }
        applicationInfo.splitSourceDirs?.forEach { path ->
            if (!path.isNullOrBlank()) {
                apkPaths.add(path)
            }
        }

        var copiedFiles = 0
        for (apkPath in apkPaths) {
            val apkFile = File(apkPath)
            if (!apkFile.isFile) {
                continue
            }
            ZipFile(apkFile).use { zipFile ->
                val entries = zipFile.entries()
                while (entries.hasMoreElements()) {
                    val entry = entries.nextElement()
                    val entryName = entry.name
                    if (!entryName.startsWith("assets/flutter_assets/")) {
                        continue
                    }
                    val relativePath = entryName.removePrefix("assets/flutter_assets/")
                    if (relativePath.isEmpty()) {
                        continue
                    }
                    val destinationFile = File(destinationDir, relativePath)
                    if (entry.isDirectory) {
                        destinationFile.mkdirs()
                        continue
                    }
                    destinationFile.parentFile?.mkdirs()
                    zipFile.getInputStream(entry).use { input ->
                        destinationFile.outputStream().use { output ->
                            input.copyTo(output)
                        }
                    }
                    copiedFiles += 1
                }
            }
        }
        return copiedFiles > 0
    }

    private fun copyAssetDirectory(assetPath: String, destinationDir: File) {
        val children = assets.list(assetPath) ?: return
        for (child in children) {
            val childAssetPath = "$assetPath/$child"
            val grandChildren = assets.list(childAssetPath)
            if (grandChildren != null && grandChildren.isNotEmpty()) {
                val childDestinationDir = File(destinationDir, child)
                childDestinationDir.mkdirs()
                copyAssetDirectory(childAssetPath, childDestinationDir)
                continue
            }

            val destinationFile = File(destinationDir, child)
            destinationFile.parentFile?.mkdirs()
            try {
                assets.open(childAssetPath).use { input ->
                    destinationFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
            } catch (_: Exception) {
                if (destinationFile.exists()) {
                    destinationFile.delete()
                }
                destinationFile.mkdirs()
            }
        }
    }
}
