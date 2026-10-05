//! The server with real programs on real terminals, through the same
//! connections the app uses.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use super::*;
use crate::lock;

#[derive(Default)]
struct Recorder {
    output: Mutex<Vec<u8>>,
    replayed: Mutex<Option<usize>>,
    exit: Mutex<Option<Option<i32>>>,
}

impl Events for Recorder {
    fn output(&self, data: Vec<u8>) {
        lock(&self.output).extend(data);
    }
    fn replayed(&self) {
        *lock(&self.replayed) = Some(lock(&self.output).len());
    }
    fn exited(&self, code: Option<i32>) {
        *lock(&self.exit) = Some(code);
    }
}

impl Recorder {
    fn text(&self) -> String {
        String::from_utf8_lossy(&lock(&self.output)).into_owned()
    }
}

fn wait_for(seconds: u64, mut condition: impl FnMut() -> bool) -> bool {
    let end = Instant::now() + Duration::from_secs(seconds);
    while Instant::now() < end {
        if condition() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    condition()
}

/// A server of its own, in a short path: socket paths are limited to 104
/// bytes.
fn server() -> PathBuf {
    let dir = PathBuf::from(format!(
        "/tmp/agentz-test-{}",
        &uuid::Uuid::new_v4().to_string()[..8]
    ));
    daemon::run_on_thread(&dir).unwrap();
    dir
}

const SIZE: TermSize = TermSize {
    cols: 80,
    rows: 24,
    width_px: 800,
    height_px: 480,
};

fn spawn(script: &str) -> Spawn {
    Spawn {
        argv: vec!["/bin/sh".into(), "-c".into(), script.into()],
        env: vec!["PATH=/usr/bin:/bin".into(), "TERM=xterm-256color".into()],
        cwd: PathBuf::from("/tmp"),
        size: SIZE,
        meta: SessionMeta {
            agent: Agent::Claude,
            session_id: Some("abc".into()),
            title: "test".into(),
        },
    }
}

fn open(dir: &std::path::Path, request: Request) -> (Connection, Arc<Recorder>) {
    let events = Arc::new(Recorder::default());
    let conn = Connection::open(dir, None, &request, events.clone()).unwrap();
    (conn, events)
}

#[test]
fn attach_again_and_exit() {
    let dir = server();
    // A query in the output: an attaching app must not see it again.
    let (first, seen) = open(
        &dir,
        Request::Spawn(spawn(
            r#"printf 'hello\033[6n\n'; stty size; read x; echo "got $x"; exit 3"#,
        )),
    );
    let session = first.session();
    assert_eq!(session.meta.session_id.as_deref(), Some("abc"));
    assert!(session.started <= SystemTime::now());
    assert!(
        wait_for(5, || seen.text().contains("24 80")),
        "{:?}",
        seen.text()
    );
    assert!(
        seen.text().contains("hello\x1b[6n"),
        "live output keeps queries"
    );

    let listed = list(&dir).unwrap();
    assert_eq!(
        listed.iter().map(|s| &s.id).collect::<Vec<_>>(),
        vec![&session.id]
    );

    first.detach();
    assert!(wait_for(5, || lock(&seen.exit).is_some()));
    assert_eq!(list(&dir).unwrap().len(), 1, "the program keeps running");

    let (second, again) = open(
        &dir,
        Request::Attach {
            id: session.id.clone(),
            size: SIZE,
        },
    );
    assert!(wait_for(5, || lock(&again.replayed).is_some()));
    let replay = again.text();
    assert!(
        replay.contains("hello\r\n") && !replay.contains("\x1b[6n"),
        "{replay:?}"
    );

    second.write(b"abc\r");
    assert!(
        wait_for(5, || again.text().contains("got abc")),
        "{:?}",
        again.text()
    );
    assert!(wait_for(5, || *lock(&again.exit) == Some(Some(3))));
    assert!(wait_for(5, || list(&dir).unwrap().is_empty()));
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn attaching_makes_the_program_redraw() {
    let dir = server();
    let (first, started) = open(
        &dir,
        Request::Spawn(spawn(
            r#"trap 'stty size' WINCH; echo ready; while :; do sleep 0.05; done"#,
        )),
    );
    assert!(wait_for(5, || started.text().contains("ready")));
    let id = first.session().id;
    first.detach();
    // Same size: it changes for a moment, so the program redraws.
    let (second, seen) = open(
        &dir,
        Request::Attach {
            id: id.clone(),
            size: SIZE,
        },
    );
    assert!(
        wait_for(5, || seen.text().contains("23 80")
            && seen.text().contains("24 80")),
        "{:?}",
        seen.text()
    );
    second.detach();
    // Other pixels but the same cells: programs only notice cells.
    let pixels = TermSize {
        width_px: 999,
        ..SIZE
    };
    let (third, seen) = open(
        &dir,
        Request::Attach {
            id: id.clone(),
            size: pixels,
        },
    );
    assert!(
        wait_for(5, || seen.text().contains("23 80")
            && seen.text().contains("24 80")),
        "{:?}",
        seen.text()
    );
    third.detach();
    // Another size: it just takes it.
    let (fourth, seen) = open(
        &dir,
        Request::Attach {
            id,
            size: TermSize {
                cols: 100,
                rows: 30,
                ..SIZE
            },
        },
    );
    assert!(
        wait_for(5, || seen.text().contains("30 100")),
        "{:?}",
        seen.text()
    );
    fourth.resize(TermSize {
        cols: 90,
        rows: 20,
        ..SIZE
    });
    assert!(
        wait_for(5, || seen.text().contains("20 90")),
        "{:?}",
        seen.text()
    );
    fourth.kill();
    assert!(wait_for(5, || lock(&seen.exit).is_some_and(|code| code.is_some())));
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn kill_hangs_up_and_stop_all_ends_everything() {
    let dir = server();
    let (one, first) = open(&dir, Request::Spawn(spawn("sleep 30")));
    let (_two, second) = open(&dir, Request::Spawn(spawn("exec sleep 31")));
    one.kill();
    assert!(
        wait_for(5, || *lock(&first.exit) == Some(Some(128 + libc::SIGHUP))),
        "{:?}",
        lock(&first.exit)
    );
    let stopped = stop_all(&dir).unwrap();
    assert_eq!(stopped.len(), 1);
    assert!(wait_for(5, || lock(&second.exit).is_some()));
    assert!(wait_for(5, || list(&dir).unwrap().is_empty()));
    // Attaching to a program that ended fails.
    let events = Arc::new(Recorder::default());
    let err = Connection::open(
        &dir,
        None,
        &Request::Attach {
            id: stopped[0].id.clone(),
            size: SIZE,
        },
        events,
    );
    assert!(err.is_err());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn update_and_errors() {
    let dir = server();
    let (conn, _) = open(&dir, Request::Spawn(spawn("sleep 30")));
    let meta = SessionMeta {
        agent: Agent::Codex,
        session_id: Some("thread".into()),
        title: "t".into(),
    };
    conn.update(meta.clone());
    assert!(wait_for(5, || list(&dir).unwrap().first().map(|s| &s.meta)
        == Some(&meta)));
    conn.kill();
    let events = Arc::new(Recorder::default());
    let mut bad = spawn("");
    bad.argv = vec!["/nonexistent/program".into()];
    let (_, failed) = open(&dir, Request::Spawn(bad));
    assert!(
        wait_for(5, || *lock(&failed.exit) == Some(Some(127))),
        "{:?}",
        failed.text()
    );
    assert!(failed.text().contains("can't start the program"));
    // No server there.
    let none = PathBuf::from("/tmp/agentz-test-none");
    assert!(list(&none).unwrap().is_empty());
    assert!(Connection::open(&none, None, &Request::List, events).is_err());
    std::fs::remove_dir_all(dir).unwrap();
}

/// Starts the real `agent` in the server, lets go of it, attaches again
/// and checks that it draws its screen again. Answers the queries agents
/// wait for at start, as a terminal would. Run with `cargo test --
/// --ignored`; needs the agent installed. Sends no prompt.
fn real_agent_redraws_after_attach(agent: Agent, command: &str, banner: &str) {
    let dir = server();
    let mut env: Vec<String> = std::env::vars()
        .filter(|(k, _)| !k.starts_with("CLAUDE") && k != "TERM_PROGRAM")
        .map(|(k, v)| format!("{k}={v}"))
        .collect();
    env.extend([
        "TERM=xterm-256color".into(),
        "TERM_PROGRAM=ghostty".into(),
        "COLORTERM=truecolor".into(),
    ]);
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    let request = Request::Spawn(Spawn {
        argv: vec![
            "/bin/bash".into(),
            "--noprofile".into(),
            "--norc".into(),
            "-c".into(),
            format!("exec {command}"),
        ],
        env,
        cwd: repo,
        size: SIZE,
        meta: SessionMeta {
            agent,
            session_id: None,
            title: "test".into(),
        },
    });
    let answer = |conn: &Connection, seen: &Recorder, from: &mut usize| {
        let out = lock(&seen.output);
        let new = &out[(*from).min(out.len())..];
        let has = |q: &[u8]| new.windows(q.len()).any(|w| w == q);
        if has(b"\x1b[6n") {
            conn.write(b"\x1b[1;1R");
        }
        if has(b"\x1b[c") {
            conn.write(b"\x1b[?62;22c");
        }
        if has(b"\x1b]11;?") {
            conn.write(b"\x1b]11;rgb:0000/0000/0000\x1b\\");
        }
        if has(b"\x1b]10;?") {
            conn.write(b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\");
        }
        *from = out.len();
    };
    let (first, seen) = open(&dir, request);
    let mut from = 0;
    let started = wait_for(20, || {
        answer(&first, &seen, &mut from);
        seen.text().contains(banner)
    });
    assert!(started, "no banner: {:?}", seen.text());
    std::thread::sleep(Duration::from_millis(500));
    let id = first.session().id;
    first.detach();

    let (second, again) = open(&dir, Request::Attach { id, size: SIZE });
    assert!(wait_for(5, || lock(&again.replayed).is_some()));
    let replayed = lock(&again.replayed).unwrap();
    let replay = String::from_utf8_lossy(&lock(&again.output)[..replayed]).into_owned();
    assert!(
        replay.contains("\x1b[?1049h") && replay.contains(banner),
        "{:?}",
        &replay[..replay.len().min(300)]
    );
    assert!(
        !replay.contains("\x1b[c") && !replay.contains("\x1b[6n"),
        "no queries in the replay"
    );
    let mut from = replayed;
    let redrawn = wait_for(10, || {
        answer(&second, &again, &mut from);
        let live = String::from_utf8_lossy(&lock(&again.output)[replayed..]).into_owned();
        live.contains(banner)
    });
    assert!(redrawn, "no redraw after attaching");
    second.kill();
    assert!(wait_for(10, || lock(&again.exit).is_some()));
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
#[ignore = "needs claude"]
fn real_claude_redraws_after_attach() {
    real_agent_redraws_after_attach(Agent::Claude, "claude", "Claude Code");
}

#[test]
#[ignore = "needs codex"]
fn real_codex_redraws_after_attach() {
    real_agent_redraws_after_attach(Agent::Codex, "codex", "OpenAI Codex");
}
