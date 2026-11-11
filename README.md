# Mount Point (native)

Menu-bar app that keeps network shares mounted. Native Swift/SwiftUI, single 2.4 MB app, no third-party
packages: only macOS frameworks (NetFS, CoreWLAN, Network, Security, ServiceManagement).

```sh
./build-app.sh            # → build/Mount Point.app
./build-app.sh --install  # also copies it to /Applications
swift test                # rule + status logic tests (MountPointCore)
```

Requires macOS 15+ and Xcode (or the Command Line Tools with Swift 6) to build.

## Layout

| File | Responsibility |
| --- | --- |
| `Sources/MountPointCore/Model.swift` | Config schema, runtime types |
| `Sources/MountPointCore/Logic.swift` | Rule evaluation, status derivation, mount URL matching |
| `Sources/MountPoint/System.swift` | Storage, Keychain, network state, probes, NetFS mounting |
| `Sources/MountPoint/AppModel.swift` | Control loop, backoff, config changes, activity log |
| `Sources/MountPoint/App.swift` | Menu-bar extra |
| `Sources/MountPoint/SettingsView.swift` | Settings window |

## Behaviour

- Mounts via **NetFS**: SMB, AFP, NFS and WebDAV; read-only is honoured.
- Passwords live in the **Keychain** (service "Mount Point"); without one, macOS uses its saved credentials or asks.
- Data: `~/Library/Application Support/Mount Point/`.

## Permissions

- **Local Network** is required to probe servers. If it's denied, rules show
  "Blocked by macOS Local Network permission". Enable it in System Settings → Privacy & Security → Local Network.
- **Location** is requested only when a server uses the Wi-Fi rule (macOS hides the SSID otherwise).
- `build-app.sh` signs with an "Apple Development" certificate (free with any Apple ID in Xcode → Settings →
  Accounts; override with `SIGN_IDENTITY`). Its Team ID keeps permissions across rebuilds. Without one it signs
  ad-hoc, and macOS asks for Local Network again after every rebuild.

## Releases

Pushing a `v*` tag runs `.github/workflows/release.yml`, which tests, builds and attaches `MountPoint.dmg` to a
GitHub Release. That build is ad-hoc signed and not notarized: after dragging it to Applications, open it via System Settings →
Privacy & Security → "Open Anyway" (or `xattr -d com.apple.quarantine "Mount Point.app"`).
