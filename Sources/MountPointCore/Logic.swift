import Foundation

// Pure ports of rule-engine.ts, runtime-derivation.ts and the mount matching in
// mount-manager.ts. No I/O.

public struct RuleEvaluation: Equatable, Sendable {
    public var results: [RuleResult]
    public var blocked: Bool
    public var reason: String?
}

/// A server is blocked when any enabled rule fails or can't be verified ("unknown").
public func evaluateRules(_ server: Server, net: NetworkState, probe: ProbeResult) -> RuleEvaluation {
    let r = server.rules
    var results: [RuleResult] = []

    if !r.wifiSSID.enabled {
        results.append(.init(key: .wifiSSID, label: "Wi-Fi network", state: .disabled))
    } else if net.ssidUnknown {
        results.append(.init(key: .wifiSSID, label: "Wi-Fi network", state: .unknown,
                             detail: "SSID unavailable (Location permission may be required)"))
    } else {
        let current = net.ssid ?? ""
        let match = r.wifiSSID.ssids.contains { $0.caseInsensitiveCompare(current) == .orderedSame }
        results.append(.init(key: .wifiSSID, label: "Wi-Fi network", state: match ? .pass : .fail,
                             detail: match ? current : current.isEmpty ? "Not on Wi-Fi" : "On \"\(current)\""))
    }

    if !r.vpnConnected.enabled {
        results.append(.init(key: .vpnConnected, label: "VPN connected", state: .disabled))
    } else {
        results.append(.init(key: .vpnConnected, label: "VPN connected",
                             state: net.vpnConnected ? .pass : .fail,
                             detail: net.vpnConnected ? "Connected" : "No VPN detected"))
    }

    if !r.hostReachable.enabled {
        results.append(.init(key: .hostReachable, label: "Host reachable", state: .disabled))
    } else {
        results.append(.init(key: .hostReachable, label: "Host reachable",
                             state: probe.hostReachable ? .pass : .fail,
                             detail: probe.hostReachable ? "Responding" : probe.localNetworkDenied ? deniedDetail : "No response"))
    }

    if !r.portOpen.enabled {
        results.append(.init(key: .portOpen, label: "Service available", state: .disabled))
    } else {
        results.append(.init(key: .portOpen, label: "Service available",
                             state: probe.portOpen ? .pass : .fail,
                             detail: probe.portOpen ? "Port \(server.port) open"
                                 : probe.localNetworkDenied ? deniedDetail : "Port \(server.port) closed"))
    }

    let blocking = results.first { $0.state == .fail || $0.state == .unknown }
    let reason: String? = blocking.map {
        if probe.localNetworkDenied && ($0.key == .hostReachable || $0.key == .portOpen) { return "Local Network access denied" }
        return switch $0.key {
        case .wifiSSID: $0.state == .unknown ? "Wi-Fi network unknown" : "Wi-Fi does not match"
        case .vpnConnected: "VPN not connected"
        case .hostReachable: "Server not reachable"
        case .portOpen: "\(server.proto.rawValue.uppercased()) service unavailable"
        }
    }
    return RuleEvaluation(results: results, blocked: blocking != nil, reason: reason)
}

private let deniedDetail = "Blocked by macOS Local Network permission"

public struct ShareFacts: Sendable {
    public var mountPoint: String?
    public var mounting = false
    public var paused = false
    public var blocked = false
    public var blockedReason: String?
    public var reachable = true
    public var portOpen = true
    public var failures = 0
    public var lastError: String?
    public var nextAttemptAt: Date?
    public init() {}
}

/// Priority (first hit wins): mounted → pending → manual-only → paused → rule-blocked →
/// unreachable → port closed → failed (backoff) → waiting.
public func deriveShareStatus(_ share: Share, _ f: ShareFacts) -> ShareRuntime {
    let id = share.id
    if let mp = f.mountPoint { return .init(shareId: id, status: .mounted, mountPoint: mp) }
    if f.mounting { return .init(shareId: id, status: .pending, reason: "Mounting…") }
    if share.behavior == .manual { return .init(shareId: id, status: .manualOnly, reason: "Manual mount only") }
    if f.paused { return .init(shareId: id, status: .blocked, reason: "Automatic mounting paused") }
    if f.blocked { return .init(shareId: id, status: .blocked, reason: f.blockedReason ?? "Rule not met") }
    if !f.reachable { return .init(shareId: id, status: .notMounted, reason: "Server not reachable") }
    if !f.portOpen { return .init(shareId: id, status: .notMounted, reason: "Service unavailable") }
    if f.failures > 0 {
        return .init(shareId: id, status: .failed, reason: f.lastError ?? "Mount failed",
                     nextAttemptAt: f.nextAttemptAt)
    }
    return .init(shareId: id, status: .notMounted, reason: "Waiting to mount")
}

public func deriveServerStatus(reachable: Bool, portOpen: Bool, blocked: Bool,
                               shares: [ShareRuntime]) -> ServerStatus {
    if !reachable { return .unavailable }
    if !portOpen { return .reachable }
    if blocked { return .ruleBlocked }
    if shares.contains(where: { $0.status == .pending }) { return .mounting }
    if shares.contains(where: { $0.status == .failed }) { return .error }
    if shares.contains(where: { $0.status == .mounted }) { return .mounted }
    return .serviceAvailable
}

public func deriveOverallStatus(_ servers: [ServerRuntime], paused: Bool) -> OverallStatus {
    if paused { return .paused }
    let all = servers.flatMap(\.shares)
    if all.isEmpty { return .idle }
    let mounted = all.filter { $0.status == .mounted }.count
    if !servers.contains(where: \.hostReachable) && mounted == 0 { return .unavailable }
    if all.contains(where: { $0.status == .failed || $0.status == .pending }) { return .partial }
    let autoNotMounted = all.filter { $0.status == .notMounted }.count
    if mounted > 0 && autoNotMounted == 0 { return .allMounted }
    if mounted > 0 { return .partial }
    return .idle
}

// MARK: - Mount URLs & matching

public struct MountedVolume: Equatable, Sendable {
    public var host: String
    public var share: String
    public var mountPoint: String
    public init(host: String, share: String, mountPoint: String) {
        self.host = host; self.share = share; self.mountPoint = mountPoint
    }
}

/// Remote URL to hand to NetFS, e.g. smb://nas.local/media or https://host:8443/dav.
public func mountURL(_ server: Server, _ share: Share) -> URL? {
    var c = URLComponents()
    switch server.proto {
    case .webdav: c.scheme = server.port == 80 ? "http" : "https"
    default: c.scheme = server.proto.rawValue
    }
    c.host = server.host
    let defaultPort = server.proto == .webdav ? (server.port == 80 ? 80 : 443) : server.proto.defaultPort
    if server.port != defaultPort { c.port = server.port }
    let path = share.sharePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    c.path = "/" + path // URLComponents percent-encodes each segment
    return c.url
}

/// Parses a kernel mount source (statfs f_mntfromname) for a network filesystem:
/// smbfs/afpfs "//user@host/share", webdav "https://host/path", nfs "host:/export".
/// Returns nil for local filesystems.
public func parseNetworkMount(source: String, fsType: String, mountPoint: String) -> MountedVolume? {
    guard ["smbfs", "afpfs", "nfs", "webdav", "ftp"].contains(fsType) else { return nil }
    var rest = source
    if let r = rest.range(of: "://") { rest = String(rest[r.upperBound...]) }
    else if rest.hasPrefix("//") { rest = String(rest.dropFirst(2)) }
    else if fsType == "nfs", let colon = rest.firstIndex(of: ":") { // host:/export
        let share = rest[rest.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return MountedVolume(host: String(rest[..<colon]), share: share, mountPoint: mountPoint)
    }
    let slash = rest.firstIndex(of: "/") ?? rest.endIndex
    var authority = rest[..<slash]
    if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
    let host = authority.split(separator: ":").first.map(String.init) ?? ""
    let path = rest[slash...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !host.isEmpty else { return nil }
    return MountedVolume(host: host.removingPercentEncoding ?? host,
                         share: path.removingPercentEncoding ?? path, mountPoint: mountPoint)
}

/// A snapshot of the mounted network volumes.
public struct MountTable: Equatable, Sendable {
    public var volumes: [MountedVolume]
    public init(_ volumes: [MountedVolume]) { self.volumes = volumes }

    /// Mount point of `share` if mounted. Lenient host match: short name vs FQDN
    /// (nas vs nas.local, either direction), but only at a label boundary.
    public func mountPoint(for server: Server, share: Share) -> String? {
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
        let wantHost = norm(server.host)
        let wantFull = norm(share.sharePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        let wantShare = wantFull.split(separator: "/").last.map(String.init) ?? wantFull
        return volumes.first { m in
            let h = norm(m.host), s = norm(m.share)
            let hostMatch = !h.isEmpty && !wantHost.isEmpty
                && (h == wantHost || h.hasPrefix(wantHost + ".") || wantHost.hasPrefix(h + "."))
            return hostMatch && (s == wantShare || s == wantFull)
        }?.mountPoint
    }
}

/// Compatibility shim for `MountTable.mountPoint(for:share:)`.
public func findMountPoint(_ mounts: [MountedVolume], _ server: Server, _ share: Share) -> String? {
    MountTable(mounts).mountPoint(for: server, share: share)
}
