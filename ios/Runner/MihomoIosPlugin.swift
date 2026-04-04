import Flutter
import Foundation
import NetworkExtension

final class MihomoIosPlugin {
  static let shared = MihomoIosPlugin()
  private enum AppConfigKey {
    static let appGroupId = "IOSAppGroupIdentifier"
    static let packetTunnelBundleId = "IOSPacketTunnelBundleIdentifier"
  }

  private let managerQueue = DispatchQueue(label: "com.accelerator.tg.mihomo.vpn.manager")
  private weak var registeredController: FlutterViewController?

  private init() {}

  private var mainBundleId: String {
    let bundleId = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (bundleId?.isEmpty == false) ? bundleId! : "app.bundle"
  }

  private var tunnelBundleId: String {
    configValue(for: AppConfigKey.packetTunnelBundleId) ?? "\(mainBundleId).packettunnel"
  }

  private var appGroupId: String {
    configValue(for: AppConfigKey.appGroupId) ?? "group.\(mainBundleId)"
  }

  func register(with controller: FlutterViewController) {
    if registeredController === controller {
      return
    }
    registeredController = controller
    let mihomoChannel = FlutterMethodChannel(
      name: "com.accelerator.tg/mihomo",
      binaryMessenger: controller.binaryMessenger
    )
    mihomoChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "UNAVAILABLE", message: "plugin released", details: nil))
        return
      }
      self.handleMihomoCall(call, result: result)
    }

    let securityChannel = FlutterMethodChannel(
      name: "com.accelerator.tg/security",
      binaryMessenger: controller.binaryMessenger
    )
    securityChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "isDebuggerAttached":
        result(false)
      case "isAppDebuggable":
        result(false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let trafficChannel = FlutterEventChannel(
      name: "com.accelerator.tg/mihomo/traffic",
      binaryMessenger: controller.binaryMessenger
    )
    trafficChannel.setStreamHandler(TrafficStreamHandler(plugin: self))
  }

  private func handleMihomoCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      guard
        let args = call.arguments as? [String: Any],
        let configPath = args["configPath"] as? String,
        !configPath.isEmpty
      else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "configPath is empty", details: nil))
        return
      }
      let homeDir = (configPath as NSString).deletingLastPathComponent
      startVpn(homeDir: homeDir, configFileName: "config.yaml") { error, sessionId in
        if let error {
          result(FlutterError(code: "START_FAILED", message: error, details: nil))
        } else {
          result([
            "sessionId": sessionId ?? ""
          ])
        }
      }

    case "stop":
      stopVpn { _ in
        result(nil)
      }

    case "isRunning":
      loadManager { manager in
        let sharedState = self.readSharedState()
        guard let manager else {
          result(sharedState?.running ?? false)
          return
        }
        let status = manager.connection.status
        let running = status == .connected || status == .connecting || status == .reasserting
        result(running || (sharedState?.running ?? false))
      }

    case "getMode":
      let mode = readSharedState()?.mode ?? ""
      result(mode)

    case "getProxies":
      let proxies = readSharedState()?.proxies
      result((proxies?.isEmpty == false) ? proxies : "{}")

    case "getSelectedProxy":
      guard
        let args = call.arguments as? [String: Any],
        let groupName = args["groupName"] as? String,
        !groupName.isEmpty
      else {
        result(nil)
        return
      }
      let selected = readSharedState()?.selectedProxyByGroup[groupName]
      result((selected?.isEmpty == false) ? selected : nil)

    case "selectProxy":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "args missing", details: nil))
        return
      }
      let proxyName = (args["name"] as? String) ?? (args["proxyName"] as? String) ?? ""
      let groupName = (args["groupName"] as? String) ?? "GLOBAL"
      guard !proxyName.isEmpty else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "proxyName cannot be empty", details: nil))
        return
      }
      let payload = ProviderSelectProxy(groupName: groupName, name: proxyName)
      guard let data = try? JSONEncoder().encode(payload),
            let params = String(data: data, encoding: .utf8)
      else {
        result(FlutterError(code: "ENCODE_FAILED", message: "encode params failed", details: nil))
        return
      }
      sendProviderMessage(id: "selectProxy", params: params) { response in
        result(response?.data == "true")
      }

    case "selectProxyByGroup":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "args missing", details: nil))
        return
      }
      let proxyName = (args["name"] as? String) ?? ""
      let groupName = (args["groupName"] as? String) ?? "GLOBAL"
      guard !proxyName.isEmpty else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "name cannot be empty", details: nil))
        return
      }
      let payload = ProviderSelectProxy(groupName: groupName, name: proxyName)
      guard let data = try? JSONEncoder().encode(payload),
            let params = String(data: data, encoding: .utf8)
      else {
        result(FlutterError(code: "ENCODE_FAILED", message: "encode params failed", details: nil))
        return
      }
      sendProviderMessage(id: "selectProxy", params: params) { response in
        result(response?.data == "true")
      }

    case "changeMode":
      guard
        let args = call.arguments as? [String: Any],
        let mode = args["mode"] as? String,
        !mode.isEmpty
      else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "mode is empty", details: nil))
        return
      }
      sendProviderMessage(id: "setMode", params: mode) { response in
        result(response?.data == "true")
      }

    case "urlTest":
      guard
        let args = call.arguments as? [String: Any],
        let name = args["name"] as? String,
        !name.isEmpty
      else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "name is empty", details: nil))
        return
      }
      sendProviderMessage(id: "urlTest", params: name) { response in
        result(response?.data ?? "")
      }

    case "getAesKey":
      result(decryptKey(enc: MihomoKeys.aesEnc, key: 0x5A))
    case "getObfuscateKey":
      result(decryptKey(enc: MihomoKeys.obfuscateEnc, key: 0x5A))
    case "getServerUrlKey":
      result(decryptKey(enc: MihomoKeys.serverUrlEnc, key: 0x5A))
    case "isReady":
      result(true)
    case "getWorkingDirectory":
      do {
        result(try resolveSharedWorkingDirectory().path)
      } catch {
        result(
          FlutterError(
            code: "APP_GROUP_UNAVAILABLE",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    case "getTunnelStatus":
      result(tunnelStatusPayload())

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func decryptKey(enc: [UInt8], key: UInt8) -> String {
    let bytes = enc.map { $0 ^ key }
    return String(bytes: bytes, encoding: .utf8) ?? ""
  }

  private func configValue(for key: String) -> String? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func resolveSharedWorkingDirectory() throws -> URL {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupId
    ) else {
      throw NSError(domain: "MihomoIosPlugin", code: -10, userInfo: [
        NSLocalizedDescriptionKey: "App Group container unavailable for \(appGroupId)"
      ])
    }
    let dir = container.appendingPathComponent("mihomo_runtime", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let probeURL = dir.appendingPathComponent(".write_probe", isDirectory: false)
    try Data("ok".utf8).write(to: probeURL, options: .atomic)
    try? FileManager.default.removeItem(at: probeURL)
    return dir
  }

  private func startVpn(
    homeDir: String,
    configFileName: String,
    completion: @escaping (String?, String?) -> Void
  ) {
    managerQueue.async {
      let sessionId = UUID().uuidString
      let finish = CompletionGate<(String?, String?)> { payload in
        completion(payload.0, payload.1)
      }
      let timeoutWorkItem = DispatchWorkItem {
        finish.call(("vpn authorization timeout", sessionId))
      }
      self.managerQueue.asyncAfter(deadline: .now() + 12.0, execute: timeoutWorkItem)
      do {
        _ = try self.resolveSharedWorkingDirectory()
        try self.validateTunnelExtensionAvailability()
      } catch {
        timeoutWorkItem.cancel()
        finish.call((error.localizedDescription, sessionId))
        return
      }
      TunnelSharedStateStore(appGroupId: self.appGroupId).clear()
      self.loadManagers { managers, error in
        if let error {
          timeoutWorkItem.cancel()
          finish.call((error.localizedDescription, sessionId))
          return
        }
        let matches = managers.filter { manager in
          (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.tunnelBundleId
        }
        let duplicates = Array(matches.dropFirst())
        self.removeManagers(duplicates) { removeError in
          if let removeError {
            timeoutWorkItem.cancel()
            finish.call((removeError.localizedDescription, sessionId))
            return
          }
          let manager = matches.first ?? NETunnelProviderManager()
          self.configureAndStartVpn(
            manager: manager,
            homeDir: homeDir,
            configFileName: configFileName,
            sessionId: sessionId,
            allowResetOnFailure: !matches.isEmpty,
            timeoutWorkItem: timeoutWorkItem,
            completion: finish
          )
        }
      }
    }
  }

  private func stopVpn(completion: @escaping (String?) -> Void) {
    managerQueue.async {
      self.loadManager { manager in
        guard let session = manager?.connection as? NETunnelProviderSession else {
          completion(nil)
          return
        }
        session.stopVPNTunnel()
        completion(nil)
      }
    }
  }

  private func configureAndStartVpn(
    manager: NETunnelProviderManager,
    homeDir: String,
    configFileName: String,
    sessionId: String,
    allowResetOnFailure: Bool,
    timeoutWorkItem: DispatchWorkItem,
    completion: CompletionGate<(String?, String?)>
  ) {
    let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
    proto.providerBundleIdentifier = tunnelBundleId
    proto.serverAddress = "mihomo"
    var conf = proto.providerConfiguration ?? [:]
    conf["homeDir"] = homeDir
    conf["configFileName"] = configFileName
    conf["appGroupId"] = appGroupId
    conf["sessionId"] = sessionId
    proto.providerConfiguration = conf
    manager.protocolConfiguration = proto
    manager.localizedDescription = "加速器"
    manager.isEnabled = true

    manager.saveToPreferences { error in
      if let error {
        self.retryAfterManagerResetIfNeeded(
          manager: manager,
          homeDir: homeDir,
          configFileName: configFileName,
          sessionId: sessionId,
          allowResetOnFailure: allowResetOnFailure,
          timeoutWorkItem: timeoutWorkItem,
          completion: completion,
          fallbackMessage: error.localizedDescription
        )
        return
      }
      manager.loadFromPreferences { error in
        if let error {
          self.retryAfterManagerResetIfNeeded(
            manager: manager,
            homeDir: homeDir,
            configFileName: configFileName,
            sessionId: sessionId,
            allowResetOnFailure: allowResetOnFailure,
            timeoutWorkItem: timeoutWorkItem,
            completion: completion,
            fallbackMessage: error.localizedDescription
          )
          return
        }
        do {
          guard let session = manager.connection as? NETunnelProviderSession else {
            timeoutWorkItem.cancel()
            completion.call(("NETunnelProviderSession unavailable", sessionId))
            return
          }
          try session.startVPNTunnel()
          timeoutWorkItem.cancel()
          completion.call((nil, sessionId))
        } catch {
          self.retryAfterManagerResetIfNeeded(
            manager: manager,
            homeDir: homeDir,
            configFileName: configFileName,
            sessionId: sessionId,
            allowResetOnFailure: allowResetOnFailure,
            timeoutWorkItem: timeoutWorkItem,
            completion: completion,
            fallbackMessage: error.localizedDescription
          )
        }
      }
    }
  }

  private func retryAfterManagerResetIfNeeded(
    manager: NETunnelProviderManager,
    homeDir: String,
    configFileName: String,
    sessionId: String,
    allowResetOnFailure: Bool,
    timeoutWorkItem: DispatchWorkItem,
    completion: CompletionGate<(String?, String?)>,
    fallbackMessage: String
  ) {
    guard allowResetOnFailure else {
      timeoutWorkItem.cancel()
      completion.call((fallbackMessage, sessionId))
      return
    }
    removeManagers([manager]) { error in
      if let error {
        timeoutWorkItem.cancel()
        completion.call(("\(fallbackMessage) · \(error.localizedDescription)", sessionId))
        return
      }
      self.configureAndStartVpn(
        manager: NETunnelProviderManager(),
        homeDir: homeDir,
        configFileName: configFileName,
        sessionId: sessionId,
        allowResetOnFailure: false,
        timeoutWorkItem: timeoutWorkItem,
        completion: completion
      )
    }
  }

  private func loadManager(completion: @escaping (NETunnelProviderManager?) -> Void) {
    loadManagers { managers, _ in
      let match = managers.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.tunnelBundleId })
      completion(match)
    }
  }

  private func loadManagers(
    completion: @escaping ([NETunnelProviderManager], Error?) -> Void
  ) {
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      completion(managers ?? [], error)
    }
  }

  private func removeManagers(
    _ managers: [NETunnelProviderManager],
    completion: @escaping (Error?) -> Void
  ) {
    guard let manager = managers.first else {
      completion(nil)
      return
    }
    var remaining = managers
    remaining.removeFirst()
    manager.removeFromPreferences { error in
      if let error {
        completion(error)
        return
      }
      self.removeManagers(remaining, completion: completion)
    }
  }

  private func validateTunnelExtensionAvailability() throws {
    guard let pluginsURL = Bundle.main.builtInPlugInsURL else {
      throw NSError(domain: "MihomoIosPlugin", code: -11, userInfo: [
        NSLocalizedDescriptionKey: "Network Extension capability unavailable"
      ])
    }
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: pluginsURL,
      includingPropertiesForKeys: nil
    ) else {
      throw NSError(domain: "MihomoIosPlugin", code: -12, userInfo: [
        NSLocalizedDescriptionKey: "Network Extension capability unavailable"
      ])
    }
    let hasExtension = entries.contains { url in
      guard
        url.pathExtension == "appex",
        let bundle = Bundle(url: url),
        bundle.bundleIdentifier == tunnelBundleId
      else {
        return false
      }
      return true
    }
    if !hasExtension {
      throw NSError(domain: "MihomoIosPlugin", code: -13, userInfo: [
        NSLocalizedDescriptionKey: "Network Extension capability unavailable"
      ])
    }
  }

  fileprivate func sendProviderMessage(id: String, params: String, completion: @escaping (ProviderMessageResponse?) -> Void) {
    loadManager { manager in
      guard let session = manager?.connection as? NETunnelProviderSession else {
        completion(nil)
        return
      }
      let msg = ProviderMessage(messageId: id, messageParams: params)
      guard let data = try? JSONEncoder().encode(msg) else {
        completion(nil)
        return
      }
      do {
        try session.sendProviderMessage(data) { responseData in
          guard let responseData else {
            completion(nil)
            return
          }
          completion(try? JSONDecoder().decode(ProviderMessageResponse.self, from: responseData))
        }
      } catch {
        completion(nil)
      }
    }
  }

  fileprivate func readSharedState() -> TunnelSharedState? {
    TunnelSharedStateStore(appGroupId: appGroupId).readOptional()
  }

  fileprivate func tunnelStatusPayload() -> [String: Any] {
    let state = readSharedState()
    return [
      "sessionId": state?.sessionId ?? "",
      "status": state?.status ?? "stopped",
      "running": state?.running ?? false,
      "mode": state?.mode ?? "",
      "up": state?.up ?? 0,
      "down": state?.down ?? 0,
      "updatedAt": state?.updatedAt ?? 0,
      "lastError": state?.lastError ?? ""
    ]
  }
}

final class TrafficStreamHandler: NSObject, FlutterStreamHandler {
  private weak var plugin: MihomoIosPlugin?
  private var timer: Timer?
  private var sink: FlutterEventSink?
  private var isFetching = false
  private var lastEmittedUp: Int64?
  private var lastEmittedDown: Int64?

  init(plugin: MihomoIosPlugin) {
    self.plugin = plugin
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    lastEmittedUp = nil
    lastEmittedDown = nil
    DispatchQueue.main.async {
      self.timer?.invalidate()
      self.emitTraffic()
      self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
        self.emitTraffic()
      }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    timer?.invalidate()
    timer = nil
    sink = nil
    isFetching = false
    lastEmittedUp = nil
    lastEmittedDown = nil
    return nil
  }

  private func emitTraffic() {
    guard sink != nil, !isFetching else {
      return
    }
    isFetching = true
    plugin?.sendProviderMessage(id: "traffic", params: "") { [weak self] response in
      guard let self else {
        return
      }
      let payload = self.resolveTrafficPayload(response: response)
      DispatchQueue.main.async {
        self.isFetching = false
        guard let sink = self.sink else {
          return
        }
        let up = payload["up"] ?? 0
        let down = payload["down"] ?? 0
        if self.lastEmittedUp == up && self.lastEmittedDown == down {
          return
        }
        self.lastEmittedUp = up
        self.lastEmittedDown = down
        sink(payload)
      }
    }
  }

  private func resolveTrafficPayload(response: ProviderMessageResponse?) -> [String: Int64] {
    if
      let data = response?.data,
      let parsed = parseTrafficPayload(data)
    {
      return parsed
    }
    let state = plugin?.readSharedState()
    return [
      "up": state?.up ?? 0,
      "down": state?.down ?? 0
    ]
  }

  private func parseTrafficPayload(_ payload: String) -> [String: Int64]? {
    guard
      let data = payload.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    let up = (object["up"] as? NSNumber)?.int64Value ?? Int64(object["up"] as? Int ?? 0)
    let down = (object["down"] as? NSNumber)?.int64Value ?? Int64(object["down"] as? Int ?? 0)
    return [
      "up": up,
      "down": down
    ]
  }
}

private struct ProviderMessage: Codable {
  var messageId: String
  var messageParams: String
}

private struct ProviderMessageResponse: Codable {
  var err: String?
  var data: String?
}

private struct ProviderSelectProxy: Codable {
  var groupName: String
  var name: String
}

private struct TunnelSharedState: Codable {
  var sessionId: String
  var status: String
  var running: Bool
  var mode: String
  var up: Int64
  var down: Int64
  var proxies: String
  var selectedProxyByGroup: [String: String]
  var updatedAt: TimeInterval
  var lastError: String?
}

private struct TunnelSharedStateStore {
  let appGroupId: String
  private let staleThreshold: TimeInterval = 10

  func readOptional() -> TunnelSharedState? {
    guard
      let url = resolveStateFileURL(),
      let data = try? Data(contentsOf: url),
      let state = try? JSONDecoder().decode(TunnelSharedState.self, from: data)
    else {
      return nil
    }
    guard Date().timeIntervalSince1970 - state.updatedAt <= staleThreshold else {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    return state
  }

  func clear() {
    guard let url = resolveStateFileURL() else {
      return
    }
    try? FileManager.default.removeItem(at: url)
  }

  private func resolveStateFileURL() -> URL? {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupId
    ) else {
      return nil
    }
    let directory = container.appendingPathComponent("mihomo_runtime", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch { return nil }
    return directory.appendingPathComponent("shared_state.json", isDirectory: false)
  }
}

private final class CompletionGate<T> {
  private let queue = DispatchQueue(label: "com.accelerator.tg.mihomo.result")
  private var completed = false
  private let completion: (T) -> Void

  init(_ completion: @escaping (T) -> Void) {
    self.completion = completion
  }

  func call(_ value: T) {
    queue.sync {
      if completed {
        return
      }
      completed = true
      completion(value)
    }
  }
}

private enum MihomoKeys {
  static let aesEnc: [UInt8] = [
    0x62, 0x63, 0x1b, 0x6d, 0x18, 0x6c, 0x19, 0x6f, 0x1e, 0x6e, 0x1f, 0x69, 0x1c, 0x68, 0x6a, 0x6b,
    0x63, 0x62, 0x6d, 0x6c, 0x6f, 0x6e, 0x69, 0x68, 0x6b, 0x6a, 0x1b, 0x18, 0x19, 0x1e, 0x1f, 0x1c,
    0x6b, 0x68, 0x69, 0x6e, 0x6f, 0x6c, 0x68, 0x62, 0x63, 0x6a, 0x1b, 0x18, 0x19, 0x1e, 0x1f, 0x1c,
    0x62, 0x63, 0x1b, 0x6d, 0x18, 0x6c, 0x19, 0x6f, 0x1e, 0x6e, 0x1f, 0x69, 0x1c, 0x68, 0x6a, 0x6b
  ]
  static let obfuscateEnc: [UInt8] = [
    0x6d, 0x17, 0x62, 0x14, 0x63, 0x18, 0x62, 0x0c, 0x6d, 0x19, 0x63, 0x02, 0x62, 0x00, 0x6d, 0x1b,
    0x63, 0x09, 0x62, 0x1e, 0x6d, 0x1c, 0x63, 0x1d, 0x62, 0x12, 0x6d, 0x10, 0x63, 0x11, 0x62, 0x16,
    0x6d, 0x0a, 0x63, 0x15, 0x62, 0x13, 0x6d, 0x0f, 0x63, 0x03, 0x62, 0x0d, 0x6d, 0x0e, 0x63, 0x08,
    0x62, 0x0a, 0x6d, 0x17, 0x63, 0x14, 0x62, 0x18, 0x6d, 0x0c, 0x63, 0x19, 0x62, 0x02, 0x6d, 0x00,
    0x63, 0x1b, 0x62, 0x09, 0x6d, 0x1e, 0x63, 0x1c, 0x62, 0x1d, 0x6d, 0x12, 0x63, 0x10, 0x62, 0x11,
    0x6d, 0x16, 0x6c, 0x0a
  ]
  static let serverUrlEnc: [UInt8] = [
      0x32, 0x2e, 0x2e, 0x2a, 0x29, 0x60, 0x75, 0x75, 0x2c, 0x2a, 0x34, 0x3b, 0x2a, 0x33, 0x29, 0x74,
      0x39, 0x35, 0x37
    ]
}
