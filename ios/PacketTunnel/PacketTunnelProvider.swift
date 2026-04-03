import Foundation
import NetworkExtension
import Darwin

final class ProviderMessage: Codable {
  var messageId: String
  var messageParams: String

  init(messageId: String, messageParams: String) {
    self.messageId = messageId
    self.messageParams = messageParams
  }
}

final class ProviderMessageResponse: Codable {
  var err: String?
  var data: String?

  init(err: String? = nil, data: String? = nil) {
    self.err = err
    self.data = data
  }
}

final class SelectProxyPayload: Codable {
  var groupName: String
  var name: String
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let defaultAppGroupId = "group.com.xiangyu.clash"
  private let actionQueue = DispatchQueue(label: "com.accelerator.tg.packet-tunnel.action")
  private var started = false
  private var currentSessionId = ""
  private var trafficTimer: DispatchSourceTimer?
  private var lastPersistedTrafficSnapshot = TrafficSnapshot.empty
  private var lastPersistedTrafficAt: TimeInterval = 0

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let gate = CompletionGate(completionHandler)
    do {
      guard
        let proto = protocolConfiguration as? NETunnelProviderProtocol,
        let providerConfig = proto.providerConfiguration,
        let homeDir = providerConfig["homeDir"] as? String,
        let configFileName = providerConfig["configFileName"] as? String
      else {
        throw NSError(domain: "PacketTunnel", code: -1, userInfo: [
          NSLocalizedDescriptionKey: "providerConfiguration invalid"
        ])
      }

      let appGroupId = (providerConfig["appGroupId"] as? String) ?? defaultAppGroupId
      let sessionId = (providerConfig["sessionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        ? (providerConfig["sessionId"] as? String)!.trimmingCharacters(in: .whitespacesAndNewlines)
        : UUID().uuidString
      _ = try validateSharedRuntimeDirectory(appGroupId: appGroupId)
      currentSessionId = sessionId
      let timeoutError = NSError(domain: "PacketTunnel", code: -10, userInfo: [
        NSLocalizedDescriptionKey: "startTunnel timeout"
      ])
      let timeoutWorkItem = DispatchWorkItem { [weak self] in
        guard let self else { return }
        if gate.call(timeoutError) {
          self.stopTrafficTimer()
          self.started = false
          self.persistFailureState(
            appGroupId: appGroupId,
            sessionId: sessionId,
            message: "startTunnel timeout"
          )
        }
      }
      actionQueue.asyncAfter(deadline: .now() + 8.0, execute: timeoutWorkItem)
      func finish(_ error: Error?) {
        timeoutWorkItem.cancel()
        _ = gate.call(error)
      }
      persistState(appGroupId: appGroupId) { state in
        state.sessionId = sessionId
        state.status = "starting"
        state.running = false
        state.mode = ""
        state.up = 0
        state.down = 0
        state.lastError = nil
      }

      let settings = buildNetworkSettings()
      setTunnelNetworkSettings(settings) { [weak self] error in
        guard let self else {
          finish(error)
          return
        }
        if let error {
          self.persistFailureState(
            appGroupId: appGroupId,
            sessionId: sessionId,
            message: error.localizedDescription
          )
          finish(error)
          return
        }
        self.actionQueue.async {
          autoreleasepool {
            do {
              let fd = try self.resolveTunnelFileDescriptor()
              try self.prepareConfigFile(
                homeDir: homeDir,
                configFileName: configFileName,
                fileDescriptor: fd
              )
              MobileSetLogLevel("silent")
              MobileStart(homeDir, configFileName)
              self.currentSessionId = sessionId
              self.started = true
              self.lastPersistedTrafficSnapshot = .empty
              self.lastPersistedTrafficAt = 0
              self.startTrafficTimer(appGroupId: appGroupId)
              self.persistRunningState(appGroupId: appGroupId, sessionId: sessionId)
              finish(nil)
              self.actionQueue.async { [weak self] in
                autoreleasepool {
                  self?.refreshSharedState(
                    appGroupId: appGroupId,
                    sessionId: sessionId,
                    includeProxies: true
                  )
                }
              }
            } catch {
              if self.started {
                MobileStop()
              }
              MobileClearSocketProtector()
              self.stopTrafficTimer()
              self.started = false
              self.persistFailureState(
                appGroupId: appGroupId,
                sessionId: sessionId,
                message: error.localizedDescription
              )
              finish(error)
            }
          }
        }
      }
    } catch {
      _ = gate.call(error)
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    let appGroupId = resolveAppGroupId()
    actionQueue.async {
      TunnelSharedStateStore(appGroupId: appGroupId).clear()
      if self.started {
        MobileStop()
      }
      MobileClearSocketProtector()
      self.stopTrafficTimer()
      self.started = false
      self.persistStoppedState(appGroupId: appGroupId, sessionId: self.currentSessionId)
      self.currentSessionId = ""
      completionHandler()
    }
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    let appGroupId = resolveAppGroupId()
    actionQueue.async {
      let response = self.handleMessageData(messageData, appGroupId: appGroupId)
      let payload = try? JSONEncoder().encode(response)
      completionHandler?(payload)
    }
  }

  private func buildNetworkSettings() -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    settings.mtu = 1500

    let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.0"])
    ipv4.includedRoutes = [NEIPv4Route.default()]
    settings.ipv4Settings = ipv4

    let ipv6 = NEIPv6Settings(addresses: ["fd00:172:19::1"], networkPrefixLengths: [64])
    ipv6.includedRoutes = [NEIPv6Route.default()]
    settings.ipv6Settings = ipv6

    let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
    dns.matchDomains = [""]
    settings.dnsSettings = dns
    return settings
  }

  private func resolveTunnelFileDescriptor() throws -> Int {
    if let value = scanTunnelFileDescriptor(), value > 0 {
      return value
    }
    if let value = packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int,
       isTunnelFileDescriptor(value) {
      return value
    }
    NSLog("PacketTunnel: failed to resolve tunnel file descriptor from all strategies")
    throw NSError(domain: "PacketTunnel", code: -2, userInfo: [
      NSLocalizedDescriptionKey: "failed to resolve tunnel file descriptor"
    ])
  }

  private func isTunnelFileDescriptor(_ fd: Int) -> Bool {
    guard fd > 0 else {
      return false
    }
    var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
    var len = socklen_t(buf.count)
    let result: Int32 = buf.withUnsafeMutableBytes { ptr in
      getsockopt(Int32(fd), 2, 2, ptr.baseAddress, &len)
    }
    guard result == 0 else {
      return false
    }
    let name = String(cString: buf)
    return name.hasPrefix("utun")
  }

  private func scanTunnelFileDescriptor() -> Int? {
    let maxFD = max(256, min(Int(getdtablesize()), 4096))
    for fd in 0..<maxFD {
      if isTunnelFileDescriptor(fd) {
        return fd
      }
    }
    return nil
  }

  private func prepareConfigFile(homeDir: String, configFileName: String, fileDescriptor: Int) throws {
    let path = (homeDir as NSString).appendingPathComponent(configFileName)
    let url = URL(fileURLWithPath: path)
    let content = try String(contentsOf: url, encoding: .utf8)
    let updatedContent = injectTunConfig(content: content, fileDescriptor: fileDescriptor)
    if updatedContent == content {
      return
    }
    try updatedContent.write(to: url, atomically: true, encoding: .utf8)
  }

  private func injectTunConfig(content: String, fileDescriptor: Int) -> String {
    let useCrlf = content.contains("\r\n")
    let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
    var lines = normalized.components(separatedBy: "\n")

    func isTopLevelKeyLine(_ line: String) -> Bool {
      if line.isEmpty { return false }
      if line.hasPrefix(" ") || line.hasPrefix("\t") { return false }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("-") || trimmed.hasPrefix("#") { return false }
      return trimmed.range(of: #"^[A-Za-z0-9_-]+:\s*"#, options: .regularExpression) != nil
    }

    func leadingWhitespace(_ line: String) -> String {
      let prefix = line.prefix { $0 == " " || $0 == "\t" }
      return String(prefix)
    }

    var tunIndex: Int?
    for i in 0..<lines.count {
      let line = lines[i]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed != "tun:" { continue }
      let raw = line.hasPrefix("\u{FEFF}") ? String(line.dropFirst()) : line
      if raw.hasPrefix("tun:") {
        tunIndex = i
        break
      }
    }

    let requiredKeyLines: [(key: String, line: (String) -> String)] = [
      ("enable", { indent in "\(indent)enable: true" }),
      ("stack", { indent in "\(indent)stack: system" }),
      ("file-descriptor", { indent in "\(indent)file-descriptor: \(fileDescriptor)" }),
    ]

    guard let tunIndex else {
      let defaultBlock = [
        "tun:",
        "  enable: true",
        "  stack: system",
        "  auto-route: false",
        "  auto-detect-interface: false",
        "  dns-hijack: []",
        "  file-descriptor: \(fileDescriptor)",
      ].joined(separator: "\n")
      let glued = normalized.hasSuffix("\n") || normalized.isEmpty ? normalized : "\(normalized)\n"
      let result = "\(glued)\n\(defaultBlock)\n"
      return useCrlf ? result.replacingOccurrences(of: "\n", with: "\r\n") : result
    }

    var blockEnd = lines.count
    if tunIndex + 1 < lines.count {
      for i in (tunIndex + 1)..<lines.count {
        if isTopLevelKeyLine(lines[i]) {
          blockEnd = i
          break
        }
      }
    }

    var indent = "  "
    if tunIndex + 1 < blockEnd {
      for i in (tunIndex + 1)..<blockEnd {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let prefix = leadingWhitespace(line)
        if !prefix.isEmpty {
          indent = prefix
          break
        }
      }
    }

    var presentKeys = Set<String>()
    if tunIndex + 1 < blockEnd {
      for i in (tunIndex + 1)..<blockEnd {
        let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
        for (key, lineBuilder) in requiredKeyLines {
          if trimmed.hasPrefix("\(key):") {
            lines[i] = lineBuilder(indent)
            presentKeys.insert(key)
            break
          }
        }
      }
    }

    var insertAt = tunIndex + 1
    while insertAt < blockEnd {
      let trimmed = lines[insertAt].trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") {
        insertAt += 1
        continue
      }
      break
    }

    let toInsert = requiredKeyLines
      .filter { !presentKeys.contains($0.key) }
      .map { $0.line(indent) }
    if !toInsert.isEmpty {
      lines.insert(contentsOf: toInsert, at: insertAt)
    }

    let result = lines.joined(separator: "\n")
    return useCrlf ? result.replacingOccurrences(of: "\n", with: "\r\n") : result
  }

  private func handleMessageData(_ messageData: Data, appGroupId: String) -> ProviderMessageResponse {
    guard let message = try? JSONDecoder().decode(ProviderMessage.self, from: messageData) else {
      return ProviderMessageResponse(err: "invalid provider message")
    }

    switch message.messageId {
    case "getMode":
      return ProviderMessageResponse(data: MobileGetMode())

    case "setMode":
      MobileSetMode(message.messageParams)
      refreshSharedState(
        appGroupId: appGroupId,
        sessionId: currentSessionId,
        includeProxies: false
      )
      return ProviderMessageResponse(data: MobileGetMode() == message.messageParams ? "true" : "false")

    case "getProxies":
      return ProviderMessageResponse(data: MobileGetProxies())

    case "getSelectedProxy":
      let groupName = message.messageParams.isEmpty ? "GLOBAL" : message.messageParams
      return ProviderMessageResponse(data: resolveSelectedProxyName(groupName: groupName))

    case "selectProxy":
      guard let payload = try? JSONDecoder().decode(SelectProxyPayload.self, from: Data(message.messageParams.utf8)) else {
        return ProviderMessageResponse(err: "invalid select proxy payload")
      }
      let ok = MobileSelectProxy(payload.groupName, payload.name)
      refreshSharedState(
        appGroupId: appGroupId,
        sessionId: currentSessionId,
        includeProxies: ok
      )
      return ProviderMessageResponse(data: ok ? "true" : "false")

    case "urlTest":
      return ProviderMessageResponse(data: MobileTestLatency(message.messageParams))

    case "traffic":
      refreshTrafficOnly(appGroupId: appGroupId)
      let payload = """
      {"up":\(MobileTrafficUp()),"down":\(MobileTrafficDown())}
      """
      return ProviderMessageResponse(data: payload)

    default:
      return ProviderMessageResponse(err: "unsupported \(message.messageId)")
    }
  }

  private func resolveSelectedProxyName(groupName: String) -> String {
    guard
      let data = MobileGetProxies().data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let proxies = object["proxies"] as? [String: Any],
      let group = proxies[groupName] as? [String: Any]
    else {
      return ""
    }
    return group["now"] as? String ?? ""
  }

  private func resolveAppGroupId() -> String {
    guard
      let proto = protocolConfiguration as? NETunnelProviderProtocol,
      let providerConfig = proto.providerConfiguration
    else {
      return defaultAppGroupId
    }
    return (providerConfig["appGroupId"] as? String) ?? defaultAppGroupId
  }

  private func startTrafficTimer(appGroupId: String) {
    stopTrafficTimer()
    let timer = DispatchSource.makeTimerSource(queue: actionQueue)
    timer.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(500))
    timer.setEventHandler { [weak self] in
      self?.refreshTrafficOnly(appGroupId: appGroupId)
    }
    trafficTimer = timer
    timer.resume()
  }

  private func stopTrafficTimer() {
    trafficTimer?.cancel()
    trafficTimer = nil
  }

  private func refreshTrafficOnly(appGroupId: String) {
    let up = Int64(MobileTrafficUp())
    let down = Int64(MobileTrafficDown())
    let status = started ? "running" : "stopped"
    let mode = started ? MobileGetMode() : ""
    let snapshot = TrafficSnapshot(
      status: status,
      running: started,
      mode: mode,
      up: up,
      down: down
    )
    let now = Date().timeIntervalSince1970
    let shouldPersist = snapshot != lastPersistedTrafficSnapshot ||
      now - lastPersistedTrafficAt >= 2.0
    guard shouldPersist else {
      return
    }
    persistState(appGroupId: appGroupId) { state in
      if !currentSessionId.isEmpty {
        state.sessionId = currentSessionId
      }
      state.running = snapshot.running
      state.status = snapshot.status
      state.up = snapshot.up
      state.down = snapshot.down
      state.updatedAt = Date().timeIntervalSince1970
      state.lastError = nil
      state.mode = snapshot.mode
    }
    lastPersistedTrafficSnapshot = snapshot
    lastPersistedTrafficAt = now
  }

  private func refreshSharedState(appGroupId: String, sessionId: String, includeProxies: Bool) {
    let proxies = includeProxies ? MobileGetProxies() : nil
    let selectedMap = proxies.map(resolveSelectedProxyMap) ?? [:]
    persistState(appGroupId: appGroupId) { state in
      state.sessionId = sessionId
      state.running = started
      state.status = started ? "running" : "stopped"
      state.mode = started ? MobileGetMode() : ""
      state.up = Int64(MobileTrafficUp())
      state.down = Int64(MobileTrafficDown())
      state.updatedAt = Date().timeIntervalSince1970
      state.lastError = nil
      if let proxies {
        state.proxies = proxies
        state.selectedProxyByGroup = selectedMap
      }
    }
  }

  private func persistRunningState(appGroupId: String, sessionId: String) {
    let mode = MobileGetMode()
    persistState(appGroupId: appGroupId) { state in
      state.sessionId = sessionId
      state.running = true
      state.status = "running"
      state.mode = mode
      state.up = 0
      state.down = 0
      state.lastError = nil
    }
    lastPersistedTrafficSnapshot = TrafficSnapshot(
      status: "running",
      running: true,
      mode: mode,
      up: 0,
      down: 0
    )
    lastPersistedTrafficAt = Date().timeIntervalSince1970
  }

  private func persistFailureState(appGroupId: String, sessionId: String, message: String) {
    persistState(appGroupId: appGroupId) { state in
      state.sessionId = sessionId
      state.status = "failed"
      state.running = false
      state.up = 0
      state.down = 0
      state.lastError = message
    }
    lastPersistedTrafficSnapshot = TrafficSnapshot(
      status: "failed",
      running: false,
      mode: "",
      up: 0,
      down: 0
    )
    lastPersistedTrafficAt = Date().timeIntervalSince1970
  }

  private func persistStoppedState(appGroupId: String, sessionId: String) {
    persistState(appGroupId: appGroupId) { state in
      state.sessionId = sessionId
      state.status = "stopped"
      state.running = false
      state.up = 0
      state.down = 0
      state.mode = ""
      state.lastError = nil
    }
    lastPersistedTrafficSnapshot = .empty
    lastPersistedTrafficAt = Date().timeIntervalSince1970
  }

  private func persistState(appGroupId: String, mutate: (inout TunnelSharedState) -> Void) {
    let store = TunnelSharedStateStore(appGroupId: appGroupId)
    var state = store.read()
    mutate(&state)
    state.updatedAt = Date().timeIntervalSince1970
    store.write(state)
  }

  private func validateSharedRuntimeDirectory(appGroupId: String) throws -> URL {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupId
    ) else {
      throw NSError(domain: "PacketTunnel", code: -20, userInfo: [
        NSLocalizedDescriptionKey: "App Group container unavailable for \(appGroupId)"
      ])
    }
    let directory = container.appendingPathComponent("mihomo_runtime", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let probeURL = directory.appendingPathComponent(".write_probe", isDirectory: false)
    try Data("ok".utf8).write(to: probeURL, options: .atomic)
    try? FileManager.default.removeItem(at: probeURL)
    return directory
  }

  private func resolveSelectedProxyMap(_ proxiesJSON: String) -> [String: String] {
    guard
      let data = proxiesJSON.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let proxies = object["proxies"] as? [String: Any]
    else {
      return [:]
    }

    var result: [String: String] = [:]
    for (name, raw) in proxies {
      guard let value = raw as? [String: Any] else { continue }
      let selected = (value["now"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !selected.isEmpty {
        result[name] = selected
      }
    }
    return result
  }
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

  static let empty = TunnelSharedState(
    sessionId: "",
    status: "stopped",
    running: false,
    mode: "",
    up: 0,
    down: 0,
    proxies: "",
    selectedProxyByGroup: [:],
    updatedAt: 0,
    lastError: nil
  )
}

private struct TunnelSharedStateStore {
  let appGroupId: String
  private let staleThreshold: TimeInterval = 10

  func read() -> TunnelSharedState {
    guard
      let url = resolveStateFileURL(),
      let data = try? Data(contentsOf: url),
      let state = try? JSONDecoder().decode(TunnelSharedState.self, from: data)
    else {
      return .empty
    }
    guard Date().timeIntervalSince1970 - state.updatedAt <= staleThreshold else {
      try? FileManager.default.removeItem(at: url)
      return .empty
    }
    return state
  }

  func write(_ state: TunnelSharedState) {
    guard let url = resolveStateFileURL() else {
      return
    }
    do {
      let data = try JSONEncoder().encode(state)
      try data.write(to: url, options: .atomic)
    } catch {
      NSLog("PacketTunnel: failed to write shared state - \(error.localizedDescription)")
    }
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
      NSLog("PacketTunnel: shared state App Group unavailable for \(appGroupId)")
      return nil
    }
    let directory = container.appendingPathComponent("mihomo_runtime", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      NSLog("PacketTunnel: failed to create shared runtime directory - \(error.localizedDescription)")
      return nil
    }
    return directory.appendingPathComponent("shared_state.json", isDirectory: false)
  }
}

private struct TrafficSnapshot: Equatable {
  let status: String
  let running: Bool
  let mode: String
  let up: Int64
  let down: Int64

  static let empty = TrafficSnapshot(
    status: "stopped",
    running: false,
    mode: "",
    up: 0,
    down: 0
  )
}

private final class CompletionGate {
  private let lock = DispatchQueue(label: "com.accelerator.tg.packet-tunnel.completion")
  private var called = false
  private let completion: (Error?) -> Void

  init(_ completion: @escaping (Error?) -> Void) {
    self.completion = completion
  }

  @discardableResult
  func call(_ error: Error?) -> Bool {
    lock.sync {
      if called {
        return false
      }
      called = true
      completion(error)
      return true
    }
  }
}
