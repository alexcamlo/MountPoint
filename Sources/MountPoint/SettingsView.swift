import MountPointCore
import SwiftUI

private enum Page: Hashable, RawRepresentable {
    case server(String), activity

    // String form so the selection survives in @SceneStorage.
    init?(rawValue: String) {
        if rawValue == "activity" { self = .activity }
        else if rawValue.hasPrefix("server:") { self = .server(String(rawValue.dropFirst(7))) }
        else { return nil }
    }
    var rawValue: String {
        switch self {
        case .server(let id): "server:\(id)"
        case .activity: "activity"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @SceneStorage("page") private var page: Page?
    @State private var editingServer: Server?

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section("Servers") {
                    ForEach(model.config.servers) { server in
                        let status = model.serverRuntime(server.id)?.status
                        // Accent-coloured system glyph like every sidebar row; status trails, like Mail's badges.
                        Label {
                            HStack {
                                Text(server.name.isEmpty ? server.host : server.name)
                                Spacer()
                                StatusIcon(style: serverStyle(status))
                            }
                        } icon: {
                            Image(systemName: "server.rack")
                        }
                        .help(status?.label ?? "Checking…")
                        .accessibilityValue(status?.label ?? "Checking…")
                        .tag(Page.server(server.id))
                    }
                }
                Section {
                    Label("Activity", systemImage: "list.bullet.rectangle").tag(Page.activity)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .toolbar {
                Button { editingServer = Server() } label: { Label("Add Server", systemImage: "plus") }
            }
        } detail: {
            switch page {
            case .server(let id): if let server = model.server(id) { ServerDetail(server: server) } else { Welcome { editingServer = Server() } }
            case .activity: ActivityView()
            case nil: Welcome { editingServer = Server() }
            }
        }
        .sheet(item: $editingServer) { server in
            ServerForm(server: server) { saved in page = .server(saved.id) }
        }
        .focusedSceneValue(\.newServer, $editingServer)
        .onAppear(perform: ensureSelection)
        .onChange(of: model.config.servers.map(\.id)) { ensureSelection() }
    }

    /// Never show a blank detail when there's something to show: fall back to the first server.
    private func ensureSelection() {
        if case .server(let id) = page, model.server(id) == nil { page = nil }
        if page == nil, let first = model.config.servers.first { page = .server(first.id) }
    }
}

typealias StatusStyle = (symbol: String, color: Color)

/// Shape and colour both encode status, so it still reads without colour.
struct StatusIcon: View {
    var style: StatusStyle
    var body: some View {
        Image(systemName: style.symbol).foregroundStyle(style.color).imageScale(.small).accessibilityHidden(true)
    }
}

func serverStyle(_ s: ServerStatus?) -> StatusStyle {
    switch s {
    case .mounted: ("checkmark.circle.fill", .green)
    case .mounting: ("ellipsis.circle.fill", .orange)
    case .ruleBlocked: ("minus.circle.fill", .orange)
    case .reachable: ("exclamationmark.circle.fill", .orange)
    case .error, .unavailable: ("xmark.circle.fill", .red)
    case .serviceAvailable: ("circle.fill", .blue)
    case .unknown, nil: ("circle.dashed", .secondary)
    }
}

func shareStyle(_ s: ShareStatus?) -> StatusStyle {
    switch s {
    case .mounted: ("checkmark.circle.fill", .green)
    case .pending: ("ellipsis.circle.fill", .orange)
    case .blocked: ("minus.circle.fill", .orange)
    case .failed: ("xmark.circle.fill", .red)
    case .notMounted, .manualOnly, nil: ("circle", .secondary)
    }
}

/// Only reachable with no servers configured (otherwise the first server is selected).
private struct Welcome: View {
    let addServer: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("No Servers", systemImage: "externaldrive.connected.to.line.below")
        } description: {
            Text("Add a server and Mount Point will keep its shares mounted.")
        } actions: {
            Button("Add Server…", action: addServer)
        }
    }
}

// MARK: - Server detail

private struct ServerDetail: View {
    @EnvironmentObject private var model: AppModel
    let server: Server
    @State private var editing = false
    @State private var editingShare: Share?
    @State private var confirmDelete = false

    var body: some View {
        let sr = model.serverRuntime(server.id)
        Form {
            Section {
                LabeledContent("Address", value: "\(server.proto.rawValue)://\(server.host):\(server.port)")
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        StatusIcon(style: serverStyle(sr?.status))
                        Text(sr?.status.label ?? "Checking…")
                        if let ms = sr?.latencyMs { Text("\(ms) ms").foregroundStyle(.secondary) }
                    }
                }
                if let reason = sr?.blockedReason {
                    LabeledContent("Blocked", value: reason)
                }
            }

            Section("Auto-mount only when") {
                if let rules = sr?.rules {
                    ForEach(rules) { rule in
                        LabeledContent {
                            Text(rule.detail ?? (rule.state == .disabled ? "Off" : "")).foregroundStyle(.secondary)
                        } label: {
                            Label(rule.label, systemImage: ruleSymbol(rule.state)).foregroundStyle(ruleColor(rule.state))
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }

            Section {
                let shares = model.shares(of: server.id)
                if shares.isEmpty { Text("No shares yet").foregroundStyle(.secondary) }
                ForEach(shares) { share in ShareRow(share: share) { editingShare = share } }
            } header: {
                HStack {
                    Text("Shares")
                    Spacer()
                    Button("Add Share") { editingShare = Share(serverId: server.id) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(server.name.isEmpty ? server.host : server.name)
        .toolbar {
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            Button { editing = true } label: { Label("Edit Server", systemImage: "pencil") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Server", systemImage: "trash") }
        }
        .focusedSceneValue(\.editServer, $editing)
        .focusedSceneValue(\.deleteServer, $confirmDelete)
        .sheet(isPresented: $editing) { ServerForm(server: server) { _ in } }
        .sheet(item: $editingShare) { ShareForm(share: $0) }
        .confirmationDialog("Delete \(server.name) and its shares?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteServer(server.id) }
        }
    }

    private func ruleSymbol(_ s: RuleState) -> String {
        switch s {
        case .pass: "checkmark.circle.fill"
        case .fail: "xmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        case .disabled: "minus.circle"
        }
    }

    private func ruleColor(_ s: RuleState) -> Color {
        switch s {
        case .pass: .green
        case .fail: .red
        case .unknown: .orange
        case .disabled: .secondary
        }
    }
}

private struct ShareRow: View {
    @EnvironmentObject private var model: AppModel
    let share: Share
    let onEdit: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        let rt = model.shareRuntime(share)
        let status = rt?.status ?? .notMounted
        HStack {
            StatusIcon(style: shareStyle(status))
            VStack(alignment: .leading, spacing: 2) {
                Text(share.displayName)
                Text(rt?.mountPoint ?? rt?.reason ?? status.label)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status == .mounted {
                Button("Reveal") { model.reveal(share) }
                Button("Unmount") { model.manualUnmount(share) }
            } else if status == .pending {
                ProgressView().controlSize(.small).accessibilityLabel("Mounting \(share.displayName)")
            } else {
                Button("Mount") { model.manualMount(share) }
            }
            Menu {
                Button("Edit…", action: onEdit)
                Button("Delete", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("More actions for \(share.displayName)")
        }
        .confirmationDialog("Delete \(share.displayName)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteShare(share.id) }
        }
    }
}

// MARK: - Forms

private struct ServerForm: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var server: Server
    let onSave: (Server) -> Void
    @State private var password = ""
    @State private var removePassword = false
    @State private var ssids = ""
    @State private var test: String?
    @State private var testing = false

    init(server: Server, onSave: @escaping (Server) -> Void) {
        _server = State(initialValue: server)
        _ssids = State(initialValue: server.rules.wifiSSID.ssids.joined(separator: ", "))
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $server.name)
                TextField("Host", text: $server.host, prompt: Text("nas.local or 192.168.1.10"))
                Picker("Protocol", selection: $server.proto) {
                    ForEach(NetProtocol.allCases.filter { $0 != .ftp }, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .onChange(of: server.proto) { old, new in
                    if server.port == old.defaultPort { server.port = new.defaultPort }
                }
                TextField("Port", value: $server.port, format: .number.grouping(.never))
                if !(1...65535).contains(server.port) {
                    Text("Port must be between 1 and 65535").font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Test Connection") {
                        testing = true
                        Task {
                            let p = await probeServer(host: server.host, port: server.port)
                            test = p.portOpen ? "Port open\(p.latencyMs.map { " (\($0) ms)" } ?? "")"
                                : p.hostReachable ? "Host reachable, port closed" : "Server not reachable"
                            testing = false
                        }
                    }
                    .disabled(testing || server.host.trimmingCharacters(in: .whitespaces).isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    else if let test { Text(test).foregroundStyle(.secondary) }
                }
            }

            Section("Authentication") {
                Picker("Mode", selection: $server.authMode) {
                    Text("Keychain / ask").tag(AuthMode.native)
                    Text("Guest").tag(AuthMode.guest)
                }
                if server.authMode == .native {
                    TextField("Username", text: Binding(get: { server.username ?? "" }, set: { server.username = $0 }))
                    SecureField("Password", text: $password,
                                prompt: Text(server.hasStoredPassword == true ? "Saved — leave blank to keep" : "Optional"))
                    if server.hasStoredPassword == true { Toggle("Remove saved password", isOn: $removePassword) }
                }
            }

            Section("Auto-mount only when") {
                Toggle("Host responds", isOn: $server.rules.hostReachable.enabled)
                Toggle("Service port is open", isOn: $server.rules.portOpen.enabled)
                Toggle("VPN is connected", isOn: $server.rules.vpnConnected.enabled)
                Toggle("On Wi-Fi network", isOn: $server.rules.wifiSSID.enabled)
                if server.rules.wifiSSID.enabled {
                    TextField("Networks", text: $ssids, prompt: Text("HomeWiFi, HomeWiFi-5G"))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    server.rules.wifiSSID.ssids = ssids.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    model.saveServer(server, password: removePassword ? .clear : password.isEmpty ? .keep : .replace(password))
                    onSave(server)
                    dismiss()
                }
                .disabled(server.host.trimmingCharacters(in: .whitespaces).isEmpty || !(1...65535).contains(server.port))
            }
        }
    }
}

private struct ShareForm: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var share: Share

    var body: some View {
        Form {
            TextField("Share path", text: $share.sharePath, prompt: Text("media or home/docs"))
            TextField("Display name", text: $share.displayName, prompt: Text(share.sharePath))
            Picker("Mounting", selection: $share.behavior) {
                Text("Automatic").tag(MountBehavior.auto)
                Text("Manual only").tag(MountBehavior.manual)
            }
            Toggle("Read-only", isOn: $share.readOnly)
            TextField("Username override",
                      text: Binding(get: { share.usernameOverride ?? "" }, set: { share.usernameOverride = $0 }),
                      prompt: Text("Use server username"))
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { model.saveShare(share); dismiss() }
                    .disabled(share.sharePath.trimmingCharacters(in: CharacterSet(charactersIn: " /")).isEmpty)
            }
        }
    }
}

// MARK: - Activity & general settings

private struct ActivityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(model.logs.reversed()) { entry in
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: entry.level == .error ? "xmark.octagon.fill"
                      : entry.level == .warn ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(entry.level == .error ? .red : entry.level == .warn ? .orange : .secondary)
                    .accessibilityLabel(entry.level.rawValue)
                Text(entry.message).textSelection(.enabled)
                Spacer()
                Text(entry.date, format: .dateTime.day().month().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay { if model.logs.isEmpty { ContentUnavailableView("No activity yet", systemImage: "list.bullet") } }
        .navigationTitle("Activity")
        .toolbar { Button("Clear") { model.clearLogs() }.disabled(model.logs.isEmpty) }
    }
}

struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel

    private func binding<T>(_ key: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { model.config.settings[keyPath: key] },
                set: { v in model.updateSettings { $0[keyPath: key] = v } })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: binding(\.launchAtLogin))
                Toggle("Pause automatic mounting", isOn: binding(\.paused))
                Toggle("Show in Dock and ⌘-Tab", isOn: binding(\.showInDock))
                Stepper(value: binding(\.pollIntervalSec), in: 10...3600, step: 10) {
                    LabeledContent("Check every", value: "\(model.config.settings.pollIntervalSec) s")
                }
            }
            Section("Configuration") {
                LabeledContent("Export servers and shares") { Button("Export…") { model.exportConfig() } }
                LabeledContent("Import from file") { Button("Import…") { model.importConfig() } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
