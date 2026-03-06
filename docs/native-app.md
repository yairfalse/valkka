# Valkka: Native Desktop App Strategy

> Not a browser tab. A real app. On every platform.

---

## 1. The Problem

Phoenix LiveView in a browser works but feels wrong:
- No dock/taskbar icon
- No system tray
- No native keyboard shortcuts (Cmd+Q, etc.)
- Browser chrome wastes space
- Accidentally closing the tab kills the UI
- Doesn't feel like a "real" tool — feels like a web app

GitKraken is Electron (Chromium + Node). It's 600MB+ and sluggish. We need to beat that.

---

## 2. The Architecture: Tauri + Phoenix

**Tauri wraps the Phoenix LiveView app in a native window.**

```
┌─────────────────────────────────────────┐
│  Tauri Shell (native window per OS)     │
│  ┌───────────────────────────────────┐  │
│  │  System WebView                   │  │
│  │  ┌─────────────────────────────┐  │  │
│  │  │  Phoenix LiveView (UI)      │  │  │
│  │  │                             │  │  │
│  │  │  ← WebSocket →             │  │  │
│  │  │                             │  │  │
│  │  └─────────────────────────────┘  │  │
│  └───────────────────────────────────┘  │
│                                         │
│  System tray ✓                          │
│  Native menus ✓                         │
│  Keyboard shortcuts ✓                   │
│  Auto-update ✓                          │
│  File dialogs ✓                         │
└──────────────┬──────────────────────────┘
               │ localhost:4420
               │
┌──────────────▼──────────────────────────┐
│  Valkka Backend (BEAM process)           │
│                                         │
│  Phoenix Endpoint                       │
│  Repo Workers (GenServers)              │
│  AI StreamManager                       │
│  Rust NIFs (git2-rs)                    │
│  File Watchers                          │
└─────────────────────────────────────────┘
```

### Why Tauri, Not Electron

| | Electron | Tauri |
|---|---|---|
| Bundle size | ~150MB (ships Chromium) | ~5-10MB (uses system WebView) |
| RAM idle | 200-400MB | 30-50MB (WebView is shared) |
| Language | JavaScript/Node | Rust |
| WebView | Chromium (bundled) | WebKit (macOS), WebView2 (Windows), WebKitGTK (Linux) |
| Native feel | No | Yes — uses OS rendering |
| Auto-update | Electron-updater (heavy) | Built-in (tiny) |
| Security | Full Node.js access | Minimal permissions by default |

### Why Not Pure Native (SwiftUI/GTK/WinUI)

- Three completely different codebases
- Three different UI frameworks to learn
- Can't share UI code between platforms
- LiveView already works — we just need a native shell

### Why Not Neutralinojs / Wails / etc.

- Tauri is the most mature Rust-based option
- Best auto-update story
- Largest ecosystem and community
- We already have Rust in the stack (NIFs) — same toolchain

---

## 3. Per-Platform Details

### macOS

```
Valkka.app (bundle)
├── Contents/
│   ├── MacOS/
│   │   ├── valkka-tauri          # Tauri binary (native shell)
│   │   └── valkka-beam           # Bundled BEAM release (Burrito)
│   ├── Resources/
│   │   ├── AppIcon.icns
│   │   └── valkka_git.dylib      # Rust NIF
│   ├── Info.plist
│   └── Frameworks/              # (WebKit is system-provided)
```

**Native features:**
- `.app` bundle — drag to /Applications
- Dock icon with badge (unresolved conflicts count)
- System tray icon — quick status, always running
- Touch Bar support (commit, push, pull buttons)
- Homebrew cask install: `brew install --cask valkka`
- Native notifications (CI failed, PR merged)
- Spotlight integration — search repos by name
- Universal binary (Intel + Apple Silicon)

**WebView:** WKWebView (built into macOS, always up-to-date)

### Linux

```
valkka/
├── valkka                        # Tauri binary
├── valkka-beam                   # Bundled BEAM release
├── valkka_git.so                 # Rust NIF
├── valkka.desktop                # Desktop entry
└── icons/
    ├── 128x128.png
    ├── 256x256.png
    └── scalable.svg
```

**Distribution formats:**
- AppImage — single file, runs anywhere
- Flatpak — sandboxed, auto-update via Flathub
- `.deb` — Debian/Ubuntu
- `.rpm` — Fedora/RHEL
- AUR — Arch Linux

**Native features:**
- System tray (libappindicator)
- Desktop notifications (libnotify)
- File manager integration (open repo in Valkka)
- XDG compliance (config in `~/.config/valkka/`)

**WebView:** WebKitGTK (requires `webkit2gtk` package)

### Windows

```
Valkka/
├── Valkka.exe                    # Tauri binary
├── valkka-beam.exe               # Bundled BEAM release
├── valkka_git.dll                # Rust NIF
└── resources/
    └── icon.ico
```

**Distribution formats:**
- MSIX — Windows Store + auto-update
- `.msi` — traditional installer
- WinGet: `winget install valkka`
- Portable `.zip` — no install needed

**Native features:**
- System tray
- Windows notifications (toast)
- Jump list (recent repos)
- Dark/light mode follows system
- Start menu integration

**WebView:** WebView2 (Edge/Chromium-based, ships with Windows 11, auto-installed on 10)

---

## 4. Startup Flow

```
User clicks Valkka.app
  │
  ├── 1. Tauri shell starts (instant, ~5ms)
  │
  ├── 2. Tauri starts BEAM process in background
  │      valkka-beam starts Phoenix on localhost:4420
  │      (~1-2 seconds for BEAM boot)
  │
  ├── 3. Tauri shows splash/loading screen
  │      (native, not web — feels instant)
  │
  ├── 4. Tauri WebView connects to localhost:4420
  │      LiveView mounts, dashboard loads
  │
  └── 5. App is ready (~2 seconds total)
```

### Process Management

```rust
// Tauri side-car process management
// Tauri v2 has built-in sidecar support

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            // Start BEAM as a sidecar process
            let sidecar = app.shell()
                .sidecar("valkka-beam")
                .args(["start"])
                .spawn()
                .expect("Failed to start BEAM");

            // Wait for Phoenix to be ready
            wait_for_port(4420, Duration::from_secs(10));

            Ok(())
        })
        .on_window_event(|event| {
            // On close: minimize to tray instead of quitting
            if let tauri::WindowEvent::CloseRequested { api, .. } = event.event() {
                event.window().hide().unwrap();
                api.prevent_close();
            }
        })
        .system_tray(build_tray())
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
```

---

## 5. Native ↔ Web Bridge

Tauri provides a bridge between native APIs and the WebView.

### Tauri → LiveView (Native Events)

```rust
// Rust (Tauri side)
#[tauri::command]
fn open_repo_dialog(app: tauri::AppHandle) -> Option<String> {
    // Native folder picker — not a web file dialog
    tauri::api::dialog::blocking::FileDialogBuilder::new()
        .pick_folder()
        .map(|p| p.to_string_lossy().to_string())
}

#[tauri::command]
fn get_system_theme() -> String {
    // Returns "dark" or "light" based on OS setting
    if dark_light::detect() == dark_light::Mode::Dark {
        "dark".to_string()
    } else {
        "light".to_string()
    }
}
```

```javascript
// JS (LiveView hook)
const NativeBridge = {
    mounted() {
        // Listen for Tauri events
        window.__TAURI__.event.listen('repo-opened', (event) => {
            this.pushEvent("repo_opened", { path: event.payload });
        });
    },

    openRepoDialog() {
        window.__TAURI__.invoke('open_repo_dialog').then(path => {
            if (path) this.pushEvent("repo_opened", { path });
        });
    }
};
```

### LiveView → Tauri (Web to Native)

```javascript
// Request native notification
window.__TAURI__.notification.sendNotification({
    title: "CI Failed",
    body: "test_auth failed in false-protocol",
    icon: "ci-failed"
});

// Update dock badge (macOS)
window.__TAURI__.invoke('set_badge_count', { count: 3 });

// System tray update
window.__TAURI__.invoke('update_tray_status', {
    repos: [
        { name: "valkka", status: "clean" },
        { name: "false-protocol", status: "dirty" }
    ]
});
```

---

## 6. System Tray

Always-running background status.

```
┌──────────────────────────┐
│ Valkka                    │
├──────────────────────────┤
│ ● valkka        main  ✓  │
│ ● false-proto  feat  ✗  │
│ ● kerto        main  ✓  │
│ ○ sykli        main  ✓  │
├──────────────────────────┤
│ Open Dashboard           │
│ Quick Commit...          │
│ Run CI                   │
├──────────────────────────┤
│ Preferences              │
│ Quit Valkka               │
└──────────────────────────┘

● = has changes    ○ = clean
✓ = CI passing     ✗ = CI failing
```

---

## 7. Keyboard Shortcuts

Native shortcuts that work across all platforms.

| Action | macOS | Linux/Windows |
|---|---|---|
| Open Valkka | Cmd+Shift+K | Ctrl+Shift+K |
| Quick commit | Cmd+Enter | Ctrl+Enter |
| Show graph | Cmd+G | Ctrl+G |
| Switch repo | Cmd+1-9 | Ctrl+1-9 |
| Search | Cmd+K | Ctrl+K |
| Push | Cmd+Shift+P | Ctrl+Shift+P |
| Pull | Cmd+Shift+L | Ctrl+Shift+L |
| New branch | Cmd+B | Ctrl+B |
| Toggle chat | Cmd+/ | Ctrl+/ |
| Preferences | Cmd+, | Ctrl+, |

### Global Hotkey

Register a system-wide hotkey to summon Valkka from anywhere:

```rust
// Tauri global shortcut
app.global_shortcut_manager()
    .register("CmdOrCtrl+Shift+K", move || {
        // Show/focus the Valkka window
        window.show().unwrap();
        window.set_focus().unwrap();
    });
```

---

## 8. Auto-Update

Tauri has built-in auto-update support.

```rust
// tauri.conf.json
{
    "tauri": {
        "updater": {
            "active": true,
            "dialog": true,
            "endpoints": ["https://releases.valkka.dev/{{target}}/{{current_version}}"],
            "pubkey": "..."
        }
    }
}
```

Update flow:
1. On launch, check for updates (background)
2. If update available, show non-intrusive notification
3. User clicks "Update" → download + replace binary
4. Restart Valkka (< 3 seconds)

BEAM release is bundled inside the Tauri app — both update together.

---

## 9. Bundling Strategy

### The Bundle

```
Valkka app bundle (~30-50MB total)
├── Tauri shell binary        ~5MB
├── BEAM release (Burrito)    ~15-25MB
│   ├── ERTS (Erlang runtime)
│   ├── Elixir stdlib
│   ├── Phoenix + LiveView
│   └── Application code
├── Rust NIF (.dylib/.so/.dll) ~3-5MB
│   ├── git2 (libgit2)
│   ├── tree-sitter + grammars
│   └── graph layout
├── Web assets (JS/CSS)        ~1-2MB
└── Icons + resources          ~1MB
```

**Compare to GitKraken: ~150MB+ (Chromium alone is 100MB)**

### Build Pipeline

```bash
# Build everything
mix deps.get
mix compile              # Compiles Elixir + Rust NIFs
mix assets.deploy        # Bundles JS/CSS
mix release              # Creates BEAM release

# Bundle with Burrito (cross-platform BEAM)
mix burrito.wrap

# Build Tauri shell
cd tauri/
cargo tauri build        # Produces platform-specific installer

# Result:
# macOS: Valkka.app (DMG)
# Linux: valkka.AppImage
# Windows: Valkka_setup.exe (MSIX)
```

### CI Build Matrix (Sykli)

```go
s := sykli.New()

// Build per platform
for _, platform := range []string{"macos-arm64", "macos-x64", "linux-x64", "windows-x64"} {
    s.Task("build-" + platform).
        Run("cargo tauri build --target " + target(platform)).
        After("test").
        Inputs("src/**", "tauri/**", "lib/**", "native/**")
}

s.Task("release").
    Run("./scripts/upload-releases.sh").
    After("build-macos-arm64", "build-macos-x64", "build-linux-x64", "build-windows-x64")

s.Emit()
```

---

## 10. Project Structure Addition

```
valkka/
├── lib/                         # Elixir app (existing)
├── native/valkka_git/            # Rust NIFs (existing)
├── assets/                      # Web assets (existing)
│
├── tauri/                       # NEW: Tauri shell
│   ├── Cargo.toml
│   ├── tauri.conf.json          # Tauri config
│   ├── build.rs
│   ├── src/
│   │   ├── main.rs              # Tauri entry point
│   │   ├── sidecar.rs           # BEAM process management
│   │   ├── tray.rs              # System tray
│   │   ├── shortcuts.rs         # Global keyboard shortcuts
│   │   ├── commands.rs          # Native commands (file dialog, etc.)
│   │   └── updater.rs           # Auto-update config
│   └── icons/
│       ├── icon.icns            # macOS
│       ├── icon.ico             # Windows
│       └── icon.png             # Linux
│
├── scripts/
│   ├── build-all.sh             # Cross-platform build
│   ├── bundle-beam.sh           # Burrito bundling
│   └── upload-releases.sh       # Release uploads
│
└── docs/
    └── native-app.md            # This file
```

---

## 11. Development Workflow

### Dev Mode (No Tauri)

During development, you don't need Tauri. Just run Phoenix:

```bash
mix phx.server
# Open http://localhost:4420 in browser
```

LiveView hot-reloads. Fast iteration. No rebuild needed.

### Dev Mode (With Tauri)

When working on native features:

```bash
cargo tauri dev
# Starts Phoenix + Tauri window together
# Hot-reloads both web and native code
```

### Production Build

```bash
cargo tauri build
# Produces distributable for current platform
```

---

## 12. Memory Budget

| Component | Target RAM |
|---|---|
| Tauri shell | ~10MB |
| System WebView | ~30-50MB (shared with OS) |
| BEAM VM | ~40-60MB |
| Rust NIFs (5 repos) | ~20-30MB |
| **Total** | **~100-150MB** |

**GitKraken comparison: 600MB - 1.2GB**

We're using 5-10x less memory. That's the headline.

---

## 13. What This Gives Us

| Feature | Browser-only | Tauri + Browser |
|---|---|---|
| Dock/taskbar icon | No | Yes |
| System tray | No | Yes |
| Global hotkey | No | Yes |
| Native notifications | No | Yes |
| Native file dialogs | No | Yes |
| Auto-update | No | Yes |
| Runs without browser | No | Yes |
| Minimize to tray | No | Yes |
| OS dark mode sync | No | Yes |
| Keyboard shortcuts | Web-only | System-wide |
| Bundle size | N/A (needs browser) | ~30-50MB |
| Feels like a real app | No | **Yes** |
