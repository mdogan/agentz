//! Everything agentz knows about Claude Code and Codex, without any UI:
//! session transcripts, projects, saved tabs, rate limits and the status
//! line, and the processes running inside our shells.
//!
//! The app reaches it through UniFFI. `make` in `macos/` builds this as a
//! static library and generates its Swift side, which becomes the app's
//! `AgentzCore` module. Most types cross as they are; paths are strings in
//! Swift, and times are `Date`. This file holds the rest of the bridge:
//! functions, objects that keep state between calls (behind a `Mutex`,
//! since Swift may call them from any thread), and `ShellProcess`, whose
//! pids Swift wants as `pid_t`.

use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

mod procs;
mod project;
mod sessions;
mod state;
mod turns;
mod usage;

use sessions::{Session, SessionKey};
use state::SavedState;
use turns::{TerminalSignal, TurnUpdate};
use usage::Limits;

uniffi::setup_scaffolding!();

// A path is a string in Swift, where UniFFI names it `typealias PathBuf =
// String`.
uniffi::custom_type!(PathBuf, String, {
    remote,
    lower: |path| path.to_string_lossy().into_owned(),
    try_lift: |s| Ok(PathBuf::from(s)),
});

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    // A panic can't leave these half-updated in a way that matters more
    // than losing the app, so keep going.
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn pids(pids: &[i32]) -> Vec<u32> {
    pids.iter().filter_map(|&p| u32::try_from(p).ok()).collect()
}

#[derive(Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum CoreError {
    Failed(String),
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CoreError::Failed(message) => f.write_str(message),
        }
    }
}

impl From<anyhow::Error> for CoreError {
    fn from(e: anyhow::Error) -> Self {
        CoreError::Failed(format!("{e:#}"))
    }
}

// ---------- projects ----------

/// The folder new sessions start in: the top of the git worktree `dir` is
/// in, or `dir` itself outside a repo.
#[uniffi::export]
pub fn project_root(dir: PathBuf) -> PathBuf {
    project::root_of(&dir)
}

// ---------- scanning ----------

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Foreground {
    /// The process group that owns the terminal.
    pub group: i32,
    /// The name of its first process under the shell, e.g. `vim`.
    pub name: String,
}

/// What is running under one of our interactive shells.
#[derive(Clone, Debug, uniffi::Record)]
pub struct ShellProcess {
    pub pid: i32,
    /// The session of an agent the user started in the shell.
    pub agent: Option<SessionKey>,
    pub foreground: Option<Foreground>,
}

impl From<procs::ShellProcess> for ShellProcess {
    fn from(p: procs::ShellProcess) -> Self {
        ShellProcess {
            pid: p.pid as i32,
            agent: p.agent,
            foreground: p.foreground.map(|(group, name)| Foreground {
                group: group as i32,
                name,
            }),
        }
    }
}

#[derive(uniffi::Record)]
pub struct Scan {
    /// All sessions, newest first. None when they are the same as in the
    /// last scan of the same folder.
    pub sessions: Option<Vec<Session>>,
    pub shells: Vec<ShellProcess>,
    /// The thread each new Codex has open, by pid.
    pub codex_threads: HashMap<i32, String>,
    pub limits: Limits,
}

/// Reads transcripts, processes and rate limits. It keeps caches between
/// scans, so keep one and reuse it.
#[derive(Default, uniffi::Object)]
pub struct SessionScanner(Mutex<ScanState>);

#[derive(Default)]
struct ScanState {
    sessions: sessions::Scanner,
    codex_usage: usage::CodexReader,
    codex_links: procs::CodexLinks,
    /// The project of the folder the last scan was for. Asking git takes
    /// a process, so it is detected again only when it changed.
    project: Option<(PathBuf, project::Project)>,
    /// The sessions the last scan returned, and the folder it was for.
    returned: Option<(PathBuf, Vec<Session>)>,
}

impl ScanState {
    /// All sessions, with `in_project` set for the project of `dir`.
    fn scan_sessions(&mut self, dir: &Path) -> Vec<Session> {
        let fresh = matches!(&self.project, Some((d, p)) if d == dir && !p.is_stale());
        if !fresh {
            self.project = Some((dir.to_path_buf(), project::Project::detect(dir)));
        }
        let Some((_, project)) = &self.project else {
            unreachable!()
        };
        let mut sessions = self.sessions.scan();
        for s in &mut sessions {
            s.in_project = project.contains(&s.cwd);
        }
        sessions
    }
}

#[uniffi::export]
impl SessionScanner {
    #[uniffi::constructor]
    pub fn new() -> Self {
        SessionScanner::default()
    }

    /// Only the sessions, with `in_project` set for the project of `dir`.
    pub fn sessions(&self, dir: PathBuf) -> Vec<Session> {
        lock(&self.0).scan_sessions(&dir)
    }

    /// Everything the app shows. `dir` is the folder whose project the
    /// window shows; `shell_pids` are our shells; `new_codex_pids` are
    /// Codex sessions we started that don't know their id yet.
    pub fn scan(&self, dir: PathBuf, shell_pids: Vec<i32>, new_codex_pids: Vec<i32>) -> Scan {
        let mut s = lock(&self.0);
        let sessions = s.scan_sessions(&dir);
        let ScanState {
            sessions: scanner,
            codex_usage,
            codex_links,
            returned,
            ..
        } = &mut *s;
        let procs = procs::Snapshot::default();
        let shells = procs::shell_processes(&pids(&shell_pids), &procs, &sessions, codex_links);
        let threads = procs::codex_threads(&pids(&new_codex_pids), &procs, &sessions, codex_links);
        let limits = Limits {
            claude: usage::claude(),
            codex: codex_usage.read(scanner.codex_files()),
        };
        // Most scans find nothing new. Then Swift keeps what it has
        // instead of decoding and comparing every session again.
        let changed = returned
            .as_ref()
            .is_none_or(|(d, last)| *d != dir || *last != sessions);
        if changed {
            *returned = Some((dir, sessions.clone()));
        }
        Scan {
            sessions: changed.then_some(sessions),
            shells: shells.into_iter().map(Into::into).collect(),
            codex_threads: threads
                .into_iter()
                .map(|(pid, id)| (pid as i32, id))
                .collect(),
            limits,
        }
    }
}

/// The process's current directory, even when its shell does not report
/// it (OSC 7).
#[uniffi::export]
pub fn working_directory(pid: i32) -> Option<PathBuf> {
    procs::working_dir(u32::try_from(pid).ok()?)
}

// ---------- Claude's status line ----------

#[derive(uniffi::Record)]
pub struct ClaudeSettings {
    /// The `--settings` value that makes Claude run `<exe> statusline`.
    pub settings: String,
    /// The user's own status line command, for `user_status_line_var()`.
    pub user_command: Option<String>,
}

#[uniffi::export]
pub fn claude_settings(cwd: PathBuf, exe: PathBuf) -> Option<ClaudeSettings> {
    let (settings, user_command) = usage::claude_settings(&cwd, &exe)?;
    Some(ClaudeSettings {
        settings,
        user_command,
    })
}

/// The environment variable that passes the user's status line command to
/// `agentz statusline`.
#[uniffi::export]
pub fn user_status_line_var() -> String {
    usage::USER_STATUS_LINE_VAR.to_string()
}

/// `agentz statusline install|uninstall`. Returns what was done.
#[uniffi::export]
pub fn configure_status_line(action: String, exe: PathBuf) -> Result<String, CoreError> {
    Ok(usage::configure_status_line(&action, &exe)?)
}

/// `agentz statusline`: reads Claude's status from stdin, saves the rate
/// limits, runs the user's own status line and returns its exit code.
#[uniffi::export]
pub fn run_status_line() -> i32 {
    usage::status_line().unwrap_or_else(|e| {
        eprintln!("agentz: {e:#}");
        1
    })
}

/// Quotes `s` for `sh`.
#[uniffi::export]
pub fn shell_quote(s: String) -> String {
    usage::shell_quote(&s)
}

// ---------- saved tabs ----------

/// Saves the open tabs on quit. Tabs saved by other windows are kept.
#[uniffi::export]
pub fn save_tabs(state: SavedState) -> Result<(), CoreError> {
    Ok(state::save(state)?)
}

/// Takes the saved tabs, so only one launch restores them.
#[uniffi::export]
pub fn take_tabs() -> Result<Option<SavedState>, CoreError> {
    Ok(state::take()?)
}

// ---------- turns ----------

/// Tells when an agent is working and when the user should hear that it is
/// done, from what it signals to its terminal. One per terminal.
#[derive(Default, uniffi::Object)]
pub struct TurnTracker(Mutex<turns::Turns>);

#[uniffi::export]
impl TurnTracker {
    #[uniffi::constructor]
    pub fn new() -> Self {
        TurnTracker::default()
    }

    pub fn receive(&self, signal: TerminalSignal) {
        lock(&self.0).receive(signal);
    }

    /// The user typed. It starts a new turn: the agent may notify again
    /// when it is done.
    pub fn user_input(&self) {
        lock(&self.0).user_input();
    }

    /// Forgets what the program said about being busy, e.g. when the agent
    /// in a shell exits and the shell is left.
    pub fn forget_reported_busy(&self) {
        lock(&self.0).forget_reported_busy();
    }

    pub fn is_busy(&self) -> bool {
        lock(&self.0).is_busy()
    }

    /// Reads the signals received since the last call and tells whether
    /// the user should hear about it. `running` is false once the process
    /// exited.
    pub fn update(&self, running: bool) -> TurnUpdate {
        lock(&self.0).update(running)
    }
}
