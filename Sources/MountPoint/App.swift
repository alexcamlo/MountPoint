import AppKit
import MountPointCore
import SwiftUI

@main
struct MountPointApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.runtime.overall.symbol)
                .accessibilityLabel("Mount Point — \(model.runtime.overall.label)")
        }

        Window("Servers", id: "main") {
            SettingsView().environmentObject(model)
        }
        .defaultSize(width: 820, height: 560)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands { ServerCommands(model: model) }

        // App-level options only; opened by the standard Settings… (⌘,) item.
        Settings {
            GeneralSettings().environmentObject(model)
        }
    }
}

/// Menu-bar equivalents of the Servers window's toolbar items.
struct ServerCommands: Commands {
    let model: AppModel
    @FocusedValue(\.newServer) private var newServer
    @FocusedValue(\.editServer) private var editServer
    @FocusedValue(\.deleteServer) private var deleteServer

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Server…") { newServer?.wrappedValue = Server() }.keyboardShortcut("n").disabled(newServer == nil)
        }
        CommandMenu("Server") {
            Button("Refresh") { model.refresh() }.keyboardShortcut("r")
            Divider()
            Button("Edit Server…") { editServer?.wrappedValue = true }.keyboardShortcut("e").disabled(editServer == nil)
            Button("Delete Server…") { deleteServer?.wrappedValue = true }.keyboardShortcut(.delete).disabled(deleteServer == nil)
        }
    }
}

extension FocusedValues {
    @Entry var newServer: Binding<Server?>?
    @Entry var editServer: Binding<Bool>?
    @Entry var deleteServer: Binding<Bool>?
}

// A menu-bar-only app isn't active, so windows opened from the extra must activate it.
struct OpenMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Mount Point…") { openWindow(id: "main"); NSApp.activate() }.keyboardShortcut("o")
    }
}

struct OpenSettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button("Settings…") { openSettings(); NSApp.activate() }.keyboardShortcut(",")
    }
}

/// Menu-bar dropdown (port of tray-controller.ts).
struct MenuContent: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let rt = model.runtime
        Text(rt.overall.label)
        if let net = networkLine(rt.network) { Text(net) }
        Divider()

        if model.config.servers.isEmpty { Text("No servers configured") }
        ForEach(model.config.servers) { server in
            let sr = model.serverRuntime(server.id)
            // Status visible at a glance, without opening each submenu.
            Menu {
                Text("\(server.host) — \(sr?.status.label ?? "Unknown")")
                if let reason = sr?.blockedReason { Text(reason) }
                Divider()
                let shares = model.shares(of: server.id)
                if shares.isEmpty { Text("No shares") }
                ForEach(shares) { share in
                    let status = model.shareRuntime(share)?.status ?? .notMounted
                    Menu("\(share.displayName) — \(status.label)") {
                        Button("Mount") { model.manualMount(share) }
                            .disabled(status == .mounted || status == .pending)
                        Button("Unmount") { model.manualUnmount(share) }.disabled(status != .mounted)
                        Button("Reveal in Finder") { model.reveal(share) }.disabled(status != .mounted)
                    }
                }
            } label: {
                Label(server.name.isEmpty ? server.host : server.name, systemImage: serverStyle(sr?.status).symbol)
            }
        }

        Divider()
        Button(rt.paused ? "Resume Automatic Mounting" : "Pause Automatic Mounting") { model.togglePause() }
        Button("Refresh Now") { model.refresh() }.keyboardShortcut("r")
        Divider()
        OpenMainWindowButton()
        OpenSettingsButton()
        Button("Quit Mount Point") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func networkLine(_ n: NetworkState) -> String? {
        var parts: [String] = []
        if let ssid = n.ssid { parts.append("Wi-Fi: \(ssid)") } else if n.ssidUnknown { parts.append("Wi-Fi: unknown") }
        if n.vpnConnected { parts.append("VPN: on") }
        return parts.isEmpty ? nil : parts.joined(separator: "   •   ")
    }
}
