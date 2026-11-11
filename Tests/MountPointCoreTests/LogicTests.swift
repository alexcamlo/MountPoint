import Foundation
import Testing
@testable import MountPointCore

private let autoShare = Share(id: "s1", serverId: "srv1", sharePath: "media", displayName: "Media")
private var manualShare: Share { var s = autoShare; s.id = "s2"; s.behavior = .manual; return s }

private func facts(_ edit: (inout ShareFacts) -> Void = { _ in }) -> ShareFacts {
    var f = ShareFacts(); edit(&f); return f
}

@Test func mountedShortCircuits() {
    let sr = deriveShareStatus(autoShare, facts {
        $0.mountPoint = "/Volumes/media"; $0.paused = true; $0.blocked = true; $0.reachable = false
    })
    #expect(sr == ShareRuntime(shareId: "s1", status: .mounted, mountPoint: "/Volumes/media"))
}

@Test func pendingBeatsManualPausedBlocked() {
    let sr = deriveShareStatus(manualShare, facts { $0.mounting = true; $0.paused = true; $0.blocked = true })
    #expect(sr.status == .pending)
}

@Test func statusPriority() {
    #expect(deriveShareStatus(manualShare, facts()).status == .manualOnly)
    #expect(deriveShareStatus(autoShare, facts { $0.paused = true; $0.blocked = true }).reason == "Automatic mounting paused")
    #expect(deriveShareStatus(autoShare, facts { $0.blocked = true; $0.blockedReason = "VPN not connected" }).reason == "VPN not connected")
    #expect(deriveShareStatus(autoShare, facts { $0.reachable = false }).reason == "Server not reachable")
    #expect(deriveShareStatus(autoShare, facts { $0.failures = 2; $0.lastError = "Incorrect credentials" }).status == .failed)
    #expect(deriveShareStatus(autoShare, facts()).reason == "Waiting to mount")
}

@Test func overallStatus() {
    func srv(_ shares: [ShareStatus], reachable: Bool = true) -> ServerRuntime {
        ServerRuntime(serverId: "x", status: .serviceAvailable, hostReachable: reachable, portOpen: true,
                      shares: shares.enumerated().map { ShareRuntime(shareId: "\($0.offset)", status: $0.element) })
    }
    #expect(deriveOverallStatus([srv([.mounted])], paused: true) == .paused)
    #expect(deriveOverallStatus([], paused: false) == .idle)
    #expect(deriveOverallStatus([srv([.notMounted], reachable: false)], paused: false) == .unavailable)
    #expect(deriveOverallStatus([srv([.mounted, .manualOnly])], paused: false) == .allMounted)
    #expect(deriveOverallStatus([srv([.mounted, .notMounted])], paused: false) == .partial)
    #expect(deriveOverallStatus([srv([.mounted, .failed])], paused: false) == .partial)
}

@Test func rulesBlockOnUnknownSSID() {
    var server = Server(id: "srv1", name: "NAS", host: "nas.local")
    server.rules.wifiSSID = SSIDRule(enabled: true, ssids: ["Home"])
    let probe = ProbeResult(hostReachable: true, portOpen: true)

    let unknown = evaluateRules(server, net: NetworkState(ssidUnknown: true), probe: probe)
    #expect(unknown.blocked && unknown.reason == "Wi-Fi network unknown")

    let match = evaluateRules(server, net: NetworkState(ssid: "home", ssidUnknown: false), probe: probe)
    #expect(!match.blocked)

    let closed = evaluateRules(server, net: NetworkState(ssid: "Home", ssidUnknown: false),
                               probe: ProbeResult(hostReachable: true, portOpen: false))
    #expect(closed.reason == "SMB service unavailable")
}

@Test func mountURLAndMatching() {
    let server = Server(host: "nas.local", proto: .smb, port: 445)
    let share = Share(serverId: server.id, sharePath: "/home/My Docs")
    #expect(mountURL(server, share)?.absoluteString == "smb://nas.local/home/My%20Docs")

    var dav = server; dav.proto = .webdav; dav.port = 8443
    #expect(mountURL(dav, share)?.absoluteString == "https://nas.local:8443/home/My%20Docs")

    let mounts = [MountedVolume(host: "NAS.local", share: "My Docs", mountPoint: "/Volumes/My Docs")]
    #expect(findMountPoint(mounts, server, share) == "/Volumes/My Docs")
    #expect(findMountPoint(mounts, Server(host: "other"), share) == nil)
    #expect(findMountPoint([MountedVolume(host: "", share: "My Docs", mountPoint: "/x")], server, share) == nil)
}

@Test func hostMatchStopsAtLabelBoundary() {
    let share = Share(serverId: "x", sharePath: "media")
    func mp(mounted: String, configured: String) -> String? {
        MountTable([MountedVolume(host: mounted, share: "media", mountPoint: "/m")])
            .mountPoint(for: Server(host: configured), share: share)
    }
    #expect(mp(mounted: "nas", configured: "nas2.local") == nil)
    #expect(mp(mounted: "n", configured: "nas.local") == nil)
    #expect(mp(mounted: "nas2.local", configured: "nas") == nil)
    #expect(mp(mounted: "nas", configured: "nas.local") == "/m")
    #expect(mp(mounted: "nas.local", configured: "nas") == "/m")
    #expect(mp(mounted: "NAS", configured: "nas.Local") == "/m")
}

@Test func decodesPartialConfig() throws {
    let json = """
    {"version":1,"servers":[{"id":"a","name":"NAS","host":"nas.local","protocol":"smb","port":445,
     "authMode":"native","hasStoredPassword":true,"rules":{"wifiSSID":{"enabled":true,"ssids":["H"]}}}],
     "shares":[{"id":"b","serverId":"a","sharePath":"media","displayName":"Media","behavior":"auto","readOnly":false}],
     "settings":{"paused":false,"pollIntervalSec":5}}
    """
    let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    #expect(cfg.servers[0].rules.wifiSSID.ssids == ["H"])
    #expect(cfg.servers[0].rules.portOpen.enabled) // default filled in
    #expect(cfg.settings.pollIntervalSec == 10)    // clamped
    #expect(cfg.shares.count == 1)
}

@Test func localNetworkDeniedIsExplained() {
    let server = Server(id: "srv1", name: "NAS", host: "10.0.0.2")
    let e = evaluateRules(server, net: NetworkState(ssidUnknown: false),
                          probe: ProbeResult(hostReachable: false, portOpen: false, localNetworkDenied: true))
    #expect(e.reason == "Local Network access denied")
    #expect(e.results.first { $0.key == .portOpen }?.detail == "Blocked by macOS Local Network permission")
}

@Test func parsesKernelMountSources() {
    #expect(parseNetworkMount(source: "//win@10.1.1.122/Cachy-Dev", fsType: "smbfs", mountPoint: "/Volumes/Cachy-Dev")
            == MountedVolume(host: "10.1.1.122", share: "Cachy-Dev", mountPoint: "/Volumes/Cachy-Dev"))
    #expect(parseNetworkMount(source: "//DOM;me@nas.local:4450/My%20Docs", fsType: "smbfs", mountPoint: "/m")?.share == "My Docs")
    #expect(parseNetworkMount(source: "https://dav.example.com/remote/files", fsType: "webdav", mountPoint: "/m")?.host == "dav.example.com")
    #expect(parseNetworkMount(source: "nas:/export/media", fsType: "nfs", mountPoint: "/m")
            == MountedVolume(host: "nas", share: "export/media", mountPoint: "/m"))
    #expect(parseNetworkMount(source: "/dev/disk3s1", fsType: "apfs", mountPoint: "/") == nil)
}
