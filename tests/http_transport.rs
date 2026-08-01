//! End-to-end tests for the streamable-HTTP transport.
//!
//! These spawn the *compiled* `mail-mcp` binary (`CARGO_BIN_EXE_mail-mcp`) with
//! `MAIL_MCP_TRANSPORT=http` and drive the real HTTP endpoint over raw TCP, so
//! they guard the transport wiring, protocol conformance, and the default-stdio
//! regression path that the in-crate unit tests (env parsing only) can't reach.
//!
//! Raw `std::net` is used deliberately: the streamable-HTTP `initialize`
//! response is an SSE stream the server holds open (keep-alive), so a naive
//! "read to end" would block — a per-read timeout lets us capture the emitted
//! events and move on without dechunking.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const INITIALIZE: &str = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"e2e","version":"1.0"}}}"#;

/// Kill-on-drop guard so a panicking test never leaks a server process.
struct ServerGuard(Child);
impl Drop for ServerGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// Reserve an ephemeral localhost port by binding `:0` and releasing it. A tiny
/// race exists between release and the child's re-bind, acceptable for tests.
fn reserve_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// Base command with dummy IMAP creds so `ServerConfig::load_from_env()`
/// succeeds. No IMAP connection is attempted until a tool is actually called,
/// so bogus creds are fine for exercising the transport/handshake.
fn base_command() -> Command {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_mail-mcp"));
    cmd.env("MAIL_IMAP_DEFAULT_HOST", "imap.example.com")
        .env("MAIL_IMAP_DEFAULT_USER", "user@example.com")
        .env("MAIL_IMAP_DEFAULT_PASS", "dummy")
        .env_remove("RUST_LOG");
    cmd
}

/// Spawn the server on the HTTP transport and block until it accepts a TCP
/// connection (the startup update-check adds up to ~2s before it binds).
fn spawn_http(path: &str) -> (String, ServerGuard) {
    let addr = format!("127.0.0.1:{}", reserve_port());
    let child = base_command()
        .env("MAIL_MCP_TRANSPORT", "http")
        .env("MAIL_MCP_HTTP_ADDR", &addr)
        .env("MAIL_MCP_HTTP_PATH", path)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn mail-mcp");
    let guard = ServerGuard(child);

    let deadline = Instant::now() + Duration::from_secs(20);
    while TcpStream::connect(&addr).is_err() {
        assert!(Instant::now() < deadline, "server never listened on {addr}");
        std::thread::sleep(Duration::from_millis(100));
    }
    (addr, guard)
}

/// Send one HTTP/1.1 request and read the response until the socket idles
/// (per-read timeout) or closes. Returns the raw response text. Good enough to
/// assert on the status line, headers, and JSON substrings without dechunking
/// or waiting for an SSE stream to end.
fn http_roundtrip(addr: &str, method: &str, path: &str, accept: &str, body: &str) -> String {
    let request = format!(
        "{method} {path} HTTP/1.1\r\n\
         Host: {addr}\r\n\
         Accept: {accept}\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {len}\r\n\
         Connection: close\r\n\
         \r\n\
         {body}",
        len = body.len(),
    );

    let mut stream = TcpStream::connect(addr).expect("connect");
    stream.write_all(request.as_bytes()).expect("write request");
    stream.flush().expect("flush");
    stream
        .set_read_timeout(Some(Duration::from_millis(500)))
        .unwrap();

    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break, // peer closed (error responses use Connection: close)
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            // read timed out: for the held-open SSE stream, once we've captured
            // the initial burst there's nothing more until the 15s keep-alive.
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                if !buf.is_empty() {
                    break;
                }
            }
            Err(e) => panic!("read error: {e}"),
        }
        assert!(Instant::now() < deadline, "response never arrived");
    }
    String::from_utf8_lossy(&buf).into_owned()
}

#[test]
fn http_initialize_handshake_returns_session_and_result() {
    let (addr, _guard) = spawn_http("/mcp");
    let resp = http_roundtrip(
        &addr,
        "POST",
        "/mcp",
        "application/json, text/event-stream",
        INITIALIZE,
    );

    assert!(
        resp.starts_with("HTTP/1.1 200"),
        "expected 200 status line, got:\n{resp}"
    );
    assert!(
        resp.to_ascii_lowercase().contains("mcp-session-id:"),
        "initialize must return a session id header:\n{resp}"
    );
    assert!(
        resp.contains(r#""jsonrpc":"2.0""#) && resp.contains(r#""result""#),
        "missing JSON-RPC result:\n{resp}"
    );
    assert!(
        resp.contains(r#""serverInfo""#) && resp.contains(r#""name":"mail-mcp""#),
        "initialize result must identify the server:\n{resp}"
    );
}

#[test]
fn http_respects_custom_mount_path() {
    let (addr, _guard) = spawn_http("/imap");
    // The configured path serves the endpoint...
    let ok = http_roundtrip(
        &addr,
        "POST",
        "/imap",
        "application/json, text/event-stream",
        INITIALIZE,
    );
    assert!(ok.starts_with("HTTP/1.1 200"), "custom path 200:\n{ok}");
    // ...and the default /mcp is now absent.
    let missing = http_roundtrip(
        &addr,
        "POST",
        "/mcp",
        "application/json, text/event-stream",
        INITIALIZE,
    );
    assert!(
        missing.starts_with("HTTP/1.1 404"),
        "non-mounted path should 404:\n{missing}"
    );
}

#[test]
fn http_unknown_path_returns_404() {
    let (addr, _guard) = spawn_http("/mcp");
    let resp = http_roundtrip(
        &addr,
        "POST",
        "/nope",
        "application/json, text/event-stream",
        "{}",
    );
    assert!(
        resp.starts_with("HTTP/1.1 404"),
        "unknown path should 404:\n{resp}"
    );
}

#[test]
fn http_post_without_event_stream_accept_is_rejected() {
    let (addr, _guard) = spawn_http("/mcp");
    // rmcp requires the POST Accept header to offer both application/json AND
    // text/event-stream; offering only json is a 406.
    let resp = http_roundtrip(&addr, "POST", "/mcp", "application/json", INITIALIZE);
    assert!(
        resp.starts_with("HTTP/1.1 406"),
        "missing event-stream Accept should be 406 Not Acceptable:\n{resp}"
    );
}

#[test]
fn http_unsupported_method_is_405() {
    let (addr, _guard) = spawn_http("/mcp");
    let resp = http_roundtrip(
        &addr,
        "PUT",
        "/mcp",
        "application/json, text/event-stream",
        "{}",
    );
    assert!(
        resp.starts_with("HTTP/1.1 405"),
        "PUT should be 405 Method Not Allowed:\n{resp}"
    );
}

#[test]
fn stdio_transport_still_serves_initialize() {
    // Regression guard: the default (no MAIL_MCP_TRANSPORT) path must keep
    // speaking newline-delimited JSON-RPC over stdio.
    let mut child = base_command()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn mail-mcp (stdio)");
    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let mut guard = ServerGuard(child);

    // Reader thread forwards each stdout line over a channel so the main thread
    // can wait with a timeout instead of blocking forever.
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    writeln!(stdin, "{INITIALIZE}").expect("write initialize");
    stdin.flush().expect("flush stdin");

    let deadline = Instant::now() + Duration::from_secs(20);
    let mut found = false;
    while Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(500)) {
            Ok(line) => {
                if line.contains(r#""result""#) && line.contains(r#""serverInfo""#) {
                    found = true;
                    break;
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    // Drop stdin (EOF) then let the guard reap the child.
    drop(stdin);
    let _ = &mut guard;
    assert!(found, "stdio transport did not return an initialize result");
}
