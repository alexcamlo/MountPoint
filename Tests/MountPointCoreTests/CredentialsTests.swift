import Foundation
import Testing
import MountPointCore

/// Config + store pair driven only through `ServerCredentials`.
private final class Harness {
    var config = AppConfig()
    var commitSucceeds = true
    let store: InMemorySecretStore
    let creds: ServerCredentials

    init(_ secrets: [String: String] = [:], failSets: Bool = false) {
        store = InMemorySecretStore(secrets, failSets: failSets)
        creds = ServerCredentials(store: store)
    }

    func commit(_ mutate: (inout AppConfig) -> Void) -> Bool {
        guard commitSucceeds else { return false }
        mutate(&config); return true
    }

    var flag: Bool? { config.servers.first { $0.id == "srv" }?.hasStoredPassword }
}

private func server(stored: Bool? = false, mode: AuthMode = .native) -> Server {
    Server(id: "srv", name: "NAS", host: "nas.local", authMode: mode, hasStoredPassword: stored)
}

@Test func replaceSetsFlagAndSecret() throws {
    let h = Harness()
    try h.creds.save(server(), .replace("pw")) { h.commit($0) }
    #expect(h.flag == true)
    #expect(h.store.get("srv") == "pw")
    #expect(h.creds.password(for: h.config.servers[0]) == "pw")
}

@Test func clearRemovesFlagAndSecret() throws {
    let h = Harness(["srv": "pw"])
    try h.creds.save(server(stored: true), .clear) { h.commit($0) }
    #expect(h.flag == false)
    #expect(h.store.get("srv") == nil)
}

@Test func keepLeavesBoth() throws {
    let h = Harness(["srv": "pw"])
    try h.creds.save(server(stored: true), .keep) { h.commit($0) }
    #expect(h.flag == true)
    #expect(h.store.get("srv") == "pw")
}

@Test func guestClearsSavedPassword() throws {
    let h = Harness(["srv": "pw"])
    try h.creds.save(server(stored: true, mode: .guest), .replace("ignored")) { h.commit($0) }
    #expect(h.flag == false)
    #expect(h.store.get("srv") == nil)
}

@Test func storeFailureRollsFlagBack() {
    let h = Harness(failSets: true)
    #expect(throws: (any Error).self) { try h.creds.save(server(), .replace("pw")) { h.commit($0) } }
    #expect(h.flag == false)
    #expect(h.store.get("srv") == nil)
}

@Test func failedCommitNeverWritesSecret() throws {
    let h = Harness()
    h.commitSucceeds = false
    try h.creds.save(server(), .replace("pw")) { h.commit($0) }
    #expect(h.store.get("srv") == nil)
}

@Test func exportScrubsFlags() {
    var cfg = AppConfig()
    cfg.servers = [server(stored: true)]
    #expect(ServerCredentials.scrubbed(cfg).servers[0].hasStoredPassword == false)
}

@Test func importScrubsFlagsAndDeletesOldSecrets() {
    let h = Harness(["old": "pw"])
    h.config.servers = [Server(id: "old", name: "Old", host: "old.local", hasStoredPassword: true)]
    var imported = AppConfig()
    imported.servers = [server(stored: true)]
    h.creds.importConfig(imported, replacing: h.config) { h.commit($0) }
    #expect(h.config.servers.map(\.id) == ["srv"])
    #expect(h.flag == false)
    #expect(h.store.get("old") == nil)
}

@Test func deleteRemovesSecret() throws {
    let h = Harness()
    try h.creds.save(server(), .replace("pw")) { h.commit($0) }
    h.creds.delete("srv") { h.commit($0) }
    #expect(h.config.servers.isEmpty)
    #expect(h.store.get("srv") == nil)
}
