//! Finds agents the user started by hand inside one of our shells, and the
//! session each one is using, Claude sessions that run outside agentz, and
//! programs that our terminals left running.
//!
//! Claude Code: writes `~/.claude/sessions/<pid>.json` with its `sessionId`.
//! Codex:       older versions keep their `rollout-<ts>-<session-id>.jsonl`
//!              file open. Since 0.157 a shared `codex app-server` daemon
//!              writes it instead, so we pair each `codex` process with a
//!              thread that is open (has a lock file) in the same folder.
//! Left running: a program started in the background, e.g. a dev server an
//!              agent started with `nohup`, goes on when the shell that
//!              started it ends, and launchd adopts it. Its folder and start
//!              time tell which session it came from. (Its environment would
//!              say more, but macOS shows that to no other process.)

use std::cell::OnceCell;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde_json::Value;

use crate::sessions::{Agent, Session, SessionKey, claude_dir, codex_home};

/// A thread's lock is created after its process starts. Outside macOS the
/// start comes from `ps`, which reports whole seconds, so it can be up to a
/// second later than the real one.
const CODEX_LOCK_SLACK: Duration = Duration::from_secs(1);

/// The processes on the machine, read on first use, and the Codex threads
/// paired with them. One per scan, so everything in the scan sees the same
/// processes and nothing reads them twice.
#[derive(Default)]
pub struct Snapshot {
    table: OnceCell<HashMap<u32, Process>>,
    codex_threads: OnceCell<HashMap<u32, String>>,
}

impl Snapshot {
    fn table(&self) -> &HashMap<u32, Process> {
        self.table.get_or_init(process_table)
    }

    /// See `codex_threads_by_pid`.
    fn codex_threads(&self, sessions: &[Session], links: &mut CodexLinks) -> &HashMap<u32, String> {
        self.codex_threads
            .get_or_init(|| codex_threads_by_pid(self.table(), sessions, links))
    }
}

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
    pid: u32,
    ppid: u32,
    pgid: u32,
    tpgid: Option<u32>,
    /// The program's name, cut to 16 bytes. Stands in for `argv0` when the
    /// arguments can't be read, e.g. for another user's process.
    comm: String,
    /// Known for the user's own processes.
    started: Option<SystemTime>,
    /// Read on first use, since most processes are never asked.
    args: OnceCell<Args>,
}

#[derive(Clone)]
struct Args {
    argv0: String,
    /// The first argument, e.g. `app-server` for Codex's daemon.
    arg1: Option<String>,
    /// The command line to show, e.g. `node next dev`. Paths are cut to
    /// their last part.
    command: String,
}

impl Process {
    fn args(&self) -> &Args {
        self.args.get_or_init(|| {
            read_args(self.pid).unwrap_or_else(|| Args {
                argv0: self.comm.clone(),
                arg1: None,
                command: self.comm.clone(),
            })
        })
    }

    fn argv0(&self) -> &str {
        &self.args().argv0
    }

    fn arg1(&self) -> Option<&str> {
        self.args().arg1.as_deref()
    }
}

/// Finds the foreground command and any linked agent for each shell.
/// `sessions` gives the folder of each Codex thread.
pub fn shell_processes(
    shells: &[u32],
    procs: &Snapshot,
    sessions: &[Session],
    codex_links: &mut CodexLinks,
) -> Vec<ShellProcess> {
    if shells.is_empty() {
        codex_links.by_pid.clear();
        return Vec::new();
    }
    let mut codex_threads = || procs.codex_threads(sessions, codex_links).clone();
    shell_processes_from_table(
        shells,
        procs.table(),
        claude_dir().map(|d| d.join("sessions")).as_deref(),
        &mut codex_threads,
    )
}

/// The thread each of these `codex` processes has open, for the ones
/// where that is certain. Every `codex` on the machine takes part in the
/// pairing, so one process can't take another one's thread.
pub fn codex_threads(
    pids: &[u32],
    procs: &Snapshot,
    sessions: &[Session],
    codex_links: &mut CodexLinks,
) -> HashMap<u32, String> {
    let mut out = HashMap::new();
    for &pid in pids {
        let id = codex_session(pid).or_else(|| {
            procs
                .codex_threads(sessions, codex_links)
                .get(&pid)
                .cloned()
        });
        if let Some(id) = id {
            out.insert(pid, id);
        }
    }
    out
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
                state.foreground = Some((proc.pgid, basename(proc.argv0()).to_string()));
            }
            let found = claude_sessions
                .and_then(|dir| claude_session(dir, pid))
                .map(|id| SessionKey {
                    agent: Agent::Claude,
                    id,
                })
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
                        .map(|id| SessionKey {
                            agent: Agent::Codex,
                            id,
                        })
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

/// pid -> parent, groups, name and start time, from the kernel.
#[cfg(target_os = "macos")]
fn process_table() -> HashMap<u32, Process> {
    let mut pids: Vec<libc::c_int> = vec![0; 2048];
    loop {
        let bytes = (pids.len() * size_of::<libc::c_int>()) as libc::c_int;
        // SAFETY: the buffer is `bytes` bytes long.
        let n = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), bytes) };
        let Ok(n) = usize::try_from(n) else {
            return HashMap::new();
        };
        if n < pids.len() {
            pids.truncate(n);
            break;
        }
        // It filled the buffer, so there may be more.
        pids.resize(pids.len() * 2, 0);
    }
    pids.into_iter()
        .filter_map(|pid| Some((u32::try_from(pid).ok()?, process(pid)?)))
        .collect()
}

#[cfg(target_os = "macos")]
fn process(pid: libc::c_int) -> Option<Process> {
    // The full info is only given for the user's own processes.
    // SAFETY: PROC_PIDTBSDINFO fills a proc_bsdinfo.
    if let Some(info) = unsafe { pid_info::<libc::proc_bsdinfo>(pid, libc::PROC_PIDTBSDINFO) } {
        return Some(Process {
            pid: info.pbi_pid,
            ppid: info.pbi_ppid,
            pgid: info.pbi_pgid,
            tpgid: Some(info.e_tpgid),
            comm: c_string(&info.pbi_comm),
            started: Some(
                SystemTime::UNIX_EPOCH
                    + Duration::from_secs(info.pbi_start_tvsec)
                    + Duration::from_micros(info.pbi_start_tvusec),
            ),
            args: OnceCell::new(),
        });
    }
    // SAFETY: PROC_PIDT_SHORTBSDINFO fills a proc_bsdshortinfo.
    let info = unsafe { pid_info::<libc::proc_bsdshortinfo>(pid, libc::PROC_PIDT_SHORTBSDINFO) }?;
    Some(Process {
        pid: info.pbsi_pid,
        ppid: info.pbsi_ppid,
        pgid: info.pbsi_pgid,
        tpgid: None,
        comm: c_string(&info.pbsi_comm),
        started: None,
        args: OnceCell::new(),
    })
}

/// `proc_pidinfo` for a flavor that fills a `T`.
///
/// # Safety
///
/// `T` must be the plain-data struct that `flavor` fills.
#[cfg(target_os = "macos")]
unsafe fn pid_info<T>(pid: libc::c_int, flavor: libc::c_int) -> Option<T> {
    let mut info = std::mem::MaybeUninit::<T>::zeroed();
    let size = size_of::<T>() as libc::c_int;
    // SAFETY: the buffer is `size` bytes and lives across the call.
    let n = unsafe { libc::proc_pidinfo(pid, flavor, 0, info.as_mut_ptr().cast(), size) };
    // SAFETY: T is plain data, zeroed and then filled by the kernel.
    (n == size).then(|| unsafe { info.assume_init() })
}

/// argv[0] and argv[1] from `KERN_PROCARGS2`.
#[cfg(target_os = "macos")]
fn read_args(pid: u32) -> Option<Args> {
    use std::ptr::null_mut;

    let mut mib = [
        libc::CTL_KERN,
        libc::KERN_PROCARGS2,
        libc::c_int::try_from(pid).ok()?,
    ];
    let mut size = 0;
    // SAFETY: with no buffer, sysctl only writes the size it needs.
    if unsafe { libc::sysctl(mib.as_mut_ptr(), 3, null_mut(), &mut size, null_mut(), 0) } != 0 {
        return None;
    }
    let mut buf = vec![0u8; size];
    // SAFETY: the buffer is `size` bytes long.
    let ok = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            buf.as_mut_ptr().cast(),
            &mut size,
            null_mut(),
            0,
        )
    } == 0;
    ok.then(|| parse_procargs(buf.get(..size)?))?
}

/// `KERN_PROCARGS2` gives argc, the program's path, NULs up to a word
/// boundary, then the arguments, each ending in a NUL. The environment
/// may follow; macOS 27 leaves it out.
fn parse_procargs(buf: &[u8]) -> Option<Args> {
    let argc = usize::try_from(i32::from_ne_bytes(buf.get(..4)?.try_into().ok()?)).ok()?;
    let rest = &buf[4..];
    let rest = &rest[rest.iter().position(|&b| b == 0)?..];
    let rest = &rest[rest.iter().position(|&b| b != 0)?..];
    let args: Vec<String> = rest
        .split(|&b| b == 0)
        .take(argc)
        .map(|a| String::from_utf8_lossy(a).into_owned())
        .collect();
    Some(Args {
        argv0: args.first()?.clone(),
        arg1: args.get(1).cloned(),
        command: command_line(&args),
    })
}

/// `node next dev` for `/usr/bin/node /x/node_modules/.bin/next dev`: the
/// program and its arguments, with paths cut to their last part.
fn command_line(args: &[String]) -> String {
    let words: Vec<&str> = args
        .iter()
        .map(|a| if a.starts_with('/') { basename(a) } else { a })
        .collect();
    let line = words.join(" ");
    match line.char_indices().nth(80) {
        Some((cut, _)) => format!("{}…", &line[..cut]),
        None => line,
    }
}

#[cfg(target_os = "macos")]
fn c_string(chars: &[libc::c_char]) -> String {
    // SAFETY: c_char and u8 have the same size and alignment.
    let bytes = unsafe { std::slice::from_raw_parts(chars.as_ptr().cast::<u8>(), chars.len()) };
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

/// pid -> parent, process group, terminal foreground group, start, argv.
#[cfg(not(target_os = "macos"))]
fn process_table() -> HashMap<u32, Process> {
    let mut out = HashMap::new();
    let Ok(res) = std::process::Command::new("ps")
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
            let arg1 = parts.next().map(str::to_string);
            let args = Args {
                argv0: argv0.to_string(),
                command: command_line(
                    &std::iter::once(argv0.to_string())
                        .chain(arg1.clone())
                        .collect::<Vec<_>>(),
                ),
                arg1,
            };
            out.insert(
                pid,
                Process {
                    pid,
                    ppid,
                    pgid,
                    tpgid: tpgid.parse().ok(),
                    comm: basename(argv0).to_string(),
                    started: parse_etime(etime)
                        .and_then(|age| observed_at.checked_sub(Duration::from_secs(age))),
                    args: OnceCell::from(args),
                },
            );
        }
    }
    out
}

/// `process_table` read them all already.
#[cfg(not(target_os = "macos"))]
fn read_args(_pid: u32) -> Option<Args> {
    None
}

/// `ps` elapsed time: `[[dd-]hh:]mm:ss`.
#[cfg(any(test, not(target_os = "macos")))]
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
    basename(proc.argv0()) == "codex"
        && !matches!(
            proc.arg1(),
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
    basename(proc.argv0()) == "codex" && matches!(proc.arg1(), Some("exec" | "e" | "review"))
}

fn claude_session(dir: &Path, pid: u32) -> Option<String> {
    let text = fs::read_to_string(dir.join(format!("{pid}.json"))).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    v["sessionId"]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// A Claude session whose process runs outside agentz: in another
/// terminal, an editor, or another agentz.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct RunningElsewhere {
    pub id: String,
    /// Claude says it is working on a turn.
    pub busy: bool,
    /// The app it runs in, e.g. `Ghostty` or `Visual Studio Code`, when
    /// known.
    pub app: Option<String>,
}

/// Claude writes `startedAt` once it is running, so its process started
/// before that. A process that started later took the pid of one that
/// ended without removing its file.
const CLAUDE_START_SLACK: Duration = Duration::from_secs(1);

/// The Claude sessions running in processes that are not under `us`, our
/// own pid, from `~/.claude/sessions/<pid>.json`. With `only`, just that
/// session.
pub fn claude_elsewhere(procs: &Snapshot, us: u32, only: Option<&str>) -> Vec<RunningElsewhere> {
    let Some(dir) = claude_dir().map(|d| d.join("sessions")) else {
        return Vec::new();
    };
    let entries: Vec<_> = registry_entries(&dir)
        .into_iter()
        .filter(|e| only.is_none_or(|id| e.id == id))
        .collect();
    // Most of the time no session runs elsewhere, and the processes are
    // not read at all.
    if entries.is_empty() {
        return Vec::new();
    }
    claude_elsewhere_from(entries, procs.table(), us)
}

/// One `~/.claude/sessions/<pid>.json`.
struct RegistryEntry {
    pid: u32,
    id: String,
    busy: bool,
    started: Option<SystemTime>,
}

fn registry_entries(dir: &Path) -> Vec<RegistryEntry> {
    let Ok(files) = fs::read_dir(dir) else {
        return Vec::new();
    };
    files
        .flatten()
        .map(|f| f.path())
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .filter_map(|p| parse_registry_entry(&fs::read_to_string(p).ok()?))
        .collect()
}

fn parse_registry_entry(text: &str) -> Option<RegistryEntry> {
    let v: Value = serde_json::from_str(text).ok()?;
    Some(RegistryEntry {
        pid: u32::try_from(v["pid"].as_u64()?).ok()?,
        id: v["sessionId"]
            .as_str()
            .filter(|s| !s.is_empty())?
            .to_string(),
        busy: v["status"] == "busy",
        started: v["startedAt"]
            .as_u64()
            .map(|ms| SystemTime::UNIX_EPOCH + Duration::from_millis(ms)),
    })
}

fn claude_elsewhere_from(
    entries: Vec<RegistryEntry>,
    procs: &HashMap<u32, Process>,
    us: u32,
) -> Vec<RunningElsewhere> {
    let mut out: Vec<_> = entries
        .into_iter()
        .filter_map(|e| {
            let proc = procs.get(&e.pid)?;
            if let (Some(written), Some(started)) = (e.started, proc.started)
                && started > written + CLAUDE_START_SLACK
            {
                return None;
            }
            let lineage = lineage(procs, e.pid);
            if lineage.iter().any(|p| p.pid == us) {
                return None;
            }
            // The process launchd started, unless that is Claude itself.
            let app = lineage
                .last()
                .filter(|top| top.pid != e.pid && top.ppid == 1)
                .map(|top| app_name(top.argv0()));
            Some(RunningElsewhere {
                id: e.id,
                busy: e.busy,
                app,
            })
        })
        .collect();
    out.sort_by(|a, b| a.id.cmp(&b.id));
    out
}

/// The process, its parent, and so on up to the one launchd started.
fn lineage(procs: &HashMap<u32, Process>, pid: u32) -> Vec<&Process> {
    let mut out: Vec<&Process> = Vec::new();
    let mut next = procs.get(&pid);
    while let Some(p) = next {
        // A cycle can't happen, but a pid can be reused between reads.
        if out.iter().any(|seen| seen.pid == p.pid) {
            break;
        }
        out.push(p);
        if p.ppid <= 1 {
            break;
        }
        next = procs.get(&p.ppid);
    }
    out
}

/// `Ghostty` for `/Applications/Ghostty.app/Contents/MacOS/ghostty`, and
/// the program's name outside an app, e.g. `tmux`.
fn app_name(argv0: &str) -> String {
    argv0
        .split('/')
        .find_map(|part| part.strip_suffix(".app"))
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| basename(argv0))
        .to_string()
}

// ---------- left running ----------

/// A program of the user's that was started in the background and went on
/// when what started it ended, so launchd adopted it, e.g. `nohup npm run
/// dev &` or a test server an agent did not stop. Apps, and programs in the
/// root or home folder, are not counted: those are most of what launchd
/// runs. Neither is Codex's background server, which Codex runs on purpose.
/// What it started counts as part of it.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Leftover {
    pub pid: u32,
    /// When it started, so that a later process with the same pid is not
    /// taken for it.
    pub started: SystemTime,
    /// E.g. `node next dev`.
    pub command: String,
    /// Its working directory.
    pub cwd: PathBuf,
    /// Its memory and that of what it started, in bytes, as Activity
    /// Monitor's Memory column counts it.
    pub memory: u64,
    /// It and the processes it started.
    pub processes: u32,
}

/// What was read about each of the user's processes adopted by launchd:
/// their arguments do not change, so each process is read once.
#[derive(Default)]
pub struct ArgsCache {
    by_pid: HashMap<u32, (SystemTime, Option<Args>)>,
}

/// The programs left running, biggest first.
pub fn leftovers(procs: &Snapshot, cache: &mut ArgsCache) -> Vec<Leftover> {
    let table = procs.table();
    cache
        .by_pid
        .retain(|pid, (started, _)| table.get(pid).and_then(|p| p.started) == Some(*started));
    for (&pid, p) in table {
        // Only the user's own processes can be read.
        if let (1, Some(started)) = (p.ppid, p.started) {
            cache
                .by_pid
                .entry(pid)
                .or_insert_with(|| (started, read_args(pid)));
        }
    }
    let args = |pid: u32| cache.by_pid.get(&pid).and_then(|(_, a)| a.clone());
    let home = dirs::home_dir().unwrap_or_default();
    leftovers_from(table, &args, &working_dir, &memory, &home)
}

fn leftovers_from(
    table: &HashMap<u32, Process>,
    args: &dyn Fn(u32) -> Option<Args>,
    cwd: &dyn Fn(u32) -> Option<PathBuf>,
    memory: &dyn Fn(u32) -> u64,
    home: &Path,
) -> Vec<Leftover> {
    let children = children(table);
    let mut out: Vec<Leftover> = table
        .iter()
        .filter(|(_, p)| p.ppid == 1)
        .filter_map(|(&pid, p)| {
            let started = p.started?;
            let args = args(pid)?;
            if args.argv0.contains(".app/") || is_codex_daemon(&args) {
                return None;
            }
            let cwd = cwd(pid).filter(|d| d.parent().is_some() && d != home)?;
            let group = descendants(&children, pid);
            Some(Leftover {
                pid,
                started,
                command: args.command,
                cwd,
                memory: group.iter().map(|&pid| memory(pid)).sum(),
                processes: u32::try_from(group.len()).unwrap_or(u32::MAX),
            })
        })
        .collect();
    out.sort_by(|a, b| b.memory.cmp(&a.memory).then(a.pid.cmp(&b.pid)));
    out
}

/// `codex app-server …`: the shared server every `codex` connects to, and
/// `codex app-server daemon pid-update-loop`, which keeps it up to date.
/// The first `codex` starts both in its own folder and leaves them running.
fn is_codex_daemon(args: &Args) -> bool {
    basename(&args.argv0) == "codex" && args.arg1.as_deref() == Some("app-server")
}

fn children(table: &HashMap<u32, Process>) -> HashMap<u32, Vec<u32>> {
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for (&pid, p) in table {
        if p.ppid != pid {
            children.entry(p.ppid).or_default().push(pid);
        }
    }
    children
}

/// `pid` and everything under it.
fn descendants(children: &HashMap<u32, Vec<u32>>, pid: u32) -> Vec<u32> {
    let mut out = vec![pid];
    let mut i = 0;
    while i < out.len() {
        for &child in children.get(&out[i]).into_iter().flatten() {
            if !out.contains(&child) {
                out.push(child);
            }
        }
        i += 1;
    }
    out
}

/// A process's memory, as Activity Monitor counts it.
#[cfg(target_os = "macos")]
fn memory(pid: u32) -> u64 {
    let Ok(pid) = libc::c_int::try_from(pid) else {
        return 0;
    };
    let mut info = std::mem::MaybeUninit::<libc::rusage_info_v2>::zeroed();
    // SAFETY: RUSAGE_INFO_V2 fills a rusage_info_v2.
    let ok =
        unsafe { libc::proc_pid_rusage(pid, libc::RUSAGE_INFO_V2, info.as_mut_ptr().cast()) } == 0;
    // SAFETY: plain data, zeroed and then filled by the kernel.
    if ok {
        unsafe { info.assume_init() }.ri_phys_footprint
    } else {
        0
    }
}

#[cfg(not(target_os = "macos"))]
fn memory(_pid: u32) -> u64 {
    0
}

/// Stops each of `leftovers` and what it started: SIGTERM, then SIGKILL
/// for what still runs 3 seconds later. A process that is not the one that
/// was found, because it ended and its pid was taken again, is left alone.
/// Returns how many processes still run.
pub fn stop(leftovers: &[Leftover]) -> usize {
    let table = process_table();
    let children = children(&table);
    let mut group: Vec<(u32, SystemTime)> = Vec::new();
    for l in leftovers {
        if !table
            .get(&l.pid)
            .is_some_and(|p| same_start(p.started, l.started))
        {
            continue;
        }
        for pid in descendants(&children, l.pid) {
            if let Some(started) = table.get(&pid).and_then(|p| p.started)
                && !group.iter().any(|(p, _)| *p == pid)
            {
                group.push((pid, started));
            }
        }
    }
    let running = |group: &[(u32, SystemTime)]| -> Vec<(u32, SystemTime)> {
        group
            .iter()
            .copied()
            .filter(|&(pid, started)| is_running(pid, started))
            .collect()
    };
    let signal = |group: &[(u32, SystemTime)], sig| {
        for &(pid, _) in group {
            if let Ok(pid) = libc::pid_t::try_from(pid) {
                // SAFETY: kill only sends a signal.
                unsafe { libc::kill(pid, sig) };
            }
        }
    };
    signal(&group, libc::SIGTERM);
    for (signal_next, wait) in [(Some(libc::SIGKILL), 30), (None, 10)] {
        for _ in 0..wait {
            group = running(&group);
            if group.is_empty() {
                return 0;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        if let Some(sig) = signal_next {
            signal(&group, sig);
        }
    }
    running(&group).len()
}

/// Two reads of a start time can differ by rounding once it went through
/// Swift's `Date`.
fn same_start(a: Option<SystemTime>, b: SystemTime) -> bool {
    a.is_some_and(|a| {
        a.duration_since(b)
            .or_else(|_| b.duration_since(a))
            .is_ok_and(|d| d < Duration::from_millis(1))
    })
}

/// True while the process `pid` that started at `started` runs, and is not
/// a zombie waiting for its parent.
#[cfg(target_os = "macos")]
fn is_running(pid: u32, started: SystemTime) -> bool {
    let Ok(c_pid) = libc::c_int::try_from(pid) else {
        return false;
    };
    // SAFETY: PROC_PIDTBSDINFO fills a proc_bsdinfo.
    let Some(info) = (unsafe { pid_info::<libc::proc_bsdinfo>(c_pid, libc::PROC_PIDTBSDINFO) })
    else {
        return false;
    };
    let start = SystemTime::UNIX_EPOCH
        + Duration::from_secs(info.pbi_start_tvsec)
        + Duration::from_micros(info.pbi_start_tvusec);
    info.pbi_status != libc::SZOMB && same_start(Some(start), started)
}

#[cfg(not(target_os = "macos"))]
fn is_running(pid: u32, _started: SystemTime) -> bool {
    std::path::Path::new(&format!("/proc/{pid}")).exists()
}

/// For each of `dirs`, a program whose working directory is in it, if
/// any: `claude`, an editor, a dev server. This process is left out.
pub fn programs_in(dirs: &[PathBuf]) -> Vec<Option<String>> {
    let dirs: Vec<Vec<PathBuf>> = dirs
        .iter()
        .map(|d| {
            let mut both = vec![d.clone()];
            // Process folders come back with symlinks resolved.
            both.extend(d.canonicalize().ok().filter(|r| r != d));
            both
        })
        .collect();
    let mut found = vec![None; dirs.len()];
    let us = std::process::id();
    for (&pid, p) in &process_table() {
        // Our own children are git, run for the check itself, and the
        // `login` of each terminal, whose program is checked anyway.
        if pid == us || p.ppid == us || p.started.is_none() {
            continue;
        }
        let Some(cwd) = working_dir(pid) else {
            continue;
        };
        for (i, ds) in dirs.iter().enumerate() {
            if found[i].is_none() && ds.iter().any(|d| cwd.starts_with(d)) {
                found[i] = Some(basename(p.args().argv0.as_str()).to_string());
            }
        }
    }
    found
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
                started: p.started?,
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

/// The files the process has open.
#[cfg(target_os = "macos")]
fn open_files(pid: u32) -> Vec<PathBuf> {
    // <sys/proc_info.h>; libc does not have these.
    const PROC_PIDFDVNODEPATHINFO: libc::c_int = 2;
    #[repr(C)]
    struct ProcFileInfo {
        fi_openflags: u32,
        fi_status: u32,
        fi_offset: libc::off_t,
        fi_type: i32,
        fi_guardflags: u32,
    }
    #[repr(C)]
    struct VnodeFdInfoWithPath {
        pfi: ProcFileInfo,
        pvip: libc::vnode_info_path,
    }

    let Ok(pid) = libc::c_int::try_from(pid) else {
        return Vec::new();
    };
    let entry = size_of::<libc::proc_fdinfo>();
    // SAFETY: with no buffer, proc_pidinfo returns the size it needs.
    let needed =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
    let Ok(needed) = usize::try_from(needed) else {
        return Vec::new();
    };
    // Room for files opened in between.
    let mut fds = vec![
        libc::proc_fdinfo {
            proc_fd: 0,
            proc_fdtype: 0
        };
        needed / entry + 16
    ];
    // SAFETY: the buffer is `fds.len() * entry` bytes long.
    let n = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDLISTFDS,
            0,
            fds.as_mut_ptr().cast(),
            (fds.len() * entry) as libc::c_int,
        )
    };
    fds.truncate(usize::try_from(n).unwrap_or(0) / entry);
    fds.iter()
        .filter(|fd| fd.proc_fdtype == libc::PROX_FDTYPE_VNODE as u32)
        .filter_map(|fd| {
            let mut info = std::mem::MaybeUninit::<VnodeFdInfoWithPath>::zeroed();
            let size = size_of::<VnodeFdInfoWithPath>() as libc::c_int;
            // SAFETY: the buffer is `size` bytes and lives across the call.
            let n = unsafe {
                libc::proc_pidfdinfo(
                    pid,
                    fd.proc_fd,
                    PROC_PIDFDVNODEPATHINFO,
                    info.as_mut_ptr().cast(),
                    size,
                )
            };
            // SAFETY: plain data, zeroed and then filled by the kernel.
            (n == size).then(|| vnode_path(unsafe { &info.assume_init_ref().pvip }))?
        })
        .collect()
}

/// The files the process has open.
#[cfg(not(target_os = "macos"))]
fn open_files(pid: u32) -> Vec<PathBuf> {
    let proc_fd = PathBuf::from(format!("/proc/{pid}/fd"));
    if let Ok(entries) = fs::read_dir(&proc_fd) {
        return entries
            .flatten()
            .filter_map(|e| fs::read_link(e.path()).ok())
            .collect();
    }
    let Ok(res) = std::process::Command::new("lsof")
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
    // SAFETY: PROC_PIDVNODEPATHINFO fills a proc_vnodepathinfo.
    let info = unsafe {
        pid_info::<libc::proc_vnodepathinfo>(
            libc::c_int::try_from(pid).ok()?,
            libc::PROC_PIDVNODEPATHINFO,
        )
    }?;
    vnode_path(&info.pvi_cdir)
}

#[cfg(target_os = "macos")]
fn vnode_path(info: &libc::vnode_info_path) -> Option<PathBuf> {
    use std::ffi::{CStr, OsStr};
    use std::os::unix::ffi::OsStrExt;

    let path = info.vip_path.as_flattened();
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

    fn process(pid: u32, ppid: u32, pgid: u32, tpgid: Option<u32>, args: &[&str]) -> Process {
        Process {
            pid,
            ppid,
            pgid,
            tpgid,
            comm: basename(args[0]).to_string(),
            started: None,
            args: OnceCell::from(Args {
                argv0: args[0].into(),
                arg1: args.get(1).map(|a| a.to_string()),
                command: args.join(" "),
            }),
        }
    }

    #[test]
    fn finds_what_was_left_running() {
        let t0 = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut table = HashMap::new();
        let mut add = |pid, ppid, argv0: &str, own: bool| {
            let mut p = process(pid, ppid, pid, None, &[argv0]);
            p.started = own.then_some(t0);
            table.insert(pid, p);
        };
        // An app, and a terminal in it with an agent and its MCP server.
        add(
            100,
            1,
            "/Applications/Agentz.app/Contents/MacOS/agentz",
            true,
        );
        add(101, 100, "/usr/bin/login", true);
        add(102, 101, "claude", true);
        add(103, 102, "node", true);
        // What the agent started with nohup, and its worker.
        add(200, 1, "npm", true);
        add(201, 200, "node", true);
        add(202, 201, "node", true);
        // launchd's own, another user's, and one in the home folder.
        add(300, 1, "/usr/libexec/trustd", true);
        add(301, 1, "/usr/sbin/cfprefsd", false);
        add(302, 1, "/opt/homebrew/bin/gpg-agent", true);
        // Codex's background server and its updater, in the agent's folder.
        let codex = "/Users/me/.codex/packages/app-server-daemon/current/bin/codex";
        for (pid, arg) in [(400, "--listen"), (401, "daemon")] {
            let mut p = process(pid, 1, pid, None, &[codex, "app-server", arg]);
            p.started = Some(t0);
            table.insert(pid, p);
        }
        let found = leftovers_from(
            &table,
            &|pid| {
                let p = table.get(&pid)?;
                Some(Args {
                    command: if pid == 200 {
                        "npm run dev".into()
                    } else {
                        p.argv0().into()
                    },
                    ..p.args().clone()
                })
            },
            &|pid| match pid {
                100 | 300 | 301 => Some("/".into()),
                302 => Some("/Users/me".into()),
                _ => Some("/Users/me/app".into()),
            },
            &|pid| u64::from(pid),
            Path::new("/Users/me"),
        );
        assert_eq!(
            found,
            vec![Leftover {
                pid: 200,
                started: t0,
                command: "npm run dev".into(),
                cwd: "/Users/me/app".into(),
                // Also what it started.
                memory: 200 + 201 + 202,
                processes: 3,
            }]
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn stops_a_leftover_and_what_it_started() {
        // `; true` so the shell waits instead of becoming the last sleep.
        let mut sh = std::process::Command::new("/bin/sh")
            .args(["-c", "sleep 30 & sleep 30; true"])
            .spawn()
            .unwrap();
        // Until the background sleep has started.
        let mut table = process_table();
        for _ in 0..50 {
            if descendants(&children(&table), sh.id()).len() == 3 {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
            table = process_table();
        }
        let p = &table[&sh.id()];
        let leftover = Leftover {
            pid: sh.id(),
            started: p.started.unwrap(),
            command: "sh".into(),
            cwd: "/".into(),
            memory: 0,
            processes: 3,
        };
        let group = descendants(&children(&table), sh.id());
        assert_eq!(group.len(), 3);
        // A pid that was taken again is left alone.
        let other = Leftover {
            started: leftover.started - Duration::from_secs(5),
            ..leftover.clone()
        };
        assert_eq!(stop(&[other]), 0);
        assert!(is_running(sh.id(), leftover.started));
        assert_eq!(stop(std::slice::from_ref(&leftover)), 0);
        sh.wait().unwrap();
        for pid in group {
            assert!(!is_running(pid, table[&pid].started.unwrap()));
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn finds_programs_in_a_folder() {
        let dir = std::env::temp_dir().join(format!("agentz-in-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(dir.join("sub")).unwrap();
        // Not our child, like a program in one of our terminals: its shell
        // exits, and launchd adopts it.
        let out = std::process::Command::new("/bin/sh")
            .args(["-c", "(cd sub && exec sleep 30) >/dev/null 2>&1 & echo $!"])
            .current_dir(&dir)
            .output()
            .unwrap();
        let pid: libc::pid_t = String::from_utf8_lossy(&out.stdout).trim().parse().unwrap();
        let other = std::env::temp_dir().join(format!("agentz-out-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&other).unwrap();
        let mut found = vec![None, None];
        for _ in 0..50 {
            found = programs_in(&[dir.clone(), other.clone()]);
            if found[0].is_some() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        // SAFETY: kill only sends a signal.
        unsafe { libc::kill(pid, libc::SIGKILL) };
        assert_eq!(found, vec![Some("sleep".to_string()), None]);
        fs::remove_dir_all(dir).unwrap();
        fs::remove_dir_all(other).unwrap();
    }

    #[test]
    fn foreground_command_ignores_background_and_unrelated_processes() {
        let mut procs = HashMap::new();
        let mut add = |pid, ppid, pgid, tpgid, argv0: &str| {
            procs.insert(pid, process(pid, ppid, pgid, tpgid, &[argv0]));
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
    fn finds_claude_sessions_running_outside_us() {
        let t0 = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut procs = HashMap::new();
        let mut add = |pid, ppid, argv0: &str, started| {
            let mut p = process(pid, ppid, pid, None, &[argv0]);
            p.started = Some(started);
            procs.insert(pid, p);
        };
        add(
            100,
            1,
            "/Applications/Ghostty.app/Contents/MacOS/ghostty",
            t0,
        );
        add(101, 100, "/usr/bin/login", t0);
        add(102, 101, "claude", t0);
        // Us, and a Claude in one of our terminals.
        add(200, 1, "/Applications/Agentz.app/Contents/MacOS/agentz", t0);
        add(201, 200, "/usr/bin/login", t0);
        add(202, 201, "claude", t0);
        // Its parent is gone.
        add(300, 1, "claude", t0);
        // Took the pid of a Claude that ended without removing its file.
        add(400, 1, "/bin/sleep", t0 + Duration::from_secs(60));
        let entry = |pid, id: &str, busy| RegistryEntry {
            pid,
            id: id.into(),
            busy,
            started: Some(t0 + Duration::from_millis(500)),
        };
        let found = claude_elsewhere_from(
            vec![
                entry(300, "orphan", false),
                entry(102, "ghostty", true),
                entry(202, "ours", false),
                entry(400, "stale", false),
                entry(500, "gone", false),
            ],
            &procs,
            200,
        );
        assert_eq!(
            found,
            vec![
                RunningElsewhere {
                    id: "ghostty".into(),
                    busy: true,
                    app: Some("Ghostty".into()),
                },
                RunningElsewhere {
                    id: "orphan".into(),
                    busy: false,
                    app: None,
                },
            ]
        );
    }

    #[test]
    fn reads_claude_session_files() {
        let dir = std::env::temp_dir().join(format!("agentz-registry-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&dir).unwrap();
        fs::write(
            dir.join("33503.json"),
            r#"{"pid":33503,"sessionId":"a21d","startedAt":1791355232094,"status":"busy","kind":"interactive"}"#,
        )
        .unwrap();
        fs::write(
            dir.join("33503.71776e8b.key"),
            r#"{"pid":1,"sessionId":"key"}"#,
        )
        .unwrap();
        fs::write(
            dir.join("40.json"),
            r#"{"pid":40,"sessionId":"","status":"idle"}"#,
        )
        .unwrap();
        fs::write(dir.join("41.json"), "{\"pid\":41,").unwrap();
        let found = registry_entries(&dir);
        assert_eq!(found.len(), 1);
        let e = &found[0];
        assert_eq!((e.pid, e.id.as_str(), e.busy), (33503, "a21d", true));
        assert_eq!(
            e.started,
            Some(SystemTime::UNIX_EPOCH + Duration::from_millis(1_791_355_232_094))
        );
        let idle = parse_registry_entry(r#"{"pid":7,"sessionId":"x","status":"idle"}"#).unwrap();
        assert!(!idle.busy);
        assert_eq!(idle.started, None);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn names_apps() {
        assert_eq!(
            app_name("/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            "Ghostty"
        );
        assert_eq!(
            app_name("/Applications/Visual Studio Code.app/Contents/MacOS/Electron"),
            "Visual Studio Code"
        );
        assert_eq!(app_name("/opt/homebrew/bin/tmux"), "tmux");
        assert_eq!(app_name("tmux"), "tmux");
    }

    #[test]
    fn parses_etime() {
        assert_eq!(parse_etime("05:02"), Some(302));
        assert_eq!(parse_etime("01:07:20"), Some(4040));
        assert_eq!(parse_etime("2-00:00:01"), Some(172_801));
        assert_eq!(parse_etime("x"), None);
    }

    #[test]
    fn parses_procargs() {
        let mut buf = 2i32.to_ne_bytes().to_vec();
        buf.extend(b"/usr/bin/codex\0\0\0codex\0exec now\0HOME=/x\0");
        let args = parse_procargs(&buf).unwrap();
        assert_eq!(args.argv0, "codex");
        assert_eq!(args.arg1.as_deref(), Some("exec now"));
        // The environment is not an argument.
        let mut buf = 1i32.to_ne_bytes().to_vec();
        buf.extend(b"/bin/sleep\0sleep\0HOME=/x\0");
        assert_eq!(parse_procargs(&buf).unwrap().arg1, None);
        let mut buf = 3i32.to_ne_bytes().to_vec();
        buf.extend(
            b"/usr/bin/node\0\0\0\0/usr/bin/node\0/x/node_modules/.bin/next\0dev\0HOME=/x\0",
        );
        assert_eq!(parse_procargs(&buf).unwrap().command, "node next dev");
        assert_eq!(command_line(&["x".repeat(100)]).chars().count(), 81);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn reads_command_lines_and_memory() {
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        assert_eq!(read_args(child.id()).unwrap().command, "sleep 30");
        assert!(memory(child.id()) > 0);
        child.kill().unwrap();
        child.wait().unwrap();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn reads_processes_from_the_kernel() {
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let pid = child.id();
        let procs = process_table();
        let found = &procs[&pid];
        let me = &procs[&std::process::id()];
        assert_eq!(found.ppid, std::process::id());
        assert_eq!(found.comm, "sleep");
        assert_eq!(found.argv0(), "/bin/sleep");
        assert_eq!(found.arg1(), Some("30"));
        let started = found.started.unwrap();
        assert!(started >= me.started.unwrap());
        assert!(started <= SystemTime::now());
        // Other users' processes are listed too, e.g. launchd.
        assert_eq!(procs[&1].ppid, 0);
        assert!(open_files(std::process::id()).iter().any(|p| p.exists()));
        child.kill().unwrap();
        child.wait().unwrap();
    }

    #[test]
    fn exec_processes_claim_threads_but_are_not_shell_sessions() {
        let process = process(3, 1, 2, Some(2), &["/usr/local/bin/codex", "exec"]);
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
