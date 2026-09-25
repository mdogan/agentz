//! Finds agents the user started by hand inside one of our shells, and the
//! session each one is using.
//!
//! Claude Code: writes `~/.claude/sessions/<pid>.json` with its `sessionId`.
//! Codex:       older versions keep their `rollout-<ts>-<session-id>.jsonl`
//!              file open. Since 0.157 a shared `codex app-server` daemon
//!              writes it instead, so we pair each `codex` process with a
//!              thread that is open (has a lock file) in the same folder.

use std::cell::OnceCell;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime};

use serde_json::Value;

use crate::sessions::{Agent, Session, SessionKey, claude_dir, codex_home};

/// `ps` reports elapsed time in whole seconds, so the estimated process
/// start can be up to a second later than the real one.
const CODEX_LOCK_SLACK: Duration = Duration::from_secs(1);

/// Links established on earlier scans. Keep them while both the process and
/// its lock exist, so another thread opening cannot move a shell's title.
#[derive(Default)]
pub struct CodexLinks {
    by_pid: HashMap<u32, LinkedThread>,
}

struct LinkedThread {
    id: String,
    started: SystemTime,
}

/// What is running under one of our interactive shells.
pub struct ShellProcess {
    pub pid: u32,
    pub agent: Option<SessionKey>,
    /// The foreground process group and its first process under the shell.
    pub foreground: Option<(u32, String)>,
}

struct Process {
    ppid: u32,
    pgid: u32,
    tpgid: Option<u32>,
    argv0: String,
    /// The first argument, e.g. `app-server` for Codex's daemon.
    arg1: Option<String>,
    /// Seconds since the process started.
    age: Option<u64>,
    /// Time at which `ps` finished, paired with its elapsed-time snapshot.
    observed_at: SystemTime,
}

/// For each shell pid, the session of the agent running under it, if any.
#[cfg(test)]
pub fn agents_in_shells(shells: &[u32]) -> Vec<(u32, SessionKey)> {
    let sessions = crate::sessions::Scanner::default().scan();
    shell_processes(shells, &sessions, &mut CodexLinks::default())
        .into_iter()
        .filter_map(|s| s.agent.map(|agent| (s.pid, agent)))
        .collect()
}

/// Finds the foreground command and any linked agent for each shell.
/// `sessions` gives the folder of each Codex thread.
pub fn shell_processes(
    shells: &[u32],
    sessions: &[Session],
    codex_links: &mut CodexLinks,
) -> Vec<ShellProcess> {
    if shells.is_empty() {
        codex_links.by_pid.clear();
        return Vec::new();
    }
    let procs = process_table();
    let mut codex_threads = || codex_threads_by_pid(&procs, sessions, codex_links);
    shell_processes_from_table(
        shells,
        &procs,
        claude_dir().map(|d| d.join("sessions")).as_deref(),
        &mut codex_threads,
    )
}

fn shell_processes_from_table(
    shells: &[u32],
    procs: &HashMap<u32, Process>,
    claude_sessions: Option<&Path>,
    mut codex_threads: &mut dyn FnMut() -> HashMap<u32, String>,
) -> Vec<ShellProcess> {
    // Only looked up once a shell turns out to run Codex.
    let codex_threads_by_pid = OnceCell::new();
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for (&pid, proc) in procs {
        children.entry(proc.ppid).or_default().push(pid);
    }
    for pids in children.values_mut() {
        pids.sort_unstable();
    }

    let mut out = Vec::new();
    for &shell in shells {
        let foreground_group = procs
            .get(&shell)
            .and_then(|p| p.tpgid.filter(|group| *group != p.pgid));
        let mut state = ShellProcess {
            pid: shell,
            agent: None,
            foreground: None,
        };
        // Breadth-first, so the agent the user started wins over anything
        // that agent started itself.
        let mut queue: Vec<u32> = children.get(&shell).cloned().unwrap_or_default();
        let mut i = 0;
        while i < queue.len() {
            let pid = queue[i];
            i += 1;
            let Some(proc) = procs.get(&pid) else {
                continue;
            };
            if state.foreground.is_none() && foreground_group == Some(proc.pgid) {
                state.foreground = Some((proc.pgid, basename(&proc.argv0).to_string()));
            }
            let found = claude_sessions
                .and_then(|dir| claude_session(dir, pid))
                .map(|id| (Agent::Claude, id))
                .or_else(|| {
                    is_codex_tui(proc)
                        .then(|| {
                            codex_session(pid).or_else(|| {
                                codex_threads_by_pid
                                    .get_or_init(&mut codex_threads)
                                    .get(&pid)
                                    .cloned()
                            })
                        })
                        .flatten()
                        .map(|id| (Agent::Codex, id))
                });
            if let Some(key) = found {
                state.agent = Some(key);
                break;
            }
            queue.extend(children.get(&pid).into_iter().flatten());
        }
        out.push(state);
    }
    out
}

/// pid -> parent, process group, terminal foreground group, age, argv.
fn process_table() -> HashMap<u32, Process> {
    let mut out = HashMap::new();
    let Ok(res) = Command::new("ps")
        .args(["-eo", "pid=,ppid=,pgid=,tpgid=,etime=,args="])
        .output()
    else {
        return out;
    };
    let observed_at = SystemTime::now();
    for line in String::from_utf8_lossy(&res.stdout).lines() {
        let mut parts = line.split_whitespace();
        let (Some(pid), Some(ppid), Some(pgid), Some(tpgid), Some(etime), Some(argv0)) = (
            parts.next(),
            parts.next(),
            parts.next(),
            parts.next(),
            parts.next(),
            parts.next(),
        ) else {
            continue;
        };
        if let (Ok(pid), Ok(ppid), Ok(pgid)) = (pid.parse(), ppid.parse(), pgid.parse()) {
            out.insert(
                pid,
                Process {
                    ppid,
                    pgid,
                    tpgid: tpgid.parse().ok(),
                    argv0: argv0.to_string(),
                    arg1: parts.next().map(str::to_string),
                    age: parse_etime(etime),
                    observed_at,
                },
            );
        }
    }
    out
}

/// `ps` elapsed time: `[[dd-]hh:]mm:ss`.
fn parse_etime(s: &str) -> Option<u64> {
    let (days, rest) = match s.split_once('-') {
        Some((d, rest)) => (d.parse::<u64>().ok()?, rest),
        None => (0, s),
    };
    let mut secs = 0;
    for part in rest.split(':') {
        secs = secs * 60 + part.parse::<u64>().ok()?;
    }
    Some(days * 86_400 + secs)
}

/// An interactive `codex`, not its daemon or a one-shot command.
fn is_codex_tui(proc: &Process) -> bool {
    basename(&proc.argv0) == "codex"
        && !matches!(
            proc.arg1.as_deref(),
            Some(
                "agents"
                    | "exec"
                    | "e"
                    | "review"
                    | "login"
                    | "logout"
                    | "mcp"
                    | "plugin"
                    | "app-server"
                    | "remote-control"
                    | "app"
                    | "completion"
                    | "update"
                    | "doctor"
                    | "sandbox"
                    | "debug"
                    | "apply"
                    | "a"
                    | "queue"
                    | "archive"
                    | "delete"
                    | "migrate-rollouts"
                    | "unarchive"
                    | "cloud"
                    | "exec-server"
                    | "mcp-server"
                    | "features"
                    | "help"
            )
        )
}

/// These commands can have open threads too; they must claim their own lock
/// before a shell's interactive Codex can be linked to one.
fn is_codex_noninteractive_thread(proc: &Process) -> bool {
    basename(&proc.argv0) == "codex"
        && matches!(proc.arg1.as_deref(), Some("exec" | "e" | "review"))
}

fn claude_session(dir: &Path, pid: u32) -> Option<String> {
    let text = fs::read_to_string(dir.join(format!("{pid}.json"))).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    v["sessionId"]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// The session id from the rollout file the process has open. Codex only
/// creates it once the session has its first message.
fn codex_session(pid: u32) -> Option<String> {
    open_files(pid).iter().find_map(|p| {
        let name = p.file_name()?.to_str()?;
        let stem = name.strip_prefix("rollout-")?.strip_suffix(".jsonl")?;
        // The id is the trailing UUID.
        let id = stem.get(stem.len().checked_sub(36)?..)?;
        Some(id.to_string())
    })
}

struct CodexProcess {
    pid: u32,
    cwd: PathBuf,
    started: SystemTime,
    tui: bool,
}

struct OpenThread {
    id: String,
    cwd: PathBuf,
    opened: SystemTime,
    tui: bool,
}

/// For Codex versions whose daemon writes the rollout file: the thread each
/// running `codex` has open. Every `codex` on the machine takes part, so a
/// shell's `codex` does not take the thread of one started elsewhere.
fn codex_threads_by_pid(
    procs: &HashMap<u32, Process>,
    sessions: &[Session],
    links: &mut CodexLinks,
) -> HashMap<u32, String> {
    let running = procs
        .iter()
        .filter(|(_, p)| is_codex_tui(p) || is_codex_noninteractive_thread(p))
        .filter_map(|(&pid, p)| {
            Some(CodexProcess {
                pid,
                cwd: working_dir(pid)?,
                started: p.observed_at.checked_sub(Duration::from_secs(p.age?))?,
                tui: is_codex_tui(p),
            })
        })
        .collect();
    pair_codex_threads(links, running, open_codex_threads(sessions))
}

/// Codex holds `thread-writer-locks/<thread-id>.lock` while a thread is
/// open and removes it after.
fn open_codex_threads(sessions: &[Session]) -> Vec<OpenThread> {
    let Some(dir) = codex_home().map(|h| h.join("thread-writer-locks")) else {
        return Vec::new();
    };
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|e| {
            let path = e.path();
            let id = path.file_name()?.to_str()?.strip_suffix(".lock")?;
            let session = sessions
                .iter()
                .find(|s| s.agent == Agent::Codex && s.id == id)?;
            Some(OpenThread {
                id: id.to_string(),
                // Process folders come back with symlinks resolved.
                cwd: session
                    .cwd
                    .canonicalize()
                    .unwrap_or_else(|_| session.cwd.clone()),
                opened: e.metadata().ok()?.modified().ok()?,
                tui: session.originator.as_deref() == Some("codex-tui"),
            })
        })
        .collect()
}

/// Link only matches that occur in every maximum one-to-one matching. More
/// than one plausible owner is safer left unlinked than linked to the wrong
/// shell. Previous links stay in place until their process or lock goes away.
fn pair_codex_threads(
    links: &mut CodexLinks,
    running: Vec<CodexProcess>,
    threads: Vec<OpenThread>,
) -> HashMap<u32, String> {
    links.by_pid.retain(|pid, linked| {
        let Some(p) = running.iter().find(|p| p.pid == *pid) else {
            return false;
        };
        let same_start = p
            .started
            .duration_since(linked.started)
            .or_else(|_| linked.started.duration_since(p.started))
            .is_ok_and(|delta| delta <= Duration::from_secs(2));
        same_start
            && threads
                .iter()
                .any(|t| t.id == linked.id && t.cwd == p.cwd && (!p.tui || t.tui))
    });
    let claimed: HashSet<_> = links.by_pid.values().map(|link| link.id.clone()).collect();
    let running: Vec<_> = running
        .into_iter()
        .filter(|p| !links.by_pid.contains_key(&p.pid))
        .collect();
    let threads: Vec<_> = threads
        .into_iter()
        .filter(|t| !claimed.contains(&t.id))
        .collect();
    let best = maximum_matching(&running, &threads, None);
    let size = best.iter().filter(|matched| matched.is_some()).count();
    for (process, thread) in best.into_iter().enumerate() {
        let Some(thread) = thread else { continue };
        let without = maximum_matching(&running, &threads, Some((process, thread)));
        if without.iter().filter(|matched| matched.is_some()).count() < size {
            links.by_pid.insert(
                running[process].pid,
                LinkedThread {
                    id: threads[thread].id.clone(),
                    started: running[process].started,
                },
            );
        }
    }
    links
        .by_pid
        .iter()
        .map(|(&pid, linked)| (pid, linked.id.clone()))
        .collect()
}

fn can_pair(p: &CodexProcess, t: &OpenThread) -> bool {
    p.cwd == t.cwd
        && (!p.tui || t.tui)
        && t.opened
            .checked_add(CODEX_LOCK_SLACK)
            .is_some_and(|opened| opened >= p.started)
}

/// Returns the matched thread index for each process. `without` lets the
/// caller check whether an edge is required by every maximum matching.
fn maximum_matching(
    running: &[CodexProcess],
    threads: &[OpenThread],
    without: Option<(usize, usize)>,
) -> Vec<Option<usize>> {
    fn extend(
        process: usize,
        running: &[CodexProcess],
        threads: &[OpenThread],
        without: Option<(usize, usize)>,
        seen: &mut [bool],
        owners: &mut [Option<usize>],
    ) -> bool {
        for (thread, t) in threads.iter().enumerate() {
            if seen[thread] || without == Some((process, thread)) || !can_pair(&running[process], t)
            {
                continue;
            }
            seen[thread] = true;
            if owners[thread]
                .is_none_or(|owner| extend(owner, running, threads, without, seen, owners))
            {
                owners[thread] = Some(process);
                return true;
            }
        }
        false
    }

    let mut owners = vec![None; threads.len()];
    for process in 0..running.len() {
        let mut seen = vec![false; threads.len()];
        extend(process, running, threads, without, &mut seen, &mut owners);
    }
    let mut result = vec![None; running.len()];
    for (thread, owner) in owners.into_iter().enumerate() {
        if let Some(process) = owner {
            result[process] = Some(thread);
        }
    }
    result
}

fn open_files(pid: u32) -> Vec<PathBuf> {
    let proc_fd = PathBuf::from(format!("/proc/{pid}/fd"));
    if let Ok(entries) = fs::read_dir(&proc_fd) {
        return entries
            .flatten()
            .filter_map(|e| fs::read_link(e.path()).ok())
            .collect();
    }
    let Ok(res) = Command::new("lsof")
        .args(["-w", "-p", &pid.to_string(), "-Fn"])
        .output()
    else {
        return Vec::new();
    };
    String::from_utf8_lossy(&res.stdout)
        .lines()
        .filter_map(|l| l.strip_prefix('n'))
        .map(PathBuf::from)
        .collect()
}

/// The process's current directory, even when its shell does not send OSC 7.
#[cfg(target_os = "macos")]
pub fn working_dir(pid: u32) -> Option<PathBuf> {
    use std::ffi::{CStr, OsStr};
    use std::os::unix::ffi::OsStrExt;

    // SAFETY: proc_vnodepathinfo is plain data; all zeros is a valid value.
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
    // SAFETY: the buffer is `size` bytes and lives across the call.
    let n = unsafe {
        libc::proc_pidinfo(
            pid as libc::c_int,
            libc::PROC_PIDVNODEPATHINFO,
            0,
            (&raw mut info).cast(),
            size,
        )
    };
    if n != size {
        return None;
    }
    let path = info.pvi_cdir.vip_path.as_flattened();
    // SAFETY: c_char and u8 have the same size and alignment.
    let bytes = unsafe { std::slice::from_raw_parts(path.as_ptr().cast::<u8>(), path.len()) };
    let path = CStr::from_bytes_until_nul(bytes).ok()?.to_bytes();
    (!path.is_empty()).then(|| PathBuf::from(OsStr::from_bytes(path)))
}

/// The process's current directory, even when its shell does not send OSC 7.
#[cfg(not(target_os = "macos"))]
pub fn working_dir(pid: u32) -> Option<PathBuf> {
    fs::read_link(format!("/proc/{pid}/cwd")).ok()
}

fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn foreground_command_ignores_background_and_unrelated_processes() {
        let mut procs = HashMap::new();
        let mut add = |pid, ppid, pgid, tpgid, argv0: &str| {
            procs.insert(
                pid,
                Process {
                    ppid,
                    pgid,
                    tpgid,
                    argv0: argv0.into(),
                    arg1: None,
                    age: None,
                    observed_at: SystemTime::UNIX_EPOCH,
                },
            );
        };
        add(10, 1, 10, Some(30), "/bin/fish");
        add(20, 10, 20, Some(30), "/bin/long-background-job");
        add(30, 10, 30, Some(30), "/usr/bin/sleep");
        add(31, 30, 30, Some(30), "/usr/bin/cat");
        add(40, 1, 30, Some(30), "/usr/bin/unrelated");

        let found = shell_processes_from_table(&[10], &procs, None, &mut HashMap::new);
        assert_eq!(found[0].foreground, Some((30, "sleep".into())));

        procs.get_mut(&10).unwrap().tpgid = Some(10);
        let found = shell_processes_from_table(&[10], &procs, None, &mut HashMap::new);
        assert_eq!(found[0].foreground, None);
    }

    #[test]
    fn parses_etime() {
        assert_eq!(parse_etime("05:02"), Some(302));
        assert_eq!(parse_etime("01:07:20"), Some(4040));
        assert_eq!(parse_etime("2-00:00:01"), Some(172_801));
        assert_eq!(parse_etime("x"), None);
    }

    #[test]
    fn exec_processes_claim_threads_but_are_not_shell_sessions() {
        let process = Process {
            ppid: 1,
            pgid: 2,
            tpgid: Some(2),
            argv0: "/usr/local/bin/codex".into(),
            arg1: Some("exec".into()),
            age: Some(10),
            observed_at: SystemTime::UNIX_EPOCH,
        };
        assert!(!is_codex_tui(&process));
        assert!(is_codex_noninteractive_thread(&process));
    }

    #[test]
    fn pairs_codex_processes_with_open_threads() {
        let t0 = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let at = |secs| t0 + Duration::from_secs(secs);
        let process = |pid, cwd: &str, started| CodexProcess {
            pid,
            cwd: cwd.into(),
            started,
            tui: true,
        };
        let thread = |id: &str, cwd: &str, opened| OpenThread {
            id: id.into(),
            cwd: cwd.into(),
            opened,
            tui: true,
        };
        let found = pair_codex_threads(
            &mut CodexLinks::default(),
            vec![
                process(1, "/a", at(0)),
                process(2, "/a", at(100)),
                process(3, "/b", at(0)),
                // No thread yet; must not take process 1's.
                process(4, "/a", at(200)),
            ],
            vec![
                // Resumed a while after the process started.
                thread("a1", "/a", at(50)),
                thread("a2", "/a", at(100)),
                thread("b1", "/b", at(10)),
                // Left over from before the process started.
                thread("stale", "/b", at(0) - Duration::from_secs(60)),
            ],
        );
        assert_eq!(
            found,
            HashMap::from([(1, "a1".into()), (2, "a2".into()), (3, "b1".into())])
        );
    }

    #[test]
    fn fresh_codex_does_not_claim_recent_older_thread() {
        let t0 = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let running = vec![
            CodexProcess {
                pid: 1,
                cwd: "/a".into(),
                started: t0,
                tui: true,
            },
            CodexProcess {
                pid: 2,
                cwd: "/a".into(),
                started: t0 + Duration::from_secs(102),
                tui: true,
            },
        ];
        let threads = vec![OpenThread {
            id: "older".into(),
            cwd: "/a".into(),
            opened: t0 + Duration::from_secs(100),
            tui: true,
        }];
        assert_eq!(
            pair_codex_threads(&mut CodexLinks::default(), running, threads),
            HashMap::from([(1, "older".into())])
        );
    }

    #[test]
    fn exec_thread_cannot_replace_interactive_thread() {
        let t0 = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let running = vec![
            CodexProcess {
                pid: 1,
                cwd: "/a".into(),
                started: t0,
                tui: true,
            },
            CodexProcess {
                pid: 2,
                cwd: "/a".into(),
                started: t0 + Duration::from_secs(20),
                tui: false,
            },
        ];
        let threads = vec![
            OpenThread {
                id: "interactive".into(),
                cwd: "/a".into(),
                opened: t0 + Duration::from_secs(10),
                tui: true,
            },
            OpenThread {
                id: "exec".into(),
                cwd: "/a".into(),
                opened: t0 + Duration::from_secs(21),
                tui: false,
            },
        ];
        assert_eq!(
            pair_codex_threads(&mut CodexLinks::default(), running, threads),
            HashMap::from([(1, "interactive".into()), (2, "exec".into())])
        );
        assert!(
            pair_codex_threads(
                &mut CodexLinks::default(),
                vec![CodexProcess {
                    pid: 1,
                    cwd: "/a".into(),
                    started: t0,
                    tui: true,
                }],
                vec![OpenThread {
                    id: "exec".into(),
                    cwd: "/a".into(),
                    opened: t0 + Duration::from_secs(21),
                    tui: false,
                }]
            )
            .is_empty()
        );
    }

    #[test]
    fn ambiguous_codex_threads_stay_unlinked_and_existing_links_stay_put() {
        let t0 = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let process = |pid| CodexProcess {
            pid,
            cwd: "/a".into(),
            started: t0,
            tui: true,
        };
        let thread = |id: &str, seconds| OpenThread {
            id: id.into(),
            cwd: "/a".into(),
            opened: t0 + Duration::from_secs(seconds),
            tui: true,
        };
        let mut links = CodexLinks::default();
        assert!(
            pair_codex_threads(
                &mut links,
                vec![process(1), process(2)],
                vec![thread("a", 10), thread("b", 11)]
            )
            .is_empty()
        );
        assert_eq!(
            pair_codex_threads(&mut links, vec![process(1)], vec![thread("a", 10)]),
            HashMap::from([(1, "a".into())])
        );
        assert_eq!(
            pair_codex_threads(
                &mut links,
                vec![process(1)],
                vec![thread("a", 10), thread("b", 11)]
            ),
            HashMap::from([(1, "a".into())])
        );
        assert_eq!(
            pair_codex_threads(&mut links, vec![process(1)], vec![thread("b", 11)]),
            HashMap::from([(1, "b".into())])
        );
    }
}
