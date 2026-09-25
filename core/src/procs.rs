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

struct Args {
    argv0: String,
    /// The first argument, e.g. `app-server` for Codex's daemon.
    arg1: Option<String>,
}

impl Process {
    fn args(&self) -> &Args {
        self.args.get_or_init(|| {
            read_args(self.pid).unwrap_or_else(|| Args {
                argv0: self.comm.clone(),
                arg1: None,
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
/// boundary, then the arguments, each ending in a NUL.
fn parse_procargs(buf: &[u8]) -> Option<Args> {
    let argc = i32::from_ne_bytes(buf.get(..4)?.try_into().ok()?);
    let rest = &buf[4..];
    let rest = &rest[rest.iter().position(|&b| b == 0)?..];
    let rest = &rest[rest.iter().position(|&b| b != 0)?..];
    let mut args = rest
        .split(|&b| b == 0)
        .take(usize::try_from(argc).ok()?)
        .map(|a| String::from_utf8_lossy(a).into_owned());
    Some(Args {
        argv0: args.next()?,
        arg1: args.next(),
    })
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
            let args = Args {
                argv0: argv0.to_string(),
                arg1: parts.next().map(str::to_string),
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
            }),
        }
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
