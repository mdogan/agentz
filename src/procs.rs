//! Finds agents the user started by hand inside one of our shells, and the
//! session each one is using.
//!
//! Claude Code: writes `~/.claude/sessions/<pid>.json` with its `sessionId`.
//! Codex:       keeps its `rollout-<ts>-<session-id>.jsonl` file open.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;

use crate::sessions::{Agent, SessionKey, claude_dir};

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
}

/// For each shell pid, the session of the agent running under it, if any.
#[cfg(test)]
pub fn agents_in_shells(shells: &[u32]) -> Vec<(u32, SessionKey)> {
    shell_processes(shells)
        .into_iter()
        .filter_map(|s| s.agent.map(|agent| (s.pid, agent)))
        .collect()
}

/// Finds the foreground command and any linked agent for each shell.
pub fn shell_processes(shells: &[u32]) -> Vec<ShellProcess> {
    if shells.is_empty() {
        return Vec::new();
    }
    let procs = process_table();
    shell_processes_from_table(
        shells,
        &procs,
        claude_dir().map(|d| d.join("sessions")).as_deref(),
    )
}

fn shell_processes_from_table(
    shells: &[u32],
    procs: &HashMap<u32, Process>,
    claude_sessions: Option<&Path>,
) -> Vec<ShellProcess> {
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
                    (basename(&proc.argv0) == "codex")
                        .then(|| codex_session(pid))
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

/// pid -> parent, process group, terminal foreground group, argv[0].
fn process_table() -> HashMap<u32, Process> {
    let mut out = HashMap::new();
    let Ok(res) = Command::new("ps")
        .args(["-eo", "pid=,ppid=,pgid=,tpgid=,args="])
        .output()
    else {
        return out;
    };
    for line in String::from_utf8_lossy(&res.stdout).lines() {
        let mut parts = line.split_whitespace();
        let (Some(pid), Some(ppid), Some(pgid), Some(tpgid), Some(argv0)) = (
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
                },
            );
        }
    }
    out
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
                },
            );
        };
        add(10, 1, 10, Some(30), "/bin/fish");
        add(20, 10, 20, Some(30), "/bin/long-background-job");
        add(30, 10, 30, Some(30), "/usr/bin/sleep");
        add(31, 30, 30, Some(30), "/usr/bin/cat");
        add(40, 1, 30, Some(30), "/usr/bin/unrelated");

        let found = shell_processes_from_table(&[10], &procs, None);
        assert_eq!(found[0].foreground, Some((30, "sleep".into())));

        procs.get_mut(&10).unwrap().tpgid = Some(10);
        let found = shell_processes_from_table(&[10], &procs, None);
        assert_eq!(found[0].foreground, None);
    }
}
