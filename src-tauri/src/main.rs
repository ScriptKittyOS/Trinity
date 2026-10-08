// SPDX-FileCopyrightText: Sudo Apt Holdings LLC
// SPDX-License-Identifier: Apache-2.0
// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

// Slice 100: `trinity --keychain ...`, the shell binary as the BEAM's keychain helper.
mod keychain;

use tauri_plugin_autostart::{MacosLauncher, ManagerExt as AutostartExt};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
use tauri_plugin_opener::OpenerExt;
use tauri_plugin_shell::process::CommandEvent;
use tauri_plugin_shell::ShellExt;
use tauri::Manager;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem, Submenu};

use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

// Flipped to false when the app is quitting. The channel threads stop sending
// heartbeats once this is false, which lets the sidecar detect heartbeat loss
// and shut itself down gracefully: the only graceful path on Windows, where
// there is no SIGTERM to deliver.
static HEARTBEAT_ACTIVE: AtomicBool = AtomicBool::new(true);

// Outbound side of the sidecar channel: heartbeats, replies, and native
// events (menu/tray clicks) are queued here and written by the writer thread.
static CHANNEL_TX: Mutex<Option<mpsc::Sender<String>>> = Mutex::new(None);

// Handle to the tray icon created via the "set_tray" channel command.
// Kept so a later set_tray updates it in place.
static TRAY: Mutex<Option<tauri::tray::TrayIcon>> = Mutex::new(None);

// Slice 100. The token this launch hands the sidecar (TRINITY_SHELL_TOKEN) and
// presents in its hello on every connection, so Trinity.Desktop.Shell can tell
// this shell from any other local process that reaches the channel (finding
// F2: on Windows the channel is a loopback TCP port).
static TOKEN: OnceLock<String> = OnceLock::new();

// Slice 100. The port the sidecar serves on, for navigating the window to a
// page of the app (a notification's click, New session).
static PORT: OnceLock<u16> = OnceLock::new();

struct AppState {
    sidecar_child: Mutex<Option<SidecarProcess>>,
}

struct SidecarProcess {
    child: Option<tauri_plugin_shell::process::CommandChild>,
    pid: Option<u32>,
}

impl Drop for SidecarProcess {
    fn drop(&mut self) {
        if let Some(child) = self.child.take() {
            let _ = child.kill();
        }
    }
}

fn send_channel_message(message: String) {
    if let Ok(guard) = CHANNEL_TX.lock() {
        if let Some(tx) = guard.as_ref() {
            let _ = tx.send(message);
        }
    }
}

// Forwards a native event (menu click, tray click, errors) to the Elixir
// sidecar, where Trinity.Desktop.Shell receives it.
fn send_channel_event(name: &str, payload: serde_json::Value) {
    let message = serde_json::json!({"type": "event", "name": name, "payload": payload});
    send_channel_message(message.to_string());
}

fn kill_sidecar(app: &tauri::AppHandle) {
    // Stop heartbeating first: the sidecar's ShutdownManager sees the heartbeat
    // stop and begins its own graceful shutdown while we wait below.
    HEARTBEAT_ACTIVE.store(false, Ordering::Relaxed);

    if let Some(state) = app.try_state::<AppState>() {
        if let Ok(mut guard) = state.sidecar_child.lock() {
            if let Some(mut process) = guard.take() {
                // Try graceful shutdown first with SIGTERM
                if let Some(pid) = process.pid {
                    println!("Attempting graceful shutdown of sidecar (PID: {})...", pid);

                    #[cfg(unix)]
                    {
                        use std::process::Command;

                        // Slice 100, finding F1: in a packaged build the sidecar is the Burrito
                        // wrapper and the BEAM is its child, and the wrapper does not forward a
                        // signal to it (slice 001 measured the BEAM orphaned, still serving). The
                        // BEAM's own SIGTERM is OTP's graceful stop, which is what keeps a
                        // streaming turn as interrupted (AC7), so a `beam.smp` child of the
                        // sidecar is signalled by name. Only that name: in development the
                        // sidecar *is* the BEAM (a script that execs `mix phx.server`), and its
                        // children are the BEAM's own helpers (`erl_child_setup`), which must not
                        // be signalled; there the TERM below reaches the BEAM directly.
                        let _ = Command::new("pkill")
                            .args(["-TERM", "-x", "-P", &pid.to_string(), "beam.smp"])
                            .output();
                        let _ = Command::new("kill")
                            .args(["-TERM", &pid.to_string()])
                            .output();

                        // Wait up to 2 seconds for graceful shutdown
                        let timeout = Duration::from_millis(2000);
                        let start = std::time::Instant::now();

                        while start.elapsed() < timeout {
                            // Check if process is still running
                            let status = Command::new("kill")
                                .args(["-0", &pid.to_string()])
                                .output();

                            if let Ok(output) = status {
                                if !output.status.success() {
                                    println!("Sidecar shut down gracefully");
                                    return;
                                }
                            }

                            std::thread::sleep(Duration::from_millis(100));
                        }

                        println!("Graceful shutdown timeout, forcing kill...");
                    }

                    #[cfg(windows)]
                    {
                        // No SIGTERM on Windows. The heartbeat was stopped above,
                        // so the sidecar's ShutdownManager times out (1500ms by
                        // default) and exits gracefully on its own; give it time
                        // to do so before falling through to the hard kill.
                        std::thread::sleep(Duration::from_millis(2000));
                    }
                }

                // Fallback to SIGKILL if graceful shutdown didn't work
                if let Some(child) = process.child.take() {
                    println!("Sending SIGKILL to sidecar...");
                    let _ = child.kill();
                }
            }
        }
    }
}

// Slice 100: the one way Trinity quits from a menu, the tray or the Elixir side.
fn quit(app: &tauri::AppHandle) {
    kill_sidecar(app);
    std::thread::sleep(std::time::Duration::from_millis(500));
    std::process::exit(0);
}

fn main() {
    // Slice 100: the keychain helper mode returns before anything of the app exists, so it runs
    // without a window, a display, or the single-instance lock.
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--keychain") {
        std::process::exit(keychain::run(&args[2..]));
    }

    let _ = TOKEN.set(random_token());

    tauri::Builder::default()
        // Slice 100, AC8: a second launch exits and the first instance comes to the front. This
        // plugin must be registered first.
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            show_main(app, None);
        }))
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_log::Builder::new().build())
        .plugin(tauri_plugin_notification::init())
        // Slice 100, AC4: the global shortcut shows or hides the window. Which shortcut is set
        // from Elixir (`set_hotkey`), from the owner's Settings.
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _shortcut, event| {
                    if event.state == ShortcutState::Pressed {
                        toggle_main(app);
                    }
                })
                .build(),
        )
        // Slice 100: launch at login, switched from Settings (`set_autostart`).
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        // Slice 100: the folder dialog for the filesystem allowlist (`open_dialog`).
        .plugin(tauri_plugin_dialog::init())
        // Slice 100: Open data folder (`open_path`).
        .plugin(tauri_plugin_opener::init())
        .manage(AppState {
            sidecar_child: Mutex::new(None),
        })
        // Tauri v2 installs no default macOS menu, so Cmd+Q is unbound. A *custom*
        // Quit item (not the predefined one, which terminates natively and bypasses
        // on_menu_event) routes Cmd+Q through on_menu_event -> kill_sidecar so the
        // backend is stopped before exit. The Edit submenu keeps copy/paste working.
        .menu(|handle| {
            let quit = MenuItem::with_id(handle, "quit", "Quit Trinity", true, Some("CmdOrCtrl+Q"))?;
            let app_menu = Submenu::with_items(handle, "Trinity", true, &[&quit])?;
            let edit_menu = Submenu::with_items(
                handle,
                "Edit",
                true,
                &[
                    &PredefinedMenuItem::undo(handle, None)?,
                    &PredefinedMenuItem::redo(handle, None)?,
                    &PredefinedMenuItem::separator(handle)?,
                    &PredefinedMenuItem::cut(handle, None)?,
                    &PredefinedMenuItem::copy(handle, None)?,
                    &PredefinedMenuItem::paste(handle, None)?,
                    &PredefinedMenuItem::select_all(handle, None)?,
                ],
            )?;
            Menu::with_items(handle, &[&app_menu, &edit_menu])
        })
        .setup(|app| {
            let port = resolve_port();
            let _ = PORT.set(port);
            start_server(app.handle(), port);
            check_server_started(port);
            navigate_main_window(app.handle(), port, "/");
            start_channel(app.handle().clone());
            Ok(())
        })
        // Intercept menu events (especially CMD+Q on macOS)
        .on_menu_event(|app, event| {
            println!("Menu event received: {:?}", event.id());
            // On macOS, the default menu includes a "quit" item
            // Intercept it to perform graceful shutdown
            if event.id().as_ref() == "quit" {
                println!("Quit menu item clicked (CMD+Q), shutting down gracefully...");
                quit(app);
            }

            // Forward every other menu click to the Elixir sidecar so
            // server-side code can react.
            send_channel_event(
                "menu_click",
                serde_json::json!({"id": event.id().as_ref()}),
            );
        })
        .on_window_event(|window, event| match event {
            tauri::WindowEvent::CloseRequested { .. } => {
                // Kill the sidecar when the main window closes. Secondary
                // windows close without stopping the app.
                if window.label() == "main" {
                    kill_sidecar(&window.app_handle());
                }
            }
            // Slice 100, AC3: Trinity notifies only while the window is away (NOTES D4).
            tauri::WindowEvent::Focused(focused) if window.label() == "main" => {
                send_channel_event("window", serde_json::json!({"focused": focused}));
            }
            _ => {}
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app_handle, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                // Kill the sidecar when the app is exiting (fallback for non-menu exits)
                println!("ExitRequested event received, shutting down...");
                kill_sidecar(app_handle);
                api.prevent_exit(); // Prevent exit until we've cleaned up
                // Allow exit after cleanup
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_millis(500));
                    std::process::exit(0);
                });
            }
        });
}

// 32 random bytes, hex: the hello token (finding F2).
fn random_token() -> String {
    let mut buf = [0u8; 32];
    getrandom::fill(&mut buf).expect("the OS has no random source");
    buf.iter().map(|b| format!("{:02x}", b)).collect()
}

// Uses EX_TAURI_PORT when set (mix ex_tauri.dev pins it to the configured dev
// port); otherwise asks the OS for a free ephemeral port so installed apps
// never collide with other services. The sidecar receives the choice via the
// PORT env var and the window navigates to it once the server is up.
fn resolve_port() -> u16 {
    if let Ok(value) = std::env::var("EX_TAURI_PORT") {
        if let Ok(port) = value.parse::<u16>() {
            return port;
        }
    }

    std::net::TcpListener::bind(("127.0.0.1", 0))
        .and_then(|listener| listener.local_addr())
        .map(|addr| addr.port())
        .unwrap_or(4000)
}

// Phoenix releases sign session cookies with SECRET_KEY_BASE. Respect one if
// provided; otherwise generate a per-launch secret: sessions reset between
// launches, which is fine for a local desktop app.
fn secret_key_base() -> String {
    if let Ok(secret) = std::env::var("SECRET_KEY_BASE") {
        return secret;
    }

    let mut buf = [0u8; 48];
    getrandom::fill(&mut buf).expect("the OS has no random source");
    buf.iter().map(|b| format!("{:02x}", b)).collect()
}

fn start_server(app: &tauri::AppHandle, port: u16) {
    // PORT and SECRET_KEY_BASE are always injected: every server needs a port,
    // and SECRET_KEY_BASE is a random per-launch secret (inert if unused).
    // Slice 100 adds TRINITY_SHELL_TOKEN (the hello token; its presence is also
    // how the sidecar knows a shell launched it and selects Trinity.Desktop.Tauri)
    // and TRINITY_KEYCHAIN_HELPER (this binary's own path, for `--keychain`).
    let mut env: std::collections::HashMap<String, String> = std::collections::HashMap::from([
        ("PORT".to_string(), port.to_string()),
        ("SECRET_KEY_BASE".to_string(), secret_key_base()),
        ("PHX_SERVER".to_string(), "true".to_string()),
        ("PHX_HOST".to_string(), "127.0.0.1".to_string()),
        (
            "TRINITY_SHELL_TOKEN".to_string(),
            TOKEN.get().cloned().unwrap_or_default(),
        ),
    ]);

    if let Ok(exe) = std::env::current_exe() {
        env.insert(
            "TRINITY_KEYCHAIN_HELPER".to_string(),
            exe.to_string_lossy().into_owned(),
        );
    }

    // Slice 100: `--no-halt`. The packaged sidecar is the Burrito binary, which starts the release
    // through the Elixir CLI, and the CLI halts when it has nothing to run: without this the BEAM
    // booted, served, and exited about a second later with status 0, so the packaged app's window
    // pointed at a server that was gone (slice 001 recorded the flag as mandatory for the binary;
    // the shell never passed it, and the first run of the packaged shell found that). The
    // development sidecar is a script that ignores its arguments.
    let sidecar_command = app.shell().sidecar("desktop")
        .expect("failed to setup `desktop` sidecar")
        .args(["--no-halt"])
        .envs(env);

    let (mut rx, child) = sidecar_command
        .spawn()
        .expect("Failed to spawn desktop sidecar");

    // Get the PID for graceful shutdown
    let pid = child.pid();
    println!("Sidecar process started with PID: {}", pid);

    // Store the child process handle so we can kill it on exit
    if let Some(state) = app.try_state::<AppState>() {
        if let Ok(mut guard) = state.sidecar_child.lock() {
            *guard = Some(SidecarProcess {
                child: Some(child),
                pid: Some(pid),
            });
        }
    }

    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            if let CommandEvent::Stdout(line_bytes) = event {
                let line = String::from_utf8_lossy(&line_bytes);
                println!("{}", line);
            }
        }
    });
}

fn check_server_started(port: u16) {
    let sleep_interval = std::time::Duration::from_millis(200);
    let host = "127.0.0.1".to_string();
    let addr = format!("{}:{}", host, port);
    println!(
        "Waiting for your phoenix dev server to start on {}...",
        addr
    );
    loop {
        if std::net::TcpStream::connect(addr.clone()).is_ok() {
           break;
        }
        std::thread::sleep(sleep_interval);
    }
}

// Points the window at a page of the app on the port actually in use. When the
// OS assigned a free port (production), the compile-time URL in
// tauri.conf.json is wrong, and even in dev this reload recovers the webview if
// it raced the server boot. Only a path of this app is accepted (slice 100:
// a notification or the tray cannot send the window to another origin).
fn navigate_main_window(app: &tauri::AppHandle, port: u16, path: &str) {
    if !app_path(path) {
        return;
    }
    if let Some(window) = app.get_webview_window("main") {
        let url = format!("http://127.0.0.1:{}{}", port, path);
        if let Ok(url) = url.parse() {
            let _ = window.navigate(url);
        }
    }
}

fn app_path(path: &str) -> bool {
    path.starts_with('/')
        && !path.starts_with("//")
        && !path.contains('\\')
        && !path.contains('\n')
        && !path.contains('\r')
}

// Slice 100: show, unminimise and focus the main window, on a page of the app
// when a path is given (AC3's click, AC8's second launch, New session).
fn show_main(app: &tauri::AppHandle, path: Option<&str>) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
    if let (Some(path), Some(port)) = (path, PORT.get()) {
        navigate_main_window(app, *port, path);
    }
}

// Slice 100, AC4: the global shortcut's action. A visible window hides; a
// hidden or minimised one is shown and focused. On visibility alone, not on
// focus: without a window manager to hand focus to a window it has just
// mapped (the Xvfb evidence run), "visible and focused" read false after every
// show and the shortcut could never hide the window again (NOTES D9).
fn toggle_main(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let visible = window.is_visible().unwrap_or(false);
        let minimized = window.is_minimized().unwrap_or(false);
        if visible && !minimized {
            let _ = window.hide();
            send_channel_event("window", serde_json::json!({"focused": false}));
        } else {
            show_main(app, None);
        }
    }
}

// The sidecar channel carries heartbeats (liveness), commands from Elixir
// (Trinity.Desktop.Tauri), and native events back to Elixir: all as
// newline-delimited JSON over the ShutdownManager socket.
fn start_channel(app: tauri::AppHandle) {
    println!("Starting sidecar channel (heartbeat + desktop commands)...");

    std::thread::spawn(move || {
        let interval = Duration::from_millis(100);

        // Outer loop: (re)establish the connection. The sidecar's listener can
        // come up late (slow boot) or be recreated, so a dropped connection must
        // reconnect rather than end the heartbeat: otherwise the backend would
        // see the heartbeat stop and shut itself down. Everything exits once
        // HEARTBEAT_ACTIVE is cleared (the app is quitting): stopping the
        // heartbeat is what tells the sidecar to shut down gracefully.
        while HEARTBEAT_ACTIVE.load(Ordering::Relaxed) {
            let stream = match connect_channel() {
                Some(stream) => stream,
                None => return,
            };

            println!("Connected to sidecar channel");

            let (tx, rx) = mpsc::channel::<String>();
            if let Ok(mut guard) = CHANNEL_TX.lock() {
                *guard = Some(tx.clone());
            }

            // Slice 100, finding F2: the first thing on every connection is the
            // hello, so the sidecar believes this peer and no other.
            send_hello();

            // Ticker: queue a heartbeat line every 100ms.
            let ticker_tx = tx.clone();
            std::thread::spawn(move || {
                while HEARTBEAT_ACTIVE.load(Ordering::Relaxed) {
                    if ticker_tx
                        .send(String::from("{\"type\":\"heartbeat\"}"))
                        .is_err()
                    {
                        break;
                    }
                    std::thread::sleep(interval);
                }
            });

            // Reader: executes desktop commands sent by Elixir.
            if let Ok(read_stream) = stream.try_clone() {
                let reader_app = app.clone();
                std::thread::spawn(move || {
                    use std::io::{BufRead, BufReader};
                    let reader = BufReader::new(read_stream);
                    for line in reader.lines() {
                        match line {
                            Ok(line) => handle_channel_command(&reader_app, &line),
                            Err(_) => break,
                        }
                    }
                });
            }

            // Writer (this thread): drain the queue onto the socket. A failed
            // write means the connection dropped; clean up and reconnect.
            let mut stream = stream;
            for message in rx.iter() {
                if writeln!(stream, "{}", message).is_err() {
                    break;
                }
            }

            if let Ok(mut guard) = CHANNEL_TX.lock() {
                *guard = None;
            }

            if HEARTBEAT_ACTIVE.load(Ordering::Relaxed) {
                println!("Sidecar channel lost, reconnecting...");
            }
        }
    });
}

fn send_hello() {
    send_channel_event(
        "hello",
        serde_json::json!({"token": TOKEN.get().cloned().unwrap_or_default()}),
    );
}

#[cfg(unix)]
type ChannelStream = std::os::unix::net::UnixStream;
#[cfg(windows)]
type ChannelStream = std::net::TcpStream;

// Connects to the ShutdownManager's listener, retrying until the sidecar is
// up. Returns None only when the app is shutting down.
fn connect_channel() -> Option<ChannelStream> {
    #[cfg(unix)]
    {
        use std::os::unix::net::UnixStream;

        let socket_path = std::env::temp_dir().join("tauri_heartbeat_trinity.sock");

        loop {
            if !HEARTBEAT_ACTIVE.load(Ordering::Relaxed) {
                return None;
            }
            match UnixStream::connect(&socket_path) {
                Ok(stream) => return Some(stream),
                Err(_) => std::thread::sleep(Duration::from_millis(100)),
            }
        }
    }

    #[cfg(windows)]
    {
        use std::net::TcpStream;

        // The BEAM cannot listen on Unix domain sockets on Windows, so the
        // sidecar listens on 127.0.0.1 with an OS-assigned port and publishes
        // the port number in this discovery file (see ExTauri.ShutdownManager).
        // Re-read it on every reconnect: the port changes when the sidecar
        // restarts its listener.
        let port_file = std::env::temp_dir().join("tauri_heartbeat_trinity.port");

        loop {
            if !HEARTBEAT_ACTIVE.load(Ordering::Relaxed) {
                return None;
            }
            let port = std::fs::read_to_string(&port_file)
                .ok()
                .and_then(|contents| contents.trim().parse::<u16>().ok());
            match port.and_then(|p| TcpStream::connect(("127.0.0.1", p)).ok()) {
                Some(stream) => return Some(stream),
                None => std::thread::sleep(Duration::from_millis(100)),
            }
        }
    }
}

// Executes a desktop command sent by the Elixir sidecar (Trinity.Desktop.Tauri;
// slice 100 adds every command but notify and set_tray, and a click path to notify).
fn handle_channel_command(app: &tauri::AppHandle, line: &str) {
    let parsed: serde_json::Value = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(_) => return,
    };

    if parsed["type"] != "command" {
        return;
    }

    let name = parsed["name"].as_str().unwrap_or("").to_string();
    let payload = parsed["payload"].clone();

    match name.as_str() {
        "hello" => send_hello(),

        "notify" => notify(app, &payload),

        "set_tray" => {
            let app_handle = app.clone();
            let _ = app.run_on_main_thread(move || set_tray(&app_handle, payload));
        }

        "show_window" => {
            let app_handle = app.clone();
            let path = payload["path"].as_str().map(str::to_string);
            let _ = app.run_on_main_thread(move || show_main(&app_handle, path.as_deref()));
        }

        "open_path" => {
            if let Some(path) = payload["path"].as_str() {
                if let Err(error) = app.opener().open_path(path, None::<&str>) {
                    send_error(format!("Failed to open {}: {}", path, error));
                }
            }
        }

        "set_hotkey" => set_hotkey(app, payload["accelerator"].as_str()),

        "set_autostart" => {
            let manager = app.autolaunch();
            let result = if payload["enabled"].as_bool().unwrap_or(false) {
                manager.enable()
            } else {
                manager.disable()
            };
            if let Err(error) = result {
                send_error(format!("Failed to change launch at login: {}", error));
            }
        }

        "open_dialog" => open_dialog(app, &payload),

        "quit" => {
            let app_handle = app.clone();
            std::thread::spawn(move || quit(&app_handle));
        }

        other => send_error(format!("Unknown desktop command: {}", other)),
    }
}

fn send_error(message: String) {
    send_channel_event("error", serde_json::json!({"message": message}));
}

// Slice 100, AC3: an OS notification whose click shows the window on `path`.
// notify-rust reports the click (a freedesktop action on Linux, the
// notification centre's response on macOS, the toast's activation on Windows);
// the wait runs on its own thread, one per notification.
fn notify(app: &tauri::AppHandle, payload: &serde_json::Value) {
    let title = payload["title"].as_str().unwrap_or("Trinity").to_string();
    let body = payload["body"].as_str().unwrap_or("").to_string();
    let path = payload["path"].as_str().unwrap_or("/").to_string();
    let app_handle = app.clone();

    #[cfg(target_os = "macos")]
    {
        let _ = notify_rust::set_application(if tauri::is_dev() {
            "com.apple.Terminal"
        } else {
            app.config().identifier.as_str()
        });
    }

    std::thread::spawn(move || {
        let mut notification = notify_rust::Notification::new();
        notification
            .appname("Trinity")
            .summary(&title)
            .body(&body)
            .action("default", "Open");

        #[cfg(windows)]
        {
            // The toast's application identity only exists for an installed
            // app; a binary run from target/ keeps the default one, as
            // tauri-plugin-notification does.
            if let Ok(exe) = std::env::current_exe() {
                let dir = exe.parent().map(|d| d.display().to_string()).unwrap_or_default();
                if !(dir.ends_with("target\\debug") || dir.ends_with("target\\release")) {
                    notification.app_id(&app_handle.config().identifier);
                }
            }
        }

        match notification.show() {
            Ok(handle) => handle.wait_for_action(|action| {
                if action != "__closed" {
                    send_channel_event("notification_click", serde_json::json!({"path": path}));
                    let target = app_handle.clone();
                    let path = path.clone();
                    let _ = app_handle.run_on_main_thread(move || show_main(&target, Some(&path)));
                }
            }),
            Err(error) => send_error(format!("Failed to show a notification: {}", error)),
        }
    });
}

fn set_hotkey(app: &tauri::AppHandle, accelerator: Option<&str>) {
    let shortcuts = app.global_shortcut();
    let _ = shortcuts.unregister_all();

    if let Some(accelerator) = accelerator {
        if let Err(error) = shortcuts.register(accelerator) {
            send_error(format!("Failed to register the shortcut {}: {}", accelerator, error));
        }
    }
}

// Slice 100: the folder dialog. The answer goes back as a `dialog_result` event
// carrying the request's id; a cancelled dialog answers with no paths.
fn open_dialog(app: &tauri::AppHandle, payload: &serde_json::Value) {
    let id = payload["id"].as_str().unwrap_or("").to_string();
    let title = payload["title"].as_str().unwrap_or("").to_string();

    let mut builder = app.dialog().file();
    if !title.is_empty() {
        builder = builder.set_title(title);
    }

    builder.pick_folder(move |folder| {
        let paths: Vec<String> = folder
            .and_then(|path| path.into_path().ok())
            .map(|path| vec![path.to_string_lossy().into_owned()])
            .unwrap_or_default();

        send_channel_event("dialog_result", serde_json::json!({"id": id, "paths": paths}));
    });
}

// Builds (or updates) the system tray from an Elixir-provided spec:
// {"tooltip": "...", "items": [{"id": "...", "label": "...", "enabled": bool}, ...]}.
// Menu item clicks come back as "tray_menu_click" events on the channel.
fn set_tray(app: &tauri::AppHandle, payload: serde_json::Value) {
    use tauri::tray::TrayIconBuilder;

    let empty = Vec::new();
    let item_specs = payload["items"].as_array().unwrap_or(&empty);

    let mut items: Vec<MenuItem<tauri::Wry>> = Vec::new();
    for spec in item_specs {
        let id = spec["id"].as_str().unwrap_or("item");
        let label = spec["label"].as_str().unwrap_or(id);
        let enabled = spec["enabled"].as_bool().unwrap_or(true);
        if let Ok(item) = MenuItem::with_id(app, id, label, enabled, None::<&str>) {
            items.push(item);
        }
    }

    let item_refs: Vec<&dyn tauri::menu::IsMenuItem<tauri::Wry>> = items
        .iter()
        .map(|item| item as &dyn tauri::menu::IsMenuItem<tauri::Wry>)
        .collect();

    let menu = match Menu::with_items(app, &item_refs) {
        Ok(menu) => menu,
        Err(error) => {
            send_error(format!("Failed to build tray menu: {}", error));
            return;
        }
    };

    let tooltip = payload["tooltip"].as_str().map(str::to_string);

    // Slice 100: the tray changes with every approval and every turn, so an
    // existing icon is updated in place rather than dropped and rebuilt.
    if let Ok(guard) = TRAY.lock() {
        if let Some(tray) = guard.as_ref() {
            let _ = tray.set_menu(Some(menu));
            let _ = tray.set_tooltip(tooltip.as_deref());
            return;
        }
    }

    let mut builder = TrayIconBuilder::with_id("ex_tauri_tray")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|_app, event| {
            send_channel_event(
                "tray_menu_click",
                serde_json::json!({"id": event.id().as_ref()}),
            );
        });

    if let Some(tooltip) = tooltip.as_deref() {
        builder = builder.tooltip(tooltip);
    }

    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }

    match builder.build(app) {
        Ok(tray) => {
            if let Ok(mut guard) = TRAY.lock() {
                *guard = Some(tray);
            }
        }
        Err(error) => send_error(format!("Failed to build tray: {}", error)),
    }
}
