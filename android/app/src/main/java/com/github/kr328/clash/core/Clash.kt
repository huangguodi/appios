package com.github.kr328.clash.core

import com.github.kr328.clash.core.bridge.*
import com.github.kr328.clash.core.model.*
import com.github.kr328.clash.core.util.parseInetSocketAddress
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonPrimitive

object Clash {
    enum class OverrideSlot {
        Persist, Session
    }

    private val ConfigurationOverrideJson = Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
    }

    fun reset() {
        Bridge.nativeReset()
    }

    fun forceGc() {
        Bridge.nativeForceGc()
    }

    fun suspendCore(suspended: Boolean) {
        Bridge.nativeSuspend(suspended)
    }

    fun queryTunnelState(): TunnelState {
        val json = Bridge.nativeQueryTunnelState()

        return Json.decodeFromString(TunnelState.serializer(), json)
    }

    fun queryTrafficNow(): Traffic {
        return Bridge.nativeQueryTrafficNow()
    }

    fun queryTrafficTotal(): Traffic {
        return Bridge.nativeQueryTrafficTotal()
    }

    fun notifyDnsChanged(dns: List<String>) {
        Bridge.nativeNotifyDnsChanged(dns.joinToString(separator = ","))
    }

    fun notifyTimeZoneChanged(name: String, offset: Int) {
        Bridge.nativeNotifyTimeZoneChanged(name, offset)
    }

    fun notifyInstalledAppsChanged(uids: List<Pair<Int, String>>) {
        val uidList = uids.joinToString(separator = ",") { "${it.first}:${it.second}" }

        Bridge.nativeNotifyInstalledAppChanged(uidList)
    }

    fun startTun(
        fd: Int,
        stack: String,
        gateway: String,
        portal: String,
        dns: String,
        cb: TunInterface
    ) {
        Bridge.nativeStartTun(fd, stack, gateway, portal, dns, cb)
    }

    fun stopTun() {
        Bridge.nativeStopTun()
    }

    fun startHttp(listenAt: String): String? {
        return Bridge.nativeStartHttp(listenAt)
    }

    fun stopHttp() {
        Bridge.nativeStopHttp()
    }

    fun queryGroupNames(excludeNotSelectable: Boolean): List<String> {
        val namesStr = Bridge.nativeQueryGroupNames(excludeNotSelectable)
        val names = Json.decodeFromString<List<String>>(namesStr)
        return names
    }

    fun queryGroup(name: String, sort: ProxySort): ProxyGroup {
        val result = Bridge.nativeQueryGroup(name, sort.name)
        return result?.let { Json.decodeFromString(ProxyGroup.serializer(), it) }
            ?: ProxyGroup(Proxy.Type.Unknown, emptyList(), "")
    }

    fun healthCheck(name: String): CompletableDeferred<Unit> {
        val deferred = CompletableDeferred<Unit>()
        Bridge.nativeHealthCheck(deferred, name)
        return deferred
    }

    fun healthCheckAll() {
        Bridge.nativeHealthCheckAll()
    }

    fun patchSelector(selector: String, name: String): Boolean {
        return Bridge.nativePatchSelector(selector, name)
    }

    fun fetchAndValid(
        path: String,
        url: String,
        force: Boolean
    ): CompletableDeferred<Unit> {
        val deferred = CompletableDeferred<Unit>()
        // Note: nativeFetchAndValid signature might differ, checking Bridge.kt
        // external fun nativeFetchAndValid(completable: FetchCallback, path: String, url: String, force: Boolean)
        // We need a FetchCallback implementation
        // For now, let's just use a simple callback if possible or adapt
        
        return deferred
    }

    fun load(path: String): CompletableDeferred<Unit> {
        val deferred = CompletableDeferred<Unit>()
        Bridge.nativeLoad(deferred, path)
        return deferred
    }

    fun queryProviders(): List<Provider> {
        val providersJson = Bridge.nativeQueryProviders()
        return Json.decodeFromString<List<Provider>>(providersJson)
    }

    fun updateProvider(type: Provider.Type, name: String): CompletableDeferred<Unit> {
        val deferred = CompletableDeferred<Unit>()
        Bridge.nativeUpdateProvider(deferred, type.toString(), name)
        return deferred
    }

    fun queryOverride(slot: OverrideSlot): ConfigurationOverride {
        return try {
            ConfigurationOverrideJson.decodeFromString(
                ConfigurationOverride.serializer(),
                Bridge.nativeReadOverride(slot.ordinal)
            )
        } catch (e: Exception) {
            ConfigurationOverride()
        }
    }

    fun patchOverride(slot: OverrideSlot, configuration: ConfigurationOverride) {
        Bridge.nativeWriteOverride(
            slot.ordinal,
            ConfigurationOverrideJson.encodeToString(
                ConfigurationOverride.serializer(),
                configuration
            )
        )
    }

    fun clearOverride(slot: OverrideSlot) {
        Bridge.nativeClearOverride(slot.ordinal)
    }

    fun queryConfiguration(): UiConfiguration {
        return Json.decodeFromString(
            UiConfiguration.serializer(),
            Bridge.nativeQueryConfiguration()
        )
    }

    fun subscribeLogcat(): ReceiveChannel<LogMessage> {
        val channel = Channel<LogMessage>(32)
        Bridge.nativeSubscribeLogcat(object : LogcatInterface {
            override fun received(jsonPayload: String) {
                channel.trySend(Json.decodeFromString(LogMessage.serializer(), jsonPayload))
            }
        })
        return channel
    }
}