import AppKit
import CoreLocation
import Foundation
import MountPointCore
import ServiceManagement
import UniformTypeIdentifiers

/// The control loop (port of orchestrator.ts + config-commits.ts + logger-store.ts):
/// probe → evaluate rules → auto-mount, with per-share exponential backoff.
final class AppModel: ObservableObject {
    @Published private(set) var config: AppConfig
    @Published private(set) var runtime = AppRuntime()
    @Published private(set) var logs: [LogEntry] // oldest first, like the JSON file

    private struct Backoff { var failures = 0; var nextAttemptAt = Date.distantPast; var lastError: String? }
    private static let backoffBase: TimeInterval = 15
    private static let backoffMax: TimeInterval = 15 * 60
    private static let maxLogs = 500

    private var backoff: [String: Backoff] = [:]
    private var inFlight: Set<String> = []
    private var evaluating = false
    private var rerunRequested = false
    private var timer: Timer?
    private var warnedLocalNetwork = false
    private let location = CLLocationManager()

    init() {
        config = Storage.read(AppConfig.self, from: Storage.configURL) ?? AppConfig()
        logs = Storage.read([LogEntry].self, from: Storage.logURL) ?? []

        DispatchQueue.main.async { [weak self] in self?.applyDock() } // NSApp isn't ready during App.init
        if config.settings.launchAtLogin { applyLoginItem() }
        requestLocationIfNeeded()
        restartTimer()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.addLog(.info, "System woke — re-evaluating mounts")
                self?.backoff.removeAll()
                self?.refresh()
            }
        }
        refresh()
    }

    // MARK: Lookup

    func server(_ id: String) -> Server? { config.servers.first { $0.id == id } }
    func shares(of serverId: String) -> [Share] { config.shares.filter { $0.serverId == serverId } }
    func serverRuntime(_ id: String) -> ServerRuntime? { runtime.servers.first { $0.serverId == id } }
    func shareRuntime(_ share: Share) -> ShareRuntime? {
        serverRuntime(share.serverId)?.shares.first { $0.shareId == share.id }
    }

    // MARK: Evaluation loop

    /// Re-evaluate now. Overlapping calls are coalesced into one follow-up run.
    func refresh() {
        if evaluating { rerunRequested = true; return }
        evaluating = true
        Task {
            await evaluateOnce()
            evaluating = false
            if rerunRequested { rerunRequested = false; refresh() }
        }
    }

    private func evaluateOnce() async {
        let cfg = config
        let net = currentNetworkState()
        let probes = await withTaskGroup(of: (String, ProbeResult).self) { group in
            for s in cfg.servers {
                group.addTask { (s.id, await probeServer(host: s.host, port: s.port)) }
            }
            var out: [String: ProbeResult] = [:]
            for await (id, probe) in group { out[id] = probe }
            return out
        }
        if probes.values.contains(where: \.localNetworkDenied), !warnedLocalNetwork {
            warnedLocalNetwork = true
            addLog(.warn, "macOS is blocking Local Network access. Enable Mount Point in System Settings → Privacy & Security → Local Network.")
        }
        let mounts = listNetworkMounts()
        let paused = config.settings.paused // may have changed while probing
        var queue: [(Server, Share)] = []

        let servers: [ServerRuntime] = cfg.servers.map { server in
            let probe = probes[server.id] ?? ProbeResult(hostReachable: false, portOpen: false)
            let eval = evaluateRules(server, net: net, probe: probe)
            let shareRuntimes: [ShareRuntime] = cfg.shares.filter { $0.serverId == server.id }.map { share in
                let b = backoff[share.id] ?? Backoff()
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
                    && f.mountPoint == nil && !f.mounting && Date() >= b.nextAttemptAt
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
        rt.network = net
        rt.servers = servers
        runtime = rt

        if !queue.isEmpty { Task { await processMountQueue(queue) } }
    }

    private func processMountQueue(_ queue: [(Server, Share)]) async {
        for (server, share) in queue where !inFlight.contains(share.id) {
            addLog(.info, "Mounting \"\(share.displayName)\" on \(server.name)…", server.id, share.id)
            _ = await performMount(server, share, manual: false)
        }
        refresh()
    }

    private func performMount(_ server: Server, _ share: Share, manual: Bool) async -> MountOutcome {
        inFlight.insert(share.id)
        defer { inFlight.remove(share.id) }
        let result = await mount(server, share)
        if result.ok {
            backoff[share.id] = Backoff()
            addLog(.info, "Mounted \"\(share.displayName)\" at \(result.mountPoint ?? "?")", server.id, share.id)
        } else {
            var b = backoff[share.id] ?? Backoff()
            b.failures += 1
            b.lastError = result.error
            b.nextAttemptAt = Date() + min(Self.backoffBase * pow(2, Double(b.failures - 1)), Self.backoffMax)
            backoff[share.id] = b
            addLog(.error, "\(manual ? "Manual mount" : "Mount") of \"\(share.displayName)\" failed: \(result.error ?? "unknown error")",
                   server.id, share.id)
        }
        return result
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(10, config.settings.pollIntervalSec))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Manual actions (bypass pause / rules / backoff)

    func manualMount(_ share: Share) {
        guard let server = server(share.serverId), !inFlight.contains(share.id) else { return }
        addLog(.info, "Manual mount of \"\(share.displayName)\" requested", server.id, share.id)
        setPending(share.id)
        Task {
            _ = await performMount(server, share, manual: true)
            refresh()
        }
    }

    func manualUnmount(_ share: Share) {
        guard let server = server(share.serverId) else { return }
        guard let mp = MountTable.current().mountPoint(for: server, share: share) else { refresh(); return }
        // Don't auto-remount right after a manual unmount.
        backoff[share.id, default: Backoff()].nextAttemptAt = Date() + Self.backoffBase
        Task {
            let result = await unmount(mp)
            if result.ok { addLog(.info, "Unmounted \"\(share.displayName)\"", server.id, share.id) }
            else { addLog(.error, "Failed to unmount \"\(share.displayName)\": \(result.error ?? "")", server.id, share.id) }
            refresh()
        }
    }

    func reveal(_ share: Share) {
        guard let server = server(share.serverId),
              let mp = MountTable.current().mountPoint(for: server, share: share) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: mp))
    }

    private func setPending(_ shareId: String) {
        for i in runtime.servers.indices {
            if let j = runtime.servers[i].shares.firstIndex(where: { $0.shareId == shareId }) {
                runtime.servers[i].shares[j].status = .pending
                runtime.servers[i].shares[j].reason = "Mounting…"
            }
        }
    }

    // MARK: Config commits — persist, apply side effects, re-evaluate

    @discardableResult
    private func commit(_ mutate: (inout AppConfig) -> Void) -> Bool {
        let prev = config
        var next = config
        mutate(&next)
        do {
            try Storage.write(next, to: Storage.configURL)
        } catch {
            addLog(.error, "Could not save configuration: \(error.localizedDescription)")
            return false
        }
        config = next
        if next.settings.launchAtLogin != prev.settings.launchAtLogin { applyLoginItem() }
        if next.settings.showInDock != prev.settings.showInDock { applyDock() }
        if next.settings.pollIntervalSec != prev.settings.pollIntervalSec { restartTimer() }
        requestLocationIfNeeded()
        refresh()
        return true
    }

    /// `password`: nil = unchanged, "" = remove, otherwise store in Keychain.
    func saveServer(_ input: Server, password: String?) {
        var server = input
        server.name = server.name.trimmingCharacters(in: .whitespaces)
        server.host = server.host.trimmingCharacters(in: .whitespaces)
        server.username = server.username?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        if server.port <= 0 { server.port = server.proto.defaultPort }
        if let password { server.hasStoredPassword = !password.isEmpty }
        // Config first, credentials after: a failed save never leaves an orphaned secret.
        guard commit({ upsert(&$0.servers, server) }) else { return }
        guard let password else { return }
        if password.isEmpty {
            Keychain.delete(server.id)
        } else {
            do { try Keychain.set(password, for: server.id) } catch {
                addLog(.error, error.localizedDescription, server.id)
                commit { cfg in
                    if let i = cfg.servers.firstIndex(where: { $0.id == server.id }) { cfg.servers[i].hasStoredPassword = false }
                }
            }
        }
    }

    func deleteServer(_ id: String) {
        guard commit({ cfg in
            cfg.servers.removeAll { $0.id == id }
            cfg.shares.removeAll { $0.serverId == id }
        }) else { return }
        Keychain.delete(id)
    }

    func saveShare(_ input: Share) {
        var share = input
        share.sharePath = share.sharePath.trimmingCharacters(in: .whitespaces)
        share.displayName = share.displayName.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? share.sharePath
        share.usernameOverride = share.usernameOverride?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        commit { upsert(&$0.shares, share) }
    }

    func deleteShare(_ id: String) { commit { $0.shares.removeAll { $0.id == id } } }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        commit { mutate(&$0.settings); $0.settings.pollIntervalSec = max(10, $0.settings.pollIntervalSec) }
    }

    func togglePause() {
        let next = !config.settings.paused
        updateSettings { $0.paused = next }
        addLog(.info, next ? "Automatic mounting paused" : "Automatic mounting resumed")
    }

    // MARK: Import / export

    func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mountpoint-config.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var cfg = config
        for i in cfg.servers.indices { cfg.servers[i].hasStoredPassword = false } // secrets never leave the Keychain
        do { try Storage.write(cfg, to: url); addLog(.info, "Exported configuration to \(url.path)") }
        catch { addLog(.error, "Export failed: \(error.localizedDescription)") }
    }

    func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let imported = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            addLog(.error, "Import failed: \(url.lastPathComponent) is not a valid Mount Point configuration")
            return
        }
        for s in config.servers { Keychain.delete(s.id) }
        commit { cfg in
            cfg.servers = imported.servers.map { var s = $0; s.hasStoredPassword = false; return s }
            cfg.shares = imported.shares
            cfg.settings = imported.settings
        }
        addLog(.info, "Imported \(imported.servers.count) server(s) and \(imported.shares.count) share(s)")
    }

    // MARK: Logs

    func addLog(_ level: LogLevel, _ message: String, _ serverId: String? = nil, _ shareId: String? = nil) {
        logs.append(LogEntry(level: level, message: message, serverId: serverId, shareId: shareId))
        if logs.count > Self.maxLogs { logs.removeFirst(logs.count - Self.maxLogs) }
        try? Storage.write(logs, to: Storage.logURL)
    }

    func clearLogs() {
        logs = []
        try? Storage.write(logs, to: Storage.logURL)
    }

    // MARK: System integration

    private func applyDock() {
        NSApp.setActivationPolicy(config.settings.showInDock ? .regular : .accessory)
    }

    private func applyLoginItem() {
        do {
            if config.settings.launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            addLog(.warn, "Could not update login item: \(error.localizedDescription)")
        }
    }

    /// Only ask for Location when an SSID rule needs it (macOS hides the SSID otherwise).
    private func requestLocationIfNeeded() {
        guard config.servers.contains(where: { $0.rules.wifiSSID.enabled }),
              location.authorizationStatus == .notDetermined else { return }
        location.requestWhenInUseAuthorization()
    }
}

private func upsert<T: Identifiable>(_ list: inout [T], _ item: T) {
    if let i = list.firstIndex(where: { $0.id == item.id }) { list[i] = item } else { list.append(item) }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
