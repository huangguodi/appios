package com.accelerator.tg

import android.util.Log
import mobile.Mobile
import org.json.JSONObject

object MihomoManager {
    private const val TAG = "MihomoManager"
    @Volatile
    private var isRunning: Boolean = false
    @Volatile
    private var currentMode: String = "rule"
    @Volatile
    private var lastTrafficSource: String = "none"

    private fun logMobileApiSnapshot(scene: String) {
        try {
            val methods = Mobile::class.java.declaredMethods
                .map { "${it.name}(${it.parameterTypes.joinToString(",") { p -> p.simpleName }})" }
                .sorted()
                .joinToString("; ")
            Log.e(TAG, "$scene api snapshot: $methods")
        } catch (e: Exception) {
            Log.e(TAG, "$scene api snapshot failed", e)
        }
    }

    fun start(configDir: String): Boolean {
        return try {
            Mobile.start(configDir, "config.yaml")
            isRunning = true
            true
        } catch (e: Throwable) {
            Log.e(TAG, "start failed", e)
            logMobileApiSnapshot("start")
            false
        }
    }

    fun stop() {
        try {
            Mobile.stop()
        } catch (e: Throwable) {
            Log.e(TAG, "stop failed", e)
        } finally {
            isRunning = false
        }
    }

    fun reloadConfig(): Boolean {
        return try {
            Mobile.forceUpdateConfig("config.yaml")
            true
        } catch (e: Throwable) {
            Log.e(TAG, "reloadConfig failed", e)
            logMobileApiSnapshot("reloadConfig")
            false
        }
    }

    fun getTraffic(): Pair<Long, Long> {
        return try {
            val up = Mobile.trafficUp()
            val down = Mobile.trafficDown()
            lastTrafficSource = "trafficUp/trafficDown"
            Pair(up, down)
        } catch (_: Throwable) {
            lastTrafficSource = "none"
            Pair(0L, 0L)
        }
    }

    fun getTrafficSource(): String {
        return lastTrafficSource
    }

    fun isRunning(): Boolean {
        return isRunning
    }

    fun setMode(mode: String): Boolean {
        val normalized = mode.trim()
        val candidates = linkedSetOf(
            normalized,
            normalized.lowercase(),
            normalized.uppercase(),
            normalized.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }
        )

        for (candidate in candidates) {
            try {
                Mobile.setMode(candidate)
                val actual = getMode()
                val success = actual.equals(normalized, ignoreCase = true)
                Log.i(TAG, "setMode mode=$normalized candidate=$candidate success=$success currentMode=$actual")
                if (success) {
                    currentMode = actual.lowercase()
                    return true
                }
                Log.w(TAG, "setMode mode=$normalized candidate=$candidate success=false currentMode=$actual expected=$normalized")
            } catch (e: Throwable) {
                Log.w(TAG, "setMode mode=$normalized candidate=$candidate success=false currentMode=${getModeFallback()} error=${e.message}")
            }
        }

        Log.e(TAG, "setMode mode=$normalized success=false currentMode=${getModeFallback()}")
        logMobileApiSnapshot("setMode")
        return false
    }

    fun getModeFallback(): String {
        return currentMode
    }

    fun getMode(): String {
        val raw = Mobile.getMode().trim()
        if (raw.isEmpty()) {
            throw IllegalStateException("native getMode returned empty")
        }
        currentMode = raw.lowercase()
        return currentMode
    }

    fun getProxies(): String {
        return try {
            Mobile.getProxies()
        } catch (e: Throwable) {
            Log.e(TAG, "getProxies failed", e)
            "{}"
        }
    }

    fun selectProxy(proxyName: String): Boolean {
        return selectProxy("GLOBAL", proxyName)
    }

    fun selectProxy(groupName: String, proxyName: String): Boolean {
        val normalizedGroup = groupName.trim()
        if (normalizedGroup.isEmpty()) {
            return false
        }
        try {
            Log.i(TAG, "selectProxy: Requesting switch to $proxyName in group $normalizedGroup")
            
            Mobile.selectProxy(normalizedGroup, proxyName)
            
            Thread.sleep(50)
            
            val current = getSelectedProxy(normalizedGroup)
            if (current != null && current == proxyName) {
                Log.i(TAG, "selectProxy: Successfully verified switch to $proxyName")
                return true
            }
            
            Log.w(TAG, "selectProxy: Verification failed. Expected $proxyName, got $current")
            return true
        } catch (e: Throwable) {
            Log.e(TAG, "selectProxy failed group=$normalizedGroup proxy=$proxyName", e)
            return false
        }
    }

    fun getSelectedProxy(groupName: String): String? {
        return try {
            val proxiesJson = Mobile.getProxies()
            // Lightweight parsing: Find "GLOBAL" group then "now" field
            // Pattern: "GLOBAL": { ... "now": "Value" ... }
            
            val groupKey = "\"$groupName\":"
            val groupPos = proxiesJson.indexOf(groupKey)
            if (groupPos == -1) return null
            
            val nowPos = proxiesJson.indexOf("\"now\":", groupPos)
            if (nowPos == -1) return null
            
            // Extract value: find next quote after "now":
            val valueStart = proxiesJson.indexOf("\"", nowPos + 6)
            if (valueStart == -1) return null
            
            val valueEnd = proxiesJson.indexOf("\"", valueStart + 1)
            if (valueEnd == -1) return null
            
            proxiesJson.substring(valueStart + 1, valueEnd)
        } catch (e: Throwable) {
            Log.e(TAG, "getSelectedProxy failed group=$groupName", e)
            null
        }
    }

    fun getSelectedProxyInfo(groupName: String): Map<String, Any>? {
        return try {
            val proxiesJson = Mobile.getProxies()
            val root = JSONObject(proxiesJson)
            val proxies = root.optJSONObject("proxies") ?: return null
            val group = proxies.optJSONObject(groupName) ?: return null
            val selectedName = group.optString("now").trim()
            if (selectedName.isEmpty()) {
                return null
            }
            val node = proxies.optJSONObject(selectedName)
            val type = node?.optString("type")?.trim().orEmpty().ifEmpty { "Unknown" }
            val country = node?.optString("country")?.trim().orEmpty().ifEmpty { "Unknown" }
            val udp = node?.optBoolean("udp", false) ?: false
            mapOf(
                "name" to selectedName,
                "type" to type,
                "country" to country,
                "udp" to udp,
            )
        } catch (e: Throwable) {
            Log.e(TAG, "getSelectedProxyInfo failed group=$groupName", e)
            null
        }
    }

    fun testLatency(proxyName: String): String {
        return try {
            Mobile.testLatency(proxyName)
        } catch (e: Throwable) {
            Log.e(TAG, "testLatency failed proxy=$proxyName", e)
            ""
        }
    }
}
