//! Tests against the real `claude` and `codex` CLIs. They catch updates that
//! break what agentz relies on: CLI flags, transcript files and their format,
//! `~/.claude/sessions/<pid>.json`, and Codex keeping its rollout file open.
//!
//! They start the agents in a PTY just like agentz does, type a prompt, and
//! check what shows up on disk. Each prompt is sent to the model, so they are
//! ignored by default. Run them with `make integration`.
//!
//! Each test works in its own fixed folder under the temp dir, so the agents'
//! "trust this folder?" answer is stored once and not for every run. The
//! transcripts the tests create are deleted at the start and end of each test.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime};

use crossterm::event::{KeyCode, KeyEvent};

use crate::app::build_command;
use crate::procs::agents_in_shells;
use crate::sessions::{Agent, Scanner, Session, claude_dir, codex_home, first_prompt};
use crate::term::Term;

const TIMEOUT: Duration = Duration::from_secs(90);
const POLL: Duration = Duration::from_millis(300);
const PROMPT: &str = "agentz compat test, reply with just OK";
const PROMPT_2: &str = "agentz compat test again, reply with just OK";
const RENAMED: &str = "agentz compat renamed";

#[test]
#[ignore = "runs the real claude CLI and calls the model"]
fn claude_new_session_and_resume() {
    let dir = TestDir::new("claude-new");
    let id = uuid::Uuid::new_v4().to_string();

    // New session, started the way agentz does it.
    let mut pty = Pty::start(Agent::Claude, &["--session-id", &id], &dir.path);
    pty.wait_ready();
    pty.submit(PROMPT);
    let s = pty.wait_for("the new session in the session list", || {
        dir.sessions().into_iter().find(|s| s.id == id)
    });
    assert_eq!(s.agent, Agent::Claude);
    // Claude soon adds a generated title, which wins over the first prompt.
    assert_first_prompt(Agent::Claude, &id);
    drop(pty);

    // Resuming must continue the same transcript, not fork a new session.
    let mut pty = Pty::start(Agent::Claude, &["--resume", &id], &dir.path);
    pty.wait_ready();
    pty.submit(PROMPT_2);
    pty.wait_for("the second prompt in the resumed transcript", || {
        transcript_contains(Agent::Claude, &id, PROMPT_2).then_some(())
    });
    assert_eq!(ids(&dir.sessions()), [id.as_str()]);

    // A `/rename` name is the title.
    pty.wait_ready();
    pty.submit(&format!("/rename {RENAMED}"));
    pty.wait_for("the new name as the title", || {
        dir.sessions()
            .into_iter()
            .find(|s| s.id == id && s.title == RENAMED)
    });
}

#[test]
#[ignore = "runs the real claude CLI and calls the model"]
fn claude_started_in_shell_is_linked() {
    let dir = TestDir::new("claude-shell");
    let mut shell = Pty::start(Agent::Shell, &[], &dir.path);
    shell.wait_ready();
    shell.submit("claude");

    // Found through `~/.claude/sessions/<pid>.json`.
    let pid = shell.term.pid.expect("shell pid");
    let id = shell.wait_for("claude to be linked to the shell", || {
        agents_in_shells(&[pid])
            .into_iter()
            .find(|(_, key)| key.0 == Agent::Claude)
            .map(|(_, key)| key.1)
    });

    // The linked id must be the id of the transcript that shows up.
    shell.wait_ready();
    shell.submit(PROMPT);
    shell.wait_for("the linked session in the session list", || {
        dir.sessions().into_iter().find(|s| s.id == id)
    });
}

#[test]
#[ignore = "runs the real codex CLI and calls the model"]
fn codex_new_session_and_resume() {
    let dir = TestDir::new("codex-new");

    // New session. Codex picks the id, so agentz finds the session by folder
    // and start time once the transcript exists.
    let started = SystemTime::now() - Duration::from_secs(5);
    let mut pty = Pty::start(Agent::Codex, &[], &dir.path);
    pty.wait_ready();
    pty.submit(PROMPT);
    let s = pty.wait_for("the new session in the session list", || {
        dir.sessions()
            .into_iter()
            .find(|s| s.agent == Agent::Codex && s.created >= started)
    });
    assert_first_prompt(Agent::Codex, &s.id);
    drop(pty);

    // Resuming must continue the same transcript, not fork a new session.
    let mut pty = Pty::start(Agent::Codex, &["resume", &s.id], &dir.path);
    pty.wait_ready();
    pty.submit(PROMPT_2);
    pty.wait_for("the second prompt in the resumed transcript", || {
        transcript_contains(Agent::Codex, &s.id, PROMPT_2).then_some(())
    });
    assert_eq!(ids(&dir.sessions()), [s.id.as_str()]);
}

#[test]
#[ignore = "runs the real codex CLI and calls the model"]
fn codex_started_in_shell_is_linked() {
    let dir = TestDir::new("codex-shell");
    let mut shell = Pty::start(Agent::Shell, &[], &dir.path);
    shell.wait_ready();
    shell.submit("codex");
    shell.wait_ready();
    // Codex creates its transcript on the first message.
    shell.submit(PROMPT);

    // Found through the rollout file Codex keeps open.
    let pid = shell.term.pid.expect("shell pid");
    let id = shell.wait_for("codex to be linked to the shell", || {
        agents_in_shells(&[pid])
            .into_iter()
            .find(|(_, key)| key.0 == Agent::Codex)
            .map(|(_, key)| key.1)
    });
    shell.wait_for("the linked session in the session list", || {
        dir.sessions().into_iter().find(|s| s.id == id)
    });
    assert_first_prompt(Agent::Codex, &id);
}

/// An agent or shell in a PTY, started with agentz's own command builder.
struct Pty {
    term: Term,
    trust_answered_at: Option<Instant>,
}

impl Pty {
    fn start(agent: Agent, args: &[&str], cwd: &Path) -> Self {
        let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        let cmd = build_command(agent, &args, cwd);
        // Nobody listens to the events; the tests poll instead.
        let (tx, _) = mpsc::channel();
        let term = Term::spawn(0, cmd, 40, 120, tx, Arc::new(AtomicBool::new(false)))
            .unwrap_or_else(|e| panic!("could not start {}: {e:#}", agent.name()));
        Pty {
            term,
            trust_answered_at: None,
        }
    }

    /// Answers "yes" to the "do you trust this folder?" question: moves the
    /// selection to the option starting with "Yes" and presses Enter. The
    /// agents ask once per folder.
    fn answer_trust(&mut self) {
        if self
            .trust_answered_at
            .is_some_and(|t| t.elapsed() < Duration::from_secs(2))
        {
            return;
        }
        if !is_trust_question(&self.term.screen_text()) {
            return;
        }
        // Let the dialog finish drawing.
        std::thread::sleep(Duration::from_millis(500));
        let screen = self.term.screen_text();
        let lines: Vec<&str> = screen.lines().collect();
        let option = |l: &str| {
            l.trim_start_matches(|c: char| {
                c.is_whitespace() || c.is_ascii_digit() || matches!(c, '❯' | '›' | '>' | '.')
            })
            .to_lowercase()
        };
        let selected = lines
            .iter()
            .position(|l| l.trim_start().starts_with(['❯', '›', '>']));
        let yes = lines.iter().position(|l| option(l).starts_with("yes"));
        if let (Some(selected), Some(yes)) = (selected, yes) {
            let key = if yes > selected {
                KeyCode::Down
            } else {
                KeyCode::Up
            };
            for _ in 0..yes.abs_diff(selected) {
                self.term.send_key(KeyEvent::from(key));
                std::thread::sleep(Duration::from_millis(100));
            }
        }
        self.term.send_key(KeyEvent::from(KeyCode::Enter));
        self.trust_answered_at = Some(Instant::now());
        std::thread::sleep(Duration::from_secs(1));
    }

    /// Waits until the program has drawn something and gone quiet. Gives up
    /// quietly after a while, since some programs keep animating.
    fn wait_ready(&mut self) {
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(30) {
            self.answer_trust();
            if !self.term.is_busy() && !self.term.screen_text().trim().is_empty() {
                return;
            }
            std::thread::sleep(POLL);
        }
    }

    /// Types a line and presses Enter. The pause keeps the Enter from being
    /// read as part of a paste.
    fn submit(&mut self, text: &str) {
        self.term.write(text.as_bytes());
        std::thread::sleep(Duration::from_millis(500));
        self.term.write(b"\r");
    }

    /// Polls `f` until it returns something. On timeout, fails and shows the
    /// screen, which usually tells what changed.
    fn wait_for<T>(&mut self, what: &str, mut f: impl FnMut() -> Option<T>) -> T {
        let start = Instant::now();
        loop {
            self.answer_trust();
            if let Some(v) = f() {
                return v;
            }
            if start.elapsed() > TIMEOUT {
                panic!(
                    "timed out waiting for {what}\n--- screen ---\n{}",
                    self.term.screen_text()
                );
            }
            std::thread::sleep(POLL);
        }
    }
}

/// A fixed working folder for one test. Removes the sessions made in it
/// before and after the test.
struct TestDir {
    path: PathBuf,
}

impl TestDir {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join("agentz-compat").join(name);
        fs::create_dir_all(&path).unwrap();
        // The agents record the real path (e.g. /private/var on macOS).
        let dir = TestDir {
            path: path.canonicalize().unwrap(),
        };
        dir.remove_sessions();
        dir
    }

    /// Sessions agentz lists for this folder.
    fn sessions(&self) -> Vec<Session> {
        let mut out = Scanner::default().scan();
        out.retain(|s| s.cwd == self.path);
        out
    }

    fn remove_sessions(&self) {
        for s in self.sessions() {
            if let Some(file) = transcript(s.agent, &s.id) {
                let _ = fs::remove_file(&file);
                // Claude keeps tool output next to the transcript.
                let _ = fs::remove_dir_all(file.with_extension(""));
                if s.agent == Agent::Claude
                    && let Some(parent) = file.parent()
                {
                    // Only succeeds once the folders are empty.
                    let _ = fs::remove_dir(parent.join("memory"));
                    let _ = fs::remove_dir(parent);
                }
            }
        }
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        self.remove_sessions();
    }
}

fn is_trust_question(screen: &str) -> bool {
    let screen = screen.to_lowercase();
    screen.contains("trust")
        && ["folder", "directory", "project"]
            .iter()
            .any(|w| screen.contains(w))
}

fn ids(sessions: &[Session]) -> Vec<String> {
    sessions.iter().map(|s| s.id.clone()).collect()
}

fn assert_first_prompt(agent: Agent, id: &str) {
    let file = transcript(agent, id).expect("transcript file");
    assert_eq!(first_prompt(&file, agent).as_deref(), Some(PROMPT));
}

fn transcript_contains(agent: Agent, id: &str, text: &str) -> bool {
    transcript(agent, id)
        .and_then(|p| fs::read_to_string(p).ok())
        .is_some_and(|t| t.contains(text))
}

/// The transcript file of a session.
fn transcript(agent: Agent, id: &str) -> Option<PathBuf> {
    match agent {
        Agent::Claude => fs::read_dir(claude_dir()?.join("projects"))
            .ok()?
            .flatten()
            .map(|project| project.path().join(format!("{id}.jsonl")))
            .find(|p| p.is_file()),
        Agent::Codex => find_file(&codex_home()?.join("sessions"), &format!("-{id}.jsonl")),
        Agent::Shell => None,
    }
}

fn find_file(dir: &Path, suffix: &str) -> Option<PathBuf> {
    for e in fs::read_dir(dir).ok()?.flatten() {
        let path = e.path();
        if path.is_dir() {
            if let Some(found) = find_file(&path, suffix) {
                return Some(found);
            }
        } else if path.to_string_lossy().ends_with(suffix) {
            return Some(path);
        }
    }
    None
}
