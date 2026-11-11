import Foundation
import Synchronization

/// What the caller wants done with a server's saved password.
public enum PasswordIntent: Sendable, Equatable {
    case keep
    case replace(String)
    case clear
}

/// Where secrets live, keyed by server id.
public protocol SecretStore: Sendable {
    func set(_ secret: String, for serverId: String) throws
    func get(_ serverId: String) -> String?
    func delete(_ serverId: String)
}

public final class InMemorySecretStore: SecretStore {
    private let secrets: Mutex<[String: String]>
    private let failSets: Bool
    /// `failSets` makes every `set` throw, to exercise rollback.
    public init(_ initial: [String: String] = [:], failSets: Bool = false) {
        secrets = Mutex(initial); self.failSets = failSets
    }
    public func set(_ secret: String, for serverId: String) throws {
        if failSets { throw CocoaError(.fileWriteUnknown) }
        secrets.withLock { $0[serverId] = secret }
    }
    public func get(_ serverId: String) -> String? { secrets.withLock { $0[serverId] } }
    public func delete(_ serverId: String) { _ = secrets.withLock { $0.removeValue(forKey: serverId) } }
}

/// Sole owner of the invariant `server.hasStoredPassword == true` ⇔ the store holds a secret for `server.id`.
/// `commit` persists a config mutation and returns false if it could not be saved.
public struct ServerCredentials: Sendable {
    public typealias Commit = ((inout AppConfig) -> Void) -> Bool
    public let store: any SecretStore

    public init(store: any SecretStore) { self.store = store }

    /// Guest mode never keeps a password; an empty replacement means clear.
    public static func resolve(_ intent: PasswordIntent, for server: Server) -> PasswordIntent {
        if server.authMode == .guest { return server.hasStoredPassword == true ? .clear : .keep }
        if case .replace("") = intent { return .clear }
        return intent
    }

    /// Upserts `server`. Config is committed first so a failed save never orphans a secret;
    /// if the store then fails, the flag is rolled back and the error rethrown.
    public func save(_ server: Server, _ intent: PasswordIntent, commit: Commit) throws {
        var server = server
        let intent = Self.resolve(intent, for: server)
        switch intent {
        case .keep: break
        case .replace: server.hasStoredPassword = true
        case .clear: server.hasStoredPassword = false
        }
        guard commit({ cfg in
            if let i = cfg.servers.firstIndex(where: { $0.id == server.id }) { cfg.servers[i] = server }
            else { cfg.servers.append(server) }
        }) else { return }
        switch intent {
        case .keep: break
        case .clear: store.delete(server.id)
        case .replace(let password):
            do { try store.set(password, for: server.id) } catch {
                _ = commit { cfg in
                    if let i = cfg.servers.firstIndex(where: { $0.id == server.id }) { cfg.servers[i].hasStoredPassword = false }
                }
                throw error
            }
        }
    }

    /// Removes the server and its shares, then its secret.
    public func delete(_ serverId: String, commit: Commit) {
        guard commit({ cfg in
            cfg.servers.removeAll { $0.id == serverId }
            cfg.shares.removeAll { $0.serverId == serverId }
        }) else { return }
        store.delete(serverId)
    }

    /// Replaces the config with `imported` (flags cleared), then deletes the old servers' secrets.
    public func importConfig(_ imported: AppConfig, replacing current: AppConfig, commit: Commit) {
        guard commit({ cfg in
            cfg.servers = Self.scrubbed(imported).servers
            cfg.shares = imported.shares
            cfg.settings = imported.settings
        }) else { return }
        for s in current.servers { store.delete(s.id) }
    }

    /// Copy safe to write outside the app: secrets never leave the store, so no flag claims one.
    public static func scrubbed(_ config: AppConfig) -> AppConfig {
        var cfg = config
        for i in cfg.servers.indices { cfg.servers[i].hasStoredPassword = false }
        return cfg
    }

    /// Password to mount with, if one is saved.
    public func password(for server: Server) -> String? {
        server.hasStoredPassword == true ? store.get(server.id) : nil
    }
}
