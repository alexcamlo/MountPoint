import Foundation
import Testing
import MountPointCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let server = Server(id: "srv1", name: "NAS", host: "nas.local")
private let share = Share(id: "s1", serverId: "srv1", sharePath: "media", displayName: "Media")
private let openProbe = ProbeResult(hostReachable: true, portOpen: true)

private func pass(server: Server = server, backoff: BackoffLedger = BackoffLedger(),
                  paused: Bool = false, now: Date = t0) -> AutoMountPass {
    var cfg = AppConfig()
    cfg.servers = [server]
    cfg.shares = [share]
    return evaluateAutoMount(config: cfg, network: NetworkState(), probes: ["srv1": openProbe], mounts: [],
                             backoff: backoff, inFlight: [], paused: paused, now: now)
}

private func queued(_ p: AutoMountPass) -> [String] { p.mountQueue.map(\.share.id) }

@Test func eligibleShareIsQueuedAndPending() {
    let p = pass()
    #expect(queued(p) == ["s1"])
    let sr = p.runtime.servers[0].shares[0]
    #expect(sr.status == .pending && sr.reason == "Mounting…")
    #expect(p.runtime.servers[0].status == .mounting)
}

@Test func pausedIsNotQueued() {
    let p = pass(paused: true)
    #expect(queued(p).isEmpty)
    #expect(p.runtime.paused && p.runtime.overall == .paused)
}

@Test func blockedRuleIsNotQueued() {
    var s = server
    s.rules.vpnConnected = RuleFlag(enabled: true)
    let p = pass(server: s)
    #expect(queued(p).isEmpty)
    #expect(p.runtime.servers[0].shares[0].reason == "VPN not connected")
}

@Test func backoffWindowRespectedThenQueued() {
    var b = BackoffLedger()
    b.recordFailure("s1", error: "Incorrect credentials", now: t0)
    let during = pass(backoff: b, now: t0 + 14)
    #expect(queued(during).isEmpty)
    let sr = during.runtime.servers[0].shares[0]
    #expect(sr.status == .failed && sr.reason == "Incorrect credentials" && sr.nextAttemptAt == t0 + 15)
    #expect(queued(pass(backoff: b, now: t0 + 15)) == ["s1"])
}

@Test func failureBackoffCurveCapsAt15Minutes() {
    var b = BackoffLedger()
    let delays: [TimeInterval] = (0..<9).map { _ in
        b.recordFailure("s1", error: nil, now: t0)
        return b["s1"].nextAttemptAt.timeIntervalSince(t0)
    }
    #expect(delays == [15, 30, 60, 120, 240, 480, 900, 900, 900])
    #expect(b["s1"].failures == 9)
    b.recordSuccess("s1")
    #expect(b["s1"] == BackoffLedger.Entry())
}

@Test func manualUnmountSuppressesBriefly() {
    var b = BackoffLedger()
    b.suppress("s1", now: t0)
    #expect(b["s1"].failures == 0)
    let during = pass(backoff: b, now: t0 + 10)
    #expect(queued(during).isEmpty)
    #expect(during.runtime.servers[0].shares[0].reason == "Waiting to mount")
    #expect(queued(pass(backoff: b, now: t0 + 15)) == ["s1"])
}

@Test func resetAllClearsBackoff() {
    var b = BackoffLedger()
    b.recordFailure("s1", error: "x", now: t0)
    b.resetAll()
    #expect(b == BackoffLedger())
    #expect(queued(pass(backoff: b, now: t0)) == ["s1"])
}
