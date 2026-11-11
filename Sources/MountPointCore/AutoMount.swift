import Foundation

// The auto-mount decision: one pure pass from gathered facts to runtime + mount queue,
// plus the per-share backoff ledger it consults. No I/O.

/// Per-share retry state, keyed by share id.
public struct BackoffLedger: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var failures = 0
        public var nextAttemptAt = Date.distantPast
        public var lastError: String?
        public init() {}
    }

    public static let base: TimeInterval = 15
    public static let max: TimeInterval = 15 * 60

    private var entries: [String: Entry] = [:]
    public init() {}

    public subscript(shareId: String) -> Entry { entries[shareId] ?? Entry() }

    public mutating func recordSuccess(_ shareId: String) { entries[shareId] = nil }

    /// Delay after the nth consecutive failure: min(15s · 2^(n-1), 15min).
    public mutating func recordFailure(_ shareId: String, error: String?, now: Date) {
        var e = self[shareId]
        e.failures += 1
        e.lastError = error
        e.nextAttemptAt = now + min(Self.base * pow(2, Double(e.failures - 1)), Self.max)
        entries[shareId] = e
    }

    /// Don't auto-remount right after a manual unmount.
    public mutating func suppress(_ shareId: String, now: Date) {
        entries[shareId, default: Entry()].nextAttemptAt = now + Self.base
    }

    public mutating func resetAll() { entries.removeAll() }
}

public struct AutoMountPass: Sendable {
    public var runtime: AppRuntime
    /// Shares to auto-mount now; already shown as pending "Mounting…" in `runtime`.
    public var mountQueue: [(server: Server, share: Share)]
}

/// Derives the full runtime and decides which shares to auto-mount. A share is queued when
/// not paused, behavior is auto, rules pass, port is open, it isn't mounted or in flight,
/// and its backoff window has passed.
public func evaluateAutoMount(config: AppConfig, network: NetworkState, probes: [String: ProbeResult],
                              mounts: [MountedVolume], backoff: BackoffLedger, inFlight: Set<String>,
                              paused: Bool, now: Date) -> AutoMountPass {
    var queue: [(server: Server, share: Share)] = []

    let servers: [ServerRuntime] = config.servers.map { server in
        let probe = probes[server.id] ?? ProbeResult(hostReachable: false, portOpen: false)
        let eval = evaluateRules(server, net: network, probe: probe)
        let shareRuntimes: [ShareRuntime] = config.shares.filter { $0.serverId == server.id }.map { share in
            let b = backoff[share.id]
            var f = ShareFacts()
            f.mountPoint = findMountPoint(mounts, server, share)
            f.mounting = inFlight.contains(share.id)
            f.paused = paused
            f.blocked = eval.blocked
            f.blockedReason = eval.reason
            f.reachable = probe.hostReachable
            f.portOpen = probe.portOpen
            f.failures = b.failures
            f.lastError = b.lastError
            f.nextAttemptAt = b.failures > 0 ? b.nextAttemptAt : nil
            var sr = deriveShareStatus(share, f)

            let eligible = !paused && share.behavior == .auto && !eval.blocked && probe.portOpen
                && f.mountPoint == nil && !f.mounting && now >= b.nextAttemptAt
            if eligible {
                queue.append((server, share))
                sr.status = .pending
                sr.reason = "Mounting…"
            }
            return sr
        }
        return ServerRuntime(
            serverId: server.id,
            status: deriveServerStatus(reachable: probe.hostReachable, portOpen: probe.portOpen,
                                       blocked: eval.blocked, shares: shareRuntimes),
            hostReachable: probe.hostReachable, portOpen: probe.portOpen, latencyMs: probe.latencyMs,
            rules: eval.results, blockedReason: eval.blocked ? eval.reason : nil, shares: shareRuntimes)
    }

    var rt = AppRuntime()
    rt.overall = deriveOverallStatus(servers, paused: paused)
    rt.paused = paused
    rt.network = network
    rt.servers = servers
    return AutoMountPass(runtime: rt, mountQueue: queue)
}
