import Foundation

// Persisted as mountpoint-config.json / mountpoint-log.json. Decoding is lenient:
// missing fields fall back to defaults, so older or hand-edited files still load.

public enum NetProtocol: String, Codable, CaseIterable, Sendable {
    case smb, webdav, nfs, afp, ftp

    public var defaultPort: Int {
        switch self {
        case .smb: 445
        case .webdav: 443
        case .nfs: 2049
        case .afp: 548
        case .ftp: 21
        }
    }
}

public enum AuthMode: String, Codable, CaseIterable, Sendable { case native, guest }
public enum MountBehavior: String, Codable, CaseIterable, Sendable { case auto, manual }

public struct RuleFlag: Codable, Equatable, Sendable {
    public var enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

public struct SSIDRule: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var ssids: [String]
    public init(enabled: Bool, ssids: [String]) { self.enabled = enabled; self.ssids = ssids }
}

public struct ServerRules: Codable, Equatable, Sendable {
    public var wifiSSID = SSIDRule(enabled: false, ssids: [])
    public var vpnConnected = RuleFlag(enabled: false)
    public var hostReachable = RuleFlag(enabled: true)
    public var portOpen = RuleFlag(enabled: true)

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ServerRules()
        wifiSSID = (try? c.decodeIfPresent(SSIDRule.self, forKey: .wifiSSID)) ?? d.wifiSSID
        vpnConnected = (try? c.decodeIfPresent(RuleFlag.self, forKey: .vpnConnected)) ?? d.vpnConnected
        hostReachable = (try? c.decodeIfPresent(RuleFlag.self, forKey: .hostReachable)) ?? d.hostReachable
        portOpen = (try? c.decodeIfPresent(RuleFlag.self, forKey: .portOpen)) ?? d.portOpen
    }
}

public struct Server: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var proto: NetProtocol
    public var port: Int
    public var authMode: AuthMode
    public var username: String?
    /// True when a password for this server is in the Keychain.
    public var hasStoredPassword: Bool?
    public var rules: ServerRules

    enum CodingKeys: String, CodingKey {
        case id, name, host, proto = "protocol", port, authMode, username, hasStoredPassword, rules
    }

    public init(id: String = "srv-\(UUID().uuidString.prefix(8).lowercased())", name: String = "",
                host: String = "", proto: NetProtocol = .smb, port: Int = 445,
                authMode: AuthMode = .native, username: String? = nil,
                hasStoredPassword: Bool? = false, rules: ServerRules = ServerRules()) {
        self.id = id; self.name = name; self.host = host; self.proto = proto; self.port = port
        self.authMode = authMode; self.username = username
        self.hasStoredPassword = hasStoredPassword; self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decode(String.self, forKey: .host)
        proto = (try? c.decodeIfPresent(NetProtocol.self, forKey: .proto)) ?? .smb
        let p = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? nil
        port = (p ?? 0) > 0 ? p! : proto.defaultPort
        authMode = (try? c.decodeIfPresent(AuthMode.self, forKey: .authMode)) ?? .native
        username = try c.decodeIfPresent(String.self, forKey: .username)
        hasStoredPassword = try c.decodeIfPresent(Bool.self, forKey: .hasStoredPassword)
        rules = (try? c.decodeIfPresent(ServerRules.self, forKey: .rules)) ?? ServerRules()
    }
}

public struct Share: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var serverId: String
    public var sharePath: String
    public var displayName: String
    public var behavior: MountBehavior
    public var readOnly: Bool
    public var usernameOverride: String?

    public init(id: String = "shr-\(UUID().uuidString.prefix(8).lowercased())", serverId: String,
                sharePath: String = "", displayName: String = "", behavior: MountBehavior = .auto,
                readOnly: Bool = false, usernameOverride: String? = nil) {
        self.id = id; self.serverId = serverId; self.sharePath = sharePath
        self.displayName = displayName; self.behavior = behavior; self.readOnly = readOnly
        self.usernameOverride = usernameOverride
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        serverId = try c.decode(String.self, forKey: .serverId)
        sharePath = try c.decode(String.self, forKey: .sharePath)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? sharePath
        behavior = (try? c.decodeIfPresent(MountBehavior.self, forKey: .behavior)) ?? .auto
        readOnly = (try? c.decodeIfPresent(Bool.self, forKey: .readOnly)) ?? false
        usernameOverride = try c.decodeIfPresent(String.self, forKey: .usernameOverride)
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var paused = false
    public var launchAtLogin = false
    public var pollIntervalSec = 30
    public var showInDock = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? false
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? false
        pollIntervalSec = max(10, (try? c.decodeIfPresent(Int.self, forKey: .pollIntervalSec)) ?? 30)
        showInDock = (try? c.decodeIfPresent(Bool.self, forKey: .showInDock)) ?? false
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var version = 1
    public var servers: [Server] = []
    public var shares: [Share] = []
    public var settings = AppSettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        servers = try c.decodeIfPresent([Server].self, forKey: .servers) ?? []
        shares = try c.decodeIfPresent([Share].self, forKey: .shares) ?? []
        settings = (try? c.decodeIfPresent(AppSettings.self, forKey: .settings)) ?? AppSettings()
    }
}

public enum LogLevel: String, Codable, Sendable { case info, warn, error }

public struct LogEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    /// Unix milliseconds (JS-compatible).
    public var ts: Double
    public var level: LogLevel
    public var message: String
    public var serverId: String?
    public var shareId: String?

    public init(level: LogLevel, message: String, serverId: String? = nil, shareId: String? = nil) {
        id = UUID().uuidString
        ts = Date().timeIntervalSince1970 * 1000
        self.level = level; self.message = message
        self.serverId = serverId; self.shareId = shareId
    }

    public var date: Date { Date(timeIntervalSince1970: ts / 1000) }
}

// MARK: - Runtime

public enum ServerStatus: Sendable {
    case unknown, unavailable, reachable, serviceAvailable, ruleBlocked, mounting, mounted, error

    public var label: String {
        switch self {
        case .unknown: "Unknown"
        case .unavailable: "Unavailable"
        case .reachable: "Reachable"
        case .serviceAvailable: "Service available"
        case .ruleBlocked: "Blocked by rule"
        case .mounting: "Mounting…"
        case .mounted: "Mounted"
        case .error: "Error"
        }
    }
}

public enum ShareStatus: Sendable {
    case notMounted, pending, mounted, manualOnly, blocked, failed

    public var label: String {
        switch self {
        case .notMounted: "Not mounted"
        case .pending: "Mounting…"
        case .mounted: "Mounted"
        case .manualOnly: "Manual only"
        case .blocked: "Blocked"
        case .failed: "Failed"
        }
    }
}

public enum RuleState: Sendable { case pass, fail, unknown, disabled }
public enum RuleKey: String, Sendable { case wifiSSID, vpnConnected, hostReachable, portOpen }

public struct RuleResult: Identifiable, Equatable, Sendable {
    public var key: RuleKey
    public var label: String
    public var state: RuleState
    public var detail: String?
    public var id: RuleKey { key }
}

public struct ShareRuntime: Equatable, Sendable {
    public var shareId: String
    public var status: ShareStatus
    public var mountPoint: String?
    public var reason: String?
    public var nextAttemptAt: Date?

    public init(shareId: String, status: ShareStatus, mountPoint: String? = nil,
                reason: String? = nil, nextAttemptAt: Date? = nil) {
        self.shareId = shareId; self.status = status; self.mountPoint = mountPoint
        self.reason = reason; self.nextAttemptAt = nextAttemptAt
    }
}

public struct ServerRuntime: Equatable, Sendable {
    public var serverId: String
    public var status: ServerStatus
    public var hostReachable: Bool
    public var portOpen: Bool
    public var latencyMs: Int?
    public var rules: [RuleResult]
    public var blockedReason: String?
    public var shares: [ShareRuntime]

    public init(serverId: String, status: ServerStatus, hostReachable: Bool, portOpen: Bool,
                latencyMs: Int? = nil, rules: [RuleResult] = [], blockedReason: String? = nil,
                shares: [ShareRuntime] = []) {
        self.serverId = serverId; self.status = status; self.hostReachable = hostReachable
        self.portOpen = portOpen; self.latencyMs = latencyMs; self.rules = rules
        self.blockedReason = blockedReason; self.shares = shares
    }
}

public enum OverallStatus: Sendable {
    case idle, allMounted, partial, paused, unavailable

    public var symbol: String {
        switch self {
        case .idle: "externaldrive"
        case .allMounted: "externaldrive.fill"
        case .partial: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .unavailable: "xmark.circle.fill"
        }
    }

    public var label: String {
        switch self {
        case .idle: "No shares mounted"
        case .allMounted: "All shares mounted"
        case .partial: "Needs attention"
        case .paused: "Automatic mounting paused"
        case .unavailable: "Servers unavailable"
        }
    }
}

public struct NetworkState: Equatable, Sendable {
    public var ssid: String?
    /// SSID could not be read (e.g. Location permission missing).
    public var ssidUnknown: Bool
    public var vpnConnected: Bool
    public init(ssid: String? = nil, ssidUnknown: Bool = true, vpnConnected: Bool = false) {
        self.ssid = ssid; self.ssidUnknown = ssidUnknown; self.vpnConnected = vpnConnected
    }
}

public struct ProbeResult: Equatable, Sendable {
    public var hostReachable: Bool
    public var portOpen: Bool
    public var latencyMs: Int?
    /// macOS blocked the probe: the app lacks Local Network permission.
    public var localNetworkDenied: Bool
    public init(hostReachable: Bool, portOpen: Bool, latencyMs: Int? = nil, localNetworkDenied: Bool = false) {
        self.hostReachable = hostReachable; self.portOpen = portOpen; self.latencyMs = latencyMs
        self.localNetworkDenied = localNetworkDenied
    }
}

public struct AppRuntime: Equatable, Sendable {
    public var overall: OverallStatus = .idle
    public var paused = false
    public var network = NetworkState()
    public var servers: [ServerRuntime] = []
    public init() {}
}
