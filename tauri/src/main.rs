// Valkka Desktop — Tauri v2 native shell
//
// Spawns the BEAM sidecar (Burrito binary), polls until healthy,
// opens the main window, and manages lifecycle (tray on close, graceful shutdown).

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::env;
use std::path::PathBuf;
use std::process::{Child, Command};
use std::sync::Mutex;
use std::time::Duration;

use tauri::Manager;

struct BeamProcess(Mutex<Option<Child>>);

fn sidecar_path() -> PathBuf {
    let exe_dir = env::current_exe()
        .expect("failed to get current exe path")
        .parent()
        .expect("exe has no parent")
        .to_path_buf();

    let bin_name = if cfg!(windows) { "valkka-beam.exe" } else { "valkka-beam" };

    // In dev, look next to the Tauri binary; in bundled app, look in binaries/
    let candidates = [
        exe_dir.join("binaries").join(bin_name),
        exe_dir.join(bin_name),
        exe_dir.join("../Resources/binaries").join(bin_name),
    ];

    for path in &candidates {
        if path.exists() {
            return path.clone();
        }
    }

    // Fallback: assume it's on PATH
    PathBuf::from(bin_name)
}

fn spawn_beam() -> Child {
    let path = sidecar_path();
    Command::new(path)
        .env("PHX_SERVER", "true")
        .env("VALKKA_TAURI", "1")
        .spawn()
        .expect("failed to start BEAM sidecar")
}

async fn wait_for_health(url: &str, timeout: Duration) -> bool {
    let start = std::time::Instant::now();
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(1))
        .build()
        .unwrap();

    while start.elapsed() < timeout {
        if let Ok(resp) = client.get(url).send().await {
            if resp.status().is_success() || resp.status().is_redirection() {
                return true;
            }
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    false
}

fn shutdown_beam(child: &mut Child) {
    // Try graceful shutdown first
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            libc::kill(child.id() as i32, libc::SIGTERM);
        }
    }

    // Wait up to 5 seconds for graceful exit
    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) => {
                if start.elapsed() > Duration::from_secs(5) {
                    let _ = child.kill();
                    return;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(_) => {
                let _ = child.kill();
                return;
            }
        }
    }
}

#[tokio::main]
async fn main() {
    let beam = spawn_beam();

    let healthy = wait_for_health("http://127.0.0.1:4420", Duration::from_secs(15)).await;
    if !healthy {
        eprintln!("valkka: BEAM sidecar failed to start within 15 seconds");
        std::process::exit(1);
    }

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(BeamProcess(Mutex::new(Some(beam))))
        .setup(|app| {
            let _window = tauri::WebviewWindowBuilder::new(
                app,
                "main",
                tauri::WebviewUrl::External("http://127.0.0.1:4420".parse().unwrap()),
            )
            .title("Valkka")
            .inner_size(1200.0, 800.0)
            .min_inner_size(900.0, 600.0)
            .build()?;

            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                // Hide to tray instead of quitting
                let _ = window.hide();
                api.prevent_close();
            }
        })
        .build(tauri::generate_context!())
        .expect("error building tauri app")
        .run(|app_handle, event| {
            if let tauri::RunEvent::ExitRequested { .. } = event {
                let state = app_handle.state::<BeamProcess>();
                if let Ok(mut guard) = state.0.lock() {
                    if let Some(ref mut child) = *guard {
                        shutdown_beam(child);
                    }
                }
            }
        });
}
