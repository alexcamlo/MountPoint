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

        Window("Mount Point", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .defaultSize(width: 820, height: 560)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appSettings) { OpenSettingsButton() }
        }
    }
}

struct OpenSettingsButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate()
        }
        .keyboardShortcut(",")
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
            Menu(server.name.isEmpty ? server.host : server.name) {
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
            }
        }

        Divider()
        Button(rt.paused ? "Resume Automatic Mounting" : "Pause Automatic Mounting") { model.togglePause() }
        Button("Refresh Now") { model.refresh() }.keyboardShortcut("r")
        Divider()
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
