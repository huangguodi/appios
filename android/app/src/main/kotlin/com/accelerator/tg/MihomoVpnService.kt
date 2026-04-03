package com.accelerator.tg

import android.content.Intent
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.net.VpnService
import android.os.Build
import android.util.Log
import android.content.pm.ServiceInfo
import java.io.File

import mobile.Mobile
import mobile.SocketProtector

class MihomoVpnService : VpnService() {
    companion object {
        var instance: MihomoVpnService? = null
        var logCallback: ((String) -> Unit)? = null
        private const val ENABLE_IPV6_ROUTE = false
    }

    private var currentConfigPath: String? = null
    private var socketProtector: SocketProtector? = null

    private fun logToFlutter(message: String) {
        Log.e("MihomoVpnService", message)
        logCallback?.invoke("MihomoVpnService: $message")
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        logToFlutter("onCreate called")
    }

    override fun onDestroy() {
        super.onDestroy()
        instance = null
        stopMihomo()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val configPath = intent?.getStringExtra("configPath")

        if (configPath != null) {
            currentConfigPath = configPath
        }

        logToFlutter("onStartCommand called with config: $configPath")

        if (configPath != null) {
            startForegroundServiceNotification()
            startMihomo(configPath)
        } else {
            logToFlutter("Missing config path")
            stopSelf()
        }

        return START_STICKY
    }
    
    private fun stopMihomo() {
        logToFlutter("Stopping Mihomo")
        clearSocketProtector()
        MihomoManager.stop()
    }

    private fun startForegroundServiceNotification() {
        val channelId = "mihomo_vpn_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(channelId, "Mihomo VPN Service", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }

        val notification: Notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
                .setContentTitle("加速器 VPN")
                .setContentText("加速服务运行中")
                .setSmallIcon(R.mipmap.ic_launcher)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
        } else {
            Notification.Builder(this)
                .setContentTitle("加速器 VPN")
                .setContentText("加速服务运行中")
                .setSmallIcon(R.mipmap.ic_launcher)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
        }

        if (Build.VERSION.SDK_INT >= 34) {
             try {
                startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
             } catch (e: Exception) {
                logToFlutter("Failed to start FGS with type: ${e.message}")
                startForeground(1, notification)
             }
        } else {
             startForeground(1, notification)
        }
    }

    fun updateNotification(content: String) {
        val channelId = "mihomo_vpn_channel"
        val notificationManager = getSystemService(NotificationManager::class.java)
        
        val notification: Notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
                .setContentTitle("加速器 VPN")
                .setContentText(content)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setOngoing(true)
                .setOnlyAlertOnce(true) // Prevent sound/vibration on update
                .build()
        } else {
            Notification.Builder(this)
                .setContentTitle("加速器 VPN")
                .setContentText(content)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
        }
        
        notificationManager.notify(1, notification)
    }

    fun reloadConfig(): Boolean {
        try {
            val ok = MihomoManager.reloadConfig()
            if (ok) {
                logToFlutter("Config reloaded successfully")
            } else {
                logToFlutter("Failed to reload config")
            }
            return ok
        } catch (e: Exception) {
            logToFlutter("Failed to reload config: ${e.message}")
            return false
        }
    }

    private fun startMihomo(configPath: String) {
        stopMihomo()
        Thread {
            try {
                logToFlutter("Starting Mihomo Core...")
                val configDir = File(configPath).parent ?: configPath
                val tunFd = establishTunFd()
                if (tunFd == null) {
                    logToFlutter("Failed to establish VPN interface")
                    stopMihomo()
                    stopSelf()
                    return@Thread
                }
                val injected = injectTunConfig(configPath, tunFd)
                if (!injected) {
                    logToFlutter("Failed to inject tun config")
                    stopMihomo()
                    stopSelf()
                    return@Thread
                }
                if (!registerSocketProtector()) {
                    logToFlutter("Failed to register socket protector")
                    stopMihomo()
                    stopSelf()
                    return@Thread
                }
                val success = MihomoManager.start(configDir)

                if (!success) {
                    logToFlutter("Failed to start Mihomo core")
                    clearSocketProtector()
                    stopSelf()
                    return@Thread
                }
                logToFlutter("Mihomo Core started.")
            } catch (e: Exception) {
                logToFlutter("Error starting Mihomo: ${e.message}")
                clearSocketProtector()
                stopSelf()
            }
        }.start()
    }

    private fun registerSocketProtector(): Boolean {
        return try {
            val protector = object : SocketProtector {
                override fun protectSocket(fd: Long, network: String?, address: String?): Boolean {
                    return try {
                        protect(fd.toInt())
                    } catch (_: Exception) {
                        false
                    }
                }

                override fun markSocket(fd: Long, network: String?, address: String?): Boolean {
                    return true
                }
            }
            Mobile.setSocketProtector(protector)
            socketProtector = protector
            logToFlutter("Socket protector registered")
            true
        } catch (e: Throwable) {
            logToFlutter("Socket protector register failed: ${e.message}")
            false
        }
    }

    private fun clearSocketProtector() {
        try {
            Mobile.clearSocketProtector()
            socketProtector = null
            logToFlutter("Socket protector cleared")
        } catch (_: Throwable) {
            socketProtector = null
        }
    }

    private fun establishTunFd(): Int? {
        return try {
            val builder = Builder()
                .setSession("Accelerator VPN")
                .setMtu(1400)
                .addAddress("172.19.0.1", 30)
                .addDnsServer("1.1.1.1")
                .addDnsServer("8.8.8.8")
                .addRoute("0.0.0.0", 0)

            if (ENABLE_IPV6_ROUTE) {
                try {
                    builder
                        .addAddress("fdfe:dcba:9876::1", 126)
                        .addDnsServer("2001:4860:4860::8888")
                        .addDnsServer("2606:4700:4700::1111")
                        .addRoute("::", 0)
                    logToFlutter("IPv6 route enabled")
                } catch (e: Exception) {
                    logToFlutter("IPv6 route setup failed: ${e.message}")
                }
            } else {
                logToFlutter("IPv6 route disabled for stability")
            }

            try {
                builder.addDisallowedApplication(packageName)
            } catch (_: Exception) {
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }

            val tun = builder.establish() ?: return null
            val fd = tun.detachFd()
            logToFlutter("VPN interface established with fd=$fd")
            fd
        } catch (e: Exception) {
            logToFlutter("Establish VPN failed: ${e.message}")
            null
        }
    }

    private fun injectTunConfig(configPath: String, fd: Int): Boolean {
        try {
            val configFile = if (configPath.endsWith("config.yaml")) {
                File(configPath)
            } else {
                File(configPath, "config.yaml")
            }
            if (!configFile.exists()) {
                logToFlutter("Config file not found for tun injection")
                return false
            }
            val content = configFile.readText()
            val tunBlock = buildTunBlock(fd)
            val patched = if (Regex("(?m)^tun:\\s*$").containsMatchIn(content)) {
                replaceTunBlock(content, tunBlock)
            } else {
                content.trimEnd() + "\n\n" + tunBlock + "\n"
            }
            configFile.writeText(patched)
            logToFlutter("Tun config injected")
            return true
        } catch (e: Exception) {
            logToFlutter("Tun config injection failed: ${e.message}")
            return false
        }
    }

    private fun buildTunBlock(fd: Int): String {
        return """
tun:
  enable: true
  stack: gvisor
  file-descriptor: $fd
  auto-route: false
  auto-detect-interface: false
  auto-redirect: false
  mtu: 1400
  dns-hijack:
    - 0.0.0.0:53
    - "[::]:53"
""".trimIndent()
    }

    private fun replaceTunBlock(content: String, tunBlock: String): String {
        val lines = content.lines()
        val out = ArrayList<String>(lines.size + 16)
        var i = 0
        var replaced = false
        while (i < lines.size) {
            val line = lines[i]
            val trimmedLine = line.trim()
            val isTopLevelTunLine = !line.startsWith(" ") && !line.startsWith("\t") && trimmedLine.startsWith("tun:")
            if (!replaced && isTopLevelTunLine) {
                out.addAll(tunBlock.lines())
                replaced = true
                i++
                while (i < lines.size) {
                    val next = lines[i]
                    if (next.isNotBlank() && !next.startsWith(" ") && !next.startsWith("\t")) {
                        break
                    }
                    i++
                }
                continue
            }
            out.add(line)
            i++
        }
        return out.joinToString("\n")
    }
}
