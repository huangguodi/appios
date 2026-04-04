import Foundation
import Network
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
  private enum AppConfigKey {
    static let appGroupId = "IOSAppGroupIdentifier"
  }
  private let actionQueue = DispatchQueue(label: "com.accelerator.tg.packet-tunnel.action")
  private let tunOpenStateLock = NSLock()
  private var started = false
  private var currentSessionId = ""
  private var trafficTimer: DispatchSourceTimer?
  private var lastPersistedTrafficSnapshot = TrafficSnapshot.empty
  private var lastPersistedTrafficAt: TimeInterval = 0
  private var socketProtector: PacketTunnelSocketProtector?
  private var tunOpener: PacketTunnelTunOpener?
  private var lastTunOpenInvoked = false
  private var lastTunOpenFD: Int64 = 0
  private var lastTunOpenError: String?
  private var defaultAppGroupId: String {
    if let configuredAppGroupId = configValue(for: AppConfigKey.appGroupId) {
      return configuredAppGroupId
    }
    let bundleId = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectiveBundleId = (bundleId?.isEmpty == false) ? bundleId! : "app.bundle.packettunnel"
    if effectiveBundleId.hasSuffix(".packettunnel") {
      return "group.\(String(effectiveBundleId.dropLast(".packettunnel".count)))"
    }
    return "group.\(effectiveBundleId)"
  }
  private struct PlatformTunOptions {
    var autoRoute: Bool = false
    var strictRoute: Bool = false
    var mtu: Int = 1500
    var inet4Address: [String] = []
    var inet6Address: [String] = []
    var routeAddress: [String] = []
    var routeExcludeAddress: [String] = []
    var dnsServers: [String] = []
    var dnsHijack: [String] = []
    var includeInterface: [String] = []
    var excludeInterface: [String] = []
    var disableICMPForwarding: Bool = false
    var name: String = ""
    var stack: String = ""
  }

  private func configValue(for key: String) -> String? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

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
      prepareForStart(sessionId: sessionId)
      let timeoutError = NSError(domain: "PacketTunnel", code: -10, userInfo: [
        NSLocalizedDescriptionKey: "startTunnel timeout"
      ])
      let timeoutWorkItem = DispatchWorkItem { [weak self] in
        guard let self else { return }
        if gate.call(timeoutError) {
          if self.started {
            MobileStop()
          }
          self.clearBridgeRegistrations()
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

      actionQueue.async {
        autoreleasepool {
          let protector = PacketTunnelSocketProtector(provider: self)
          let opener = PacketTunnelTunOpener(provider: self)
          self.clearBridgeRegistrations()
          MobileSetSocketProtector(protector)
          MobileSetTunOpener(opener)
          self.socketProtector = protector
          self.tunOpener = opener
          MobileSetLogLevel("silent")
          MobileStart(homeDir, configFileName)
          let tunOpenState = self.tunOpenState()
          guard tunOpenState.invoked, tunOpenState.fd > 0 else {
            let message = tunOpenState.error ?? "openTun failed"
            MobileStop()
            self.clearBridgeRegistrations()
            self.persistFailureState(
              appGroupId: appGroupId,
              sessionId: sessionId,
              message: message
            )
            finish(NSError(domain: "PacketTunnel", code: -22, userInfo: [
              NSLocalizedDescriptionKey: message
            ]))
            return
          }
          self.started = true
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
      self.clearBridgeRegistrations()
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

  fileprivate func openTun(options: MobileTunOptions?) -> Int64 {
    guard let options else {
      recordTunOpenFailure("missing tun options")
      persistFailureState(
        appGroupId: resolveAppGroupId(),
        sessionId: currentSessionId,
        message: "missing tun options"
      )
      return -1
    }

    do {
      let payload = parseTunOptions(options)
      let settings = buildNetworkSettings(tunOptions: payload)
      try applyTunnelNetworkSettings(settings)
      let fd = try resolveTunnelFileDescriptor()
      recordTunOpenSuccess(fd: Int64(fd))
      return Int64(fd)
    } catch {
      recordTunOpenFailure(error.localizedDescription)
      persistFailureState(
        appGroupId: resolveAppGroupId(),
        sessionId: currentSessionId,
        message: error.localizedDescription
      )
      return -1
    }
  }

  private func resetTunOpenState() {
    tunOpenStateLock.lock()
    lastTunOpenInvoked = false
    lastTunOpenFD = 0
    lastTunOpenError = nil
    tunOpenStateLock.unlock()
  }

  private func prepareForStart(sessionId: String) {
    currentSessionId = sessionId
    started = false
    stopTrafficTimer()
    lastPersistedTrafficSnapshot = .empty
    lastPersistedTrafficAt = 0
    resetTunOpenState()
  }

  private func clearBridgeRegistrations() {
    MobileClearTunOpener()
    MobileClearSocketProtector()
    tunOpener = nil
    socketProtector = nil
    stopTrafficTimer()
    started = false
  }

  private func recordTunOpenSuccess(fd: Int64) {
    tunOpenStateLock.lock()
    lastTunOpenInvoked = true
    lastTunOpenFD = fd
    lastTunOpenError = nil
    tunOpenStateLock.unlock()
  }

  private func recordTunOpenFailure(_ message: String) {
    tunOpenStateLock.lock()
    lastTunOpenInvoked = true
    lastTunOpenFD = -1
    lastTunOpenError = message
    tunOpenStateLock.unlock()
  }

  private func tunOpenState() -> (invoked: Bool, fd: Int64, error: String?) {
    tunOpenStateLock.lock()
    let state = (lastTunOpenInvoked, lastTunOpenFD, lastTunOpenError)
    tunOpenStateLock.unlock()
    return state
  }

  private func applyTunnelNetworkSettings(_ settings: NEPacketTunnelNetworkSettings) throws {
    let semaphore = DispatchSemaphore(value: 0)
    var applyError: Error?
    setTunnelNetworkSettings(settings) { error in
      applyError = error
      semaphore.signal()
    }
    let result = semaphore.wait(timeout: .now() + 8.0)
    if result == .timedOut {
      throw NSError(domain: "PacketTunnel", code: -21, userInfo: [
        NSLocalizedDescriptionKey: "setTunnelNetworkSettings timeout"
      ])
    }
    if let applyError {
      throw applyError
    }
  }

  private func buildNetworkSettings(tunOptions: PlatformTunOptions) -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    settings.mtu = NSNumber(value: max(tunOptions.mtu, 1))

    let ipv4AddressPairs = tunOptions.inet4Address.compactMap(parseIPv4CIDR)
    let ipv4Addresses = ipv4AddressPairs.isEmpty
      ? ["172.19.0.1"]
      : ipv4AddressPairs.map { $0.address }
    let ipv4Masks = ipv4AddressPairs.isEmpty
      ? ["255.255.255.252"]
      : ipv4AddressPairs.map { $0.mask }
    let ipv4 = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)
    if tunOptions.autoRoute {
      let ipv4IncludedRoutes = tunOptions.routeAddress
        .filter { !$0.contains(":") }
        .compactMap(parseIPv4Route)
      ipv4.includedRoutes = ipv4IncludedRoutes.isEmpty ? [NEIPv4Route.default()] : ipv4IncludedRoutes
      let ipv4ExcludedRoutes = tunOptions.routeExcludeAddress
        .filter { !$0.contains(":") }
        .compactMap(parseIPv4Route)
      if !ipv4ExcludedRoutes.isEmpty {
        ipv4.excludedRoutes = ipv4ExcludedRoutes
      }
    }
    settings.ipv4Settings = ipv4

    let shouldConfigureIPv6 =
      !tunOptions.inet6Address.isEmpty ||
      (tunOptions.autoRoute && tunOptions.routeAddress.contains(where: { $0.contains(":") })) ||
      (tunOptions.autoRoute && tunOptions.routeExcludeAddress.contains(where: { $0.contains(":") }))
    if shouldConfigureIPv6 {
      let ipv6AddressPairs = tunOptions.inet6Address.compactMap(parseIPv6CIDR)
      let ipv6Addresses = ipv6AddressPairs.isEmpty
        ? ["fdfe:dcbe:9876::1"]
        : ipv6AddressPairs.map { $0.address }
      let ipv6Prefix = ipv6AddressPairs.isEmpty
        ? [NSNumber(value: 126)]
        : ipv6AddressPairs.map { $0.prefix }
      let ipv6 = NEIPv6Settings(addresses: ipv6Addresses, networkPrefixLengths: ipv6Prefix)
      if tunOptions.autoRoute {
        let ipv6IncludedRoutes = tunOptions.routeAddress
          .filter { $0.contains(":") }
          .compactMap(parseIPv6Route)
        ipv6.includedRoutes = ipv6IncludedRoutes.isEmpty ? [NEIPv6Route.default()] : ipv6IncludedRoutes
        let ipv6ExcludedRoutes = tunOptions.routeExcludeAddress
          .filter { $0.contains(":") }
          .compactMap(parseIPv6Route)
        if !ipv6ExcludedRoutes.isEmpty {
          ipv6.excludedRoutes = ipv6ExcludedRoutes
        }
      }
      settings.ipv6Settings = ipv6
    }

    let dnsServers = normalizeDnsServers(tunOptions.dnsServers).filter {
      isValidIPv4Address($0) || isValidIPv6Address($0)
    }
    if tunOptions.autoRoute && !dnsServers.isEmpty {
      let dns = NEDNSSettings(servers: dnsServers)
      dns.matchDomains = [""]
      dns.matchDomainsNoSearch = true
      settings.dnsSettings = dns
    }
    return settings
  }

  private func parseTunOptions(_ options: MobileTunOptions) -> PlatformTunOptions {
    let jsonObject = decodeJSONObject(options.json())
    var payload = PlatformTunOptions()
    payload.autoRoute = boolValue(
      in: jsonObject,
      keys: ["auto-route", "autoRoute", "auto_route"]
    ) ?? options.autoRoute()
    payload.strictRoute = boolValue(
      in: jsonObject,
      keys: ["strict-route", "strictRoute", "strict_route"]
    ) ?? options.strictRoute()
    payload.mtu = intValue(
      in: jsonObject,
      keys: ["mtu", "MTU"]
    ) ?? Int(options.mtu())
    payload.inet4Address = stringListValue(
      in: jsonObject,
      keys: ["inet4-address", "inet4Address", "inet4_address"]
    ) ?? parseStringList(options.inet4Address())
    payload.inet6Address = stringListValue(
      in: jsonObject,
      keys: ["inet6-address", "inet6Address", "inet6_address"]
    ) ?? parseStringList(options.inet6Address())
    payload.routeAddress = stringListValue(
      in: jsonObject,
      keys: ["route-address", "routeAddress", "route_address"]
    ) ?? parseStringList(options.routeAddress())
    payload.routeExcludeAddress = stringListValue(
      in: jsonObject,
      keys: ["route-exclude-address", "routeExcludeAddress", "route_exclude_address"]
    ) ?? parseStringList(options.routeExcludeAddress())
    payload.dnsServers = stringListValue(
      in: jsonObject,
      keys: ["dns-servers", "dnsServers", "dns_servers"]
    ) ?? parseStringList(options.dnsServers())
    payload.dnsHijack = stringListValue(
      in: jsonObject,
      keys: ["dns-hijack", "dnsHijack", "dns_hijack"]
    ) ?? parseStringList(options.dnsHijack())
    payload.includeInterface = stringListValue(
      in: jsonObject,
      keys: ["include-interface", "includeInterface", "include_interface"]
    ) ?? parseStringList(options.includeInterface())
    payload.excludeInterface = stringListValue(
      in: jsonObject,
      keys: ["exclude-interface", "excludeInterface", "exclude_interface"]
    ) ?? parseStringList(options.excludeInterface())
    payload.disableICMPForwarding = boolValue(
      in: jsonObject,
      keys: ["disable-icmp-forwarding", "disableICMPForwarding", "disable_icmp_forwarding"]
    ) ?? options.disableICMPForwarding()
    payload.name = stringValue(
      in: jsonObject,
      keys: ["name", "Name"]
    ) ?? options.name()
    payload.stack = stringValue(
      in: jsonObject,
      keys: ["stack", "Stack"]
    ) ?? options.stack()
    return payload
  }

  private func decodeJSONObject(_ json: String) -> [String: Any] {
    guard
      let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }
    return object
  }

  private func value(in object: [String: Any], keys: [String]) -> Any? {
    for key in keys {
      if let value = object[key] {
        return value
      }
    }
    return nil
  }

  private func boolValue(in object: [String: Any], keys: [String]) -> Bool? {
    guard let value = value(in: object, keys: keys) else {
      return nil
    }
    if let boolValue = value as? Bool {
      return boolValue
    }
    if let numberValue = value as? NSNumber {
      return numberValue.boolValue
    }
    if let stringValue = value as? String {
      let normalized = sanitizeYamlScalar(stringValue).lowercased()
      if normalized == "true" {
        return true
      }
      if normalized == "false" {
        return false
      }
    }
    return nil
  }

  private func intValue(in object: [String: Any], keys: [String]) -> Int? {
    guard let value = value(in: object, keys: keys) else {
      return nil
    }
    if let intValue = value as? Int {
      return intValue
    }
    if let numberValue = value as? NSNumber {
      return numberValue.intValue
    }
    if let stringValue = value as? String {
      return Int(sanitizeYamlScalar(stringValue))
    }
    return nil
  }

  private func stringValue(in object: [String: Any], keys: [String]) -> String? {
    guard let value = value(in: object, keys: keys) else {
      return nil
    }
    if let stringValue = value as? String {
      let normalized = sanitizeYamlScalar(stringValue)
      return normalized.isEmpty ? nil : normalized
    }
    if let numberValue = value as? NSNumber {
      return numberValue.stringValue
    }
    return nil
  }

  private func stringListValue(in object: [String: Any], keys: [String]) -> [String]? {
    guard let value = value(in: object, keys: keys) else {
      return nil
    }
    return parseStringList(value)
  }

  private func parseStringList(_ raw: Any?) -> [String] {
    guard let raw else {
      return []
    }
    if let values = raw as? [String] {
      return values.map { sanitizeYamlScalar($0) }.filter { !$0.isEmpty }
    }
    if let values = raw as? [Any] {
      return values.compactMap { value -> String? in
        if let stringValue = value as? String {
          let normalized = sanitizeYamlScalar(stringValue)
          return normalized.isEmpty ? nil : normalized
        }
        if let numberValue = value as? NSNumber {
          return numberValue.stringValue
        }
        return nil
      }
    }
    guard let rawString = raw as? String else {
      return []
    }
    let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return []
    }
    if
      let data = trimmed.data(using: .utf8),
      let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [Any]
    {
      return parseStringList(jsonArray)
    }
    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
      let inner = String(trimmed.dropFirst().dropLast())
      return inner
        .split(separator: ",")
        .map { sanitizeYamlScalar(String($0)) }
        .filter { !$0.isEmpty }
    }
    return trimmed
      .components(separatedBy: CharacterSet(charactersIn: ",\n"))
      .map { sanitizeYamlScalar($0) }
      .filter { !$0.isEmpty }
  }

  private func sanitizeYamlScalar(_ value: String) -> String {
    var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let hashIndex = result.firstIndex(of: "#") {
      result = String(result[..<hashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if result.hasPrefix("'"), result.hasSuffix("'"), result.count >= 2 {
      result = String(result.dropFirst().dropLast())
    }
    if result.hasPrefix("\""), result.hasSuffix("\""), result.count >= 2 {
      result = String(result.dropFirst().dropLast())
    }
    return result
  }

  private func parseIPv4CIDR(_ cidr: String) -> (address: String, mask: String)? {
    let normalized = sanitizeYamlScalar(cidr)
    if normalized.isEmpty {
      return nil
    }
    let parts = normalized.split(separator: "/", maxSplits: 1).map(String.init)
    let address = parts[0]
    guard isValidIPv4Address(address) else {
      return nil
    }
    let prefix = parts.count > 1 ? Int(parts[1]) ?? 32 : 32
    guard (0...32).contains(prefix) else {
      return nil
    }
    let maskValue: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
    let mask = "\(UInt8((maskValue >> 24) & 0xff)).\(UInt8((maskValue >> 16) & 0xff)).\(UInt8((maskValue >> 8) & 0xff)).\(UInt8(maskValue & 0xff))"
    return (address, mask)
  }

  private func parseIPv6CIDR(_ cidr: String) -> (address: String, prefix: NSNumber)? {
    let normalized = sanitizeYamlScalar(cidr)
    if normalized.isEmpty {
      return nil
    }
    let parts = normalized.split(separator: "/", maxSplits: 1).map(String.init)
    let address = parts[0]
    guard isValidIPv6Address(address) else {
      return nil
    }
    let prefix = parts.count > 1 ? Int(parts[1]) ?? 128 : 128
    guard (0...128).contains(prefix) else {
      return nil
    }
    return (address, NSNumber(value: prefix))
  }

  private func parseIPv4Route(_ cidr: String) -> NEIPv4Route? {
    guard let parsed = parseIPv4CIDR(cidr) else {
      return nil
    }
    if parsed.address == "0.0.0.0", parsed.mask == "0.0.0.0" {
      return NEIPv4Route.default()
    }
    return NEIPv4Route(destinationAddress: parsed.address, subnetMask: parsed.mask)
  }

  private func parseIPv6Route(_ cidr: String) -> NEIPv6Route? {
    guard let parsed = parseIPv6CIDR(cidr) else {
      return nil
    }
    if parsed.address == "::", parsed.prefix.intValue == 0 {
      return NEIPv6Route.default()
    }
    return NEIPv6Route(destinationAddress: parsed.address, networkPrefixLength: parsed.prefix)
  }

  private func normalizeDnsServers(_ servers: [String]) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for rawServer in servers {
      guard let extracted = extractDnsHost(rawServer) else {
        continue
      }
      let normalized = extracted.lowercased()
      if seen.contains(normalized) {
        continue
      }
      seen.insert(normalized)
      result.append(extracted)
    }
    return result
  }

  private func extractDnsHost(_ raw: String) -> String? {
    var candidate = sanitizeYamlScalar(raw)
    if candidate.isEmpty || candidate.lowercased() == "system" {
      return nil
    }
    if let hashIndex = candidate.firstIndex(of: "#") {
      candidate = String(candidate[..<hashIndex])
    }
    candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    if candidate.isEmpty {
      return nil
    }
    if candidate.contains("://"), let url = URL(string: candidate), let host = url.host {
      candidate = host
    }
    if candidate.hasPrefix("["),
       let closing = candidate.firstIndex(of: "]") {
      candidate = String(candidate[candidate.index(after: candidate.startIndex)..<closing])
    } else if candidate.filter({ $0 == ":" }).count == 1 {
      let parts = candidate.split(separator: ":", maxSplits: 1).map(String.init)
      if parts.count == 2, Int(parts[1]) != nil {
        candidate = parts[0]
      }
    }
    candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    if candidate.isEmpty {
      return nil
    }
    if isValidIPv4Address(candidate) || isValidIPv6Address(candidate) {
      return candidate
    }
    let hostPattern = #"^[A-Za-z0-9.-]+$"#
    let validHost = candidate.range(of: hostPattern, options: .regularExpression) != nil
    return validHost ? candidate : nil
  }

  private func isValidIPv4Address(_ value: String) -> Bool {
    var addr = in_addr()
    return value.withCString { inet_pton(AF_INET, $0, &addr) } == 1
  }

  private func isValidIPv6Address(_ value: String) -> Bool {
    var addr = in6_addr()
    return value.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
  }

  fileprivate func protectSocket(fd: Int64, network: String?, address: String?) -> Bool {
    let socketFD = Int32(fd)
    guard socketFD > 0 else {
      return false
    }
    guard let interfaceIndex = activePhysicalInterfaceIndex() else {
      return true
    }

    let networkHint = (network ?? "").lowercased()
    let addressHint = (address ?? "").lowercased()
    let preferIPv6 = networkHint.contains("6") || addressHint.contains(":")
    let preferIPv4 = networkHint.contains("4") || (addressHint.contains(".") && !addressHint.contains(":"))

    var protected = false
    if !preferIPv6 {
      protected = bindSocketToInterface(
        fd: socketFD,
        level: Int32(IPPROTO_IP),
        option: CInt(IP_BOUND_IF),
        interfaceIndex: interfaceIndex
      ) || protected
    }
    if !preferIPv4 {
      protected = bindSocketToInterface(
        fd: socketFD,
        level: Int32(IPPROTO_IPV6),
        option: CInt(IPV6_BOUND_IF),
        interfaceIndex: interfaceIndex
      ) || protected
    }
    if preferIPv4 || preferIPv6 {
      if preferIPv4 {
        protected = bindSocketToInterface(
          fd: socketFD,
          level: Int32(IPPROTO_IP),
          option: CInt(IP_BOUND_IF),
          interfaceIndex: interfaceIndex
        ) || protected
      }
      if preferIPv6 {
        protected = bindSocketToInterface(
          fd: socketFD,
          level: Int32(IPPROTO_IPV6),
          option: CInt(IPV6_BOUND_IF),
          interfaceIndex: interfaceIndex
        ) || protected
      }
    }
    return protected
  }

  private func activePhysicalInterfaceIndex() -> UInt32? {
    let interfaces = activeInterfaceNames()
    guard !interfaces.isEmpty else {
      return nil
    }
    if let index = resolveInterfaceIndex(
      from: interfaces,
      matchingPrefixes: ["en"]
    ) {
      return index
    }
    if let index = resolveInterfaceIndex(
      from: interfaces,
      matchingPrefixes: ["pdp_ip", "pdp-ip"]
    ) {
      return index
    }
    if let index = resolveInterfaceIndex(
      from: interfaces,
      matchingPrefixes: ["en", "pdp_ip", "pdp-ip", "bridge"]
    ) {
      return index
    }
    if let fallback = interfaces.first,
       let index = interfaceIndex(named: fallback) {
      return index
    }
    return nil
  }

  private func activeInterfaceNames() -> [String] {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else {
      return []
    }
    defer { freeifaddrs(pointer) }

    var result: [String] = []
    var seen = Set<String>()
    var current: UnsafeMutablePointer<ifaddrs>? = first

    while let interface = current {
      let flags = Int32(interface.pointee.ifa_flags)
      let isUp = (flags & IFF_UP) != 0
      let isRunning = (flags & IFF_RUNNING) != 0
      if isUp, isRunning, let cName = interface.pointee.ifa_name {
        let name = String(cString: cName)
        let lowercased = name.lowercased()
        if !lowercased.hasPrefix("lo"),
           !lowercased.hasPrefix("utun"),
           !seen.contains(name) {
          seen.insert(name)
          result.append(name)
        }
      }
      current = interface.pointee.ifa_next
    }

    return result
  }

  private func resolveInterfaceIndex(from names: [String], matchingPrefixes prefixes: [String]) -> UInt32? {
    for prefix in prefixes {
      if let name = names.first(where: { $0.lowercased().hasPrefix(prefix.lowercased()) }),
         let index = interfaceIndex(named: name) {
        return index
      }
    }
    return nil
  }

  private func interfaceIndex(named name: String) -> UInt32? {
    name.withCString { cName in
      let index = if_nametoindex(cName)
      return index == 0 ? nil : index
    }
  }

  private func bindSocketToInterface(
    fd: Int32,
    level: Int32,
    option: CInt,
    interfaceIndex: UInt32
  ) -> Bool {
    var idx = interfaceIndex
    let applied = withUnsafePointer(to: &idx) { ptr -> Bool in
      setsockopt(fd, level, option, ptr, socklen_t(MemoryLayout<UInt32>.size)) == 0
    }
    return applied
  }

  private func resolveTunnelFileDescriptor() throws -> Int {
    if let value = scanTunnelFileDescriptor(), value > 0 {
      return value
    }
    if let rawValue = packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int {
      if rawValue > 0 && isTunnelFileDescriptor(rawValue) {
        return rawValue
      }
    }
    throw NSError(domain: "PacketTunnel", code: -2, userInfo: [
      NSLocalizedDescriptionKey: "failed to resolve tunnel file descriptor: utun fd unavailable"
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
      let snapshot = refreshTrafficOnly(appGroupId: appGroupId)
      let payload = """
      {"up":\(snapshot.up),"down":\(snapshot.down)}
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

  @discardableResult
  private func refreshTrafficOnly(appGroupId: String) -> TrafficSnapshot {
    let snapshot = currentTrafficSnapshot()
    let now = Date().timeIntervalSince1970
    let shouldPersist = snapshot != lastPersistedTrafficSnapshot ||
      now - lastPersistedTrafficAt >= 2.0
    guard shouldPersist else {
      return snapshot
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
    return snapshot
  }

  private func currentTrafficSnapshot() -> TrafficSnapshot {
    let up = Int64(MobileTrafficUp())
    let down = Int64(MobileTrafficDown())
    let status = started ? "running" : "stopped"
    let mode = started ? MobileGetMode() : ""
    return TrafficSnapshot(
      status: status,
      running: started,
      mode: mode,
      up: up,
      down: down
    )
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
    } catch {}
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

private final class PacketTunnelSocketProtector: NSObject, MobileSocketProtectorProtocol {
  private weak var provider: PacketTunnelProvider?

  init(provider: PacketTunnelProvider) {
    self.provider = provider
  }

  func markSocket(_ fd: Int64, network: String?, address: String?) -> Bool {
    provider?.protectSocket(fd: fd, network: network, address: address) ?? true
  }

  func protectSocket(_ fd: Int64, network: String?, address: String?) -> Bool {
    provider?.protectSocket(fd: fd, network: network, address: address) ?? true
  }
}

private final class PacketTunnelTunOpener: NSObject, MobileTunOpenerProtocol {
  private weak var provider: PacketTunnelProvider?

  init(provider: PacketTunnelProvider) {
    self.provider = provider
  }

  func openTun(_ options: MobileTunOptions?) -> Int64 {
    provider?.openTun(options: options) ?? -1
  }
}
