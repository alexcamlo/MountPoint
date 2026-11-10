import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import MountPointCore
import Network
import NetFS
import Security

// MARK: - Persistence (~/Library/Application Support/Mount Point)

enum Storage {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Mount Point", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let configURL = dir.appendingPathComponent("mountpoint-config.json")
    static let logURL = dir.appendingPathComponent("mountpoint-log.json")

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Atomic write; throws so callers never think a failed save succeeded.
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(value).write(to: url, options: .atomic)
    }
}

// MARK: - Keychain (generic password per server id)

enum Keychain {
    private static let service = "Mount Point"

    private static func query(_ serverId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: serverId]
    }

    static func set(_ password: String, for serverId: String) throws {
        SecItemDelete(query(serverId) as CFDictionary)
        var q = query(serverId)
        q[kSecValueData as String] = Data(password.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not save password to Keychain (\(status))"])
        }
    }

    static func get(_ serverId: String) -> String? {
        var q = query(serverId)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ serverId: String) {
        SecItemDelete(query(serverId) as CFDictionary)
    }
}

// MARK: - Network state

/// SSID via CoreWLAN. macOS redacts it without Location permission → reported as unknown.
func currentNetworkState() -> NetworkState {
    var state = NetworkState(ssidUnknown: true, vpnConnected: vpnActive())
    guard let iface = CWWiFiClient.shared().interface() else { return state }
    if let ssid = iface.ssid() {
        state.ssid = ssid
        state.ssidUnknown = false
    } else {
        // nil SSID is only trustworthy ("not on Wi-Fi") when we're allowed to see it.
        let auth = CLLocationManager().authorizationStatus
        state.ssidUnknown = !(auth == .authorizedAlways || auth == .authorized)
    }
    return state
}

/// A VPN looks like a utun/ppp/ipsec interface with an IPv4 address.
/// (macOS keeps several utun interfaces with only IPv6 link-local addresses; those don't count.)
func vpnActive() -> Bool {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return false }
    defer { freeifaddrs(head) }
    var p = head
    while let ifa = p {
        defer { p = ifa.pointee.ifa_next }
        let name = String(cString: ifa.pointee.ifa_name)
        guard ["utun", "ppp", "ipsec"].contains(where: name.hasPrefix),
              let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
              (ifa.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
        return true
    }
    return false
}

// MARK: - Probes

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
}

func checkPort(host: String, port: Int, timeout: TimeInterval = 3) async -> (open: Bool, latencyMs: Int?, denied: Bool) {
    guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), !host.isEmpty else { return (false, nil, false) }
    let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
    let start = Date()
    return await withCheckedContinuation { cont in
        let once = Once()
        let finish: @Sendable (Bool) -> Void = { open in
            guard once.fire() else { return }
            let denied = conn.currentPath?.unsatisfiedReason == .localNetworkDenied
            conn.cancel()
            cont.resume(returning: (open, open ? Int(Date().timeIntervalSince(start) * 1000) : nil, denied))
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .waiting, .cancelled: finish(false)
            default: break
            }
        }
        conn.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
    }
}

/// Runs a system binary off the main thread; returns its exit status.
func run(_ path: String, _ args: [String]) async -> Int32 {
    await withCheckedContinuation { cont in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
        do { try proc.run() } catch { cont.resume(returning: -1) }
    }
}

func pingHost(_ host: String) async -> Bool {
    guard !host.isEmpty, !host.hasPrefix("-") else { return false }
    return await run("/sbin/ping", ["-c", "1", "-W", "2000", "-t", "3", host]) == 0
}

func probeServer(host: String, port: Int) async -> ProbeResult {
    async let portRes = checkPort(host: host, port: port)
    async let reachable = pingHost(host)
    let (pr, ping) = await (portRes, reachable)
    return ProbeResult(hostReachable: ping || pr.open, portOpen: pr.open, latencyMs: pr.latencyMs,
                       localNetworkDenied: pr.denied)
}

// MARK: - Mounting (NetFS)

/// Currently mounted network volumes, read from the kernel mount table.
/// MNT_NOWAIT: never touches the network, so a dead server can't block the caller.
func listNetworkMounts() -> [MountedVolume] {
    var buf: UnsafeMutablePointer<statfs>?
    let n = getmntinfo_r_np(&buf, MNT_NOWAIT)
    guard n > 0, let buf else { return [] }
    defer { free(buf) }
    let stats = Array(UnsafeBufferPointer(start: buf, count: Int(n)))
    return stats.compactMap { st in
        var st = st
        func str<T>(_ field: inout T) -> String {
            withUnsafeBytes(of: &field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        return parseNetworkMount(source: str(&st.f_mntfromname), fsType: str(&st.f_fstypename),
                                 mountPoint: str(&st.f_mntonname))
    }
}

struct MountOutcome { var ok: Bool; var mountPoint: String?; var error: String? }

func mount(_ server: Server, _ share: Share) async -> MountOutcome {
    if let mp = findMountPoint(listNetworkMounts(), server, share) { return .init(ok: true, mountPoint: mp) }
    guard let url = mountURL(server, share) else { return .init(ok: false, error: "Invalid server address") }

    var user: String?
    var password: String?
    let openOptions = NSMutableDictionary()
    // Lets macOS show its own auth dialog (and read saved Keychain creds) when needed.
    openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI
    if server.authMode == .guest {
        openOptions[kNetFSUseGuestKey] = true
    } else {
        user = share.usernameOverride ?? server.username
        if server.hasStoredPassword == true { password = Keychain.get(server.id) }
    }
    let mountOptions = NSMutableDictionary()
    if share.readOnly { mountOptions[kNetFSMountFlagsKey] = MNT_RDONLY }

    let code = await Task.detached { () -> Int32 in
        var mountpoints: Unmanaged<CFArray>?
        let rc = NetFSMountURLSync(url as CFURL, nil, user as CFString?, password as CFString?,
                                   openOptions, mountOptions, &mountpoints)
        mountpoints?.release()
        return rc
    }.value

    // Re-check either way: NetFS can report EEXIST etc. for a mount that's actually there.
    if let mp = findMountPoint(listNetworkMounts(), server, share) { return .init(ok: true, mountPoint: mp) }
    if code == 0 { return .init(ok: false, error: "Mount completed but the volume was not found.") }
    return .init(ok: false, error: mountError(code))
}

private func mountError(_ code: Int32) -> String {
    switch code {
    case ECANCELED, -128: return "Authentication canceled"
    case EAUTH, EACCES, EPERM: return "Incorrect credentials or permission denied"
    case ENOENT: return "Share not found"
    case EHOSTUNREACH, ENETUNREACH, ETIMEDOUT, ECONNREFUSED: return "Server not reachable"
    default:
        let msg = String(cString: strerror(code))
        return code > 0 && !msg.hasPrefix("Unknown") ? "Mount failed: \(msg)" : "Mount failed (error \(code))"
    }
}

func unmount(_ mountPoint: String) async -> MountOutcome {
    do {
        try await FileManager.default.unmountVolume(at: URL(fileURLWithPath: mountPoint), options: [])
        return .init(ok: true)
    } catch {
        let busy = "\(error)".localizedCaseInsensitiveContains("busy") || (error as NSError).code == Int(EBUSY)
        return .init(ok: false, error: busy ? "Volume is in use" : "Unmount failed")
    }
}
