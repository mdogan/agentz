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

/// For each shell pid, the session of the agent running under it, if any.
pub fn agents_in_shells(shells: &[u32]) -> Vec<(u32, SessionKey)> {
    if shells.is_empty() {
        return Vec::new();
    }
    let procs = process_table();
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for (&pid, (ppid, _)) in &procs {
        children.entry(*ppid).or_default().push(pid);
    }
    let claude_sessions = claude_dir().map(|d| d.join("sessions"));

    let mut out = Vec::new();
    for &shell in shells {
        // Breadth-first, so the agent the user started wins over anything
        // that agent started itself.
        let mut queue: Vec<u32> = children.get(&shell).cloned().unwrap_or_default();
        let mut i = 0;
        while i < queue.len() {
            let pid = queue[i];
            i += 1;
            let found = claude_sessions
                .as_deref()
                .and_then(|dir| claude_session(dir, pid))
                .map(|id| (Agent::Claude, id))
                .or_else(|| {
                    let argv0 = procs.get(&pid).map(|(_, a)| a.as_str()).unwrap_or("");
                    (basename(argv0) == "codex")
                        .then(|| codex_session(pid))
                        .flatten()
                        .map(|id| (Agent::Codex, id))
                });
            if let Some(key) = found {
                out.push((shell, key));
                break;
            }
            queue.extend(children.get(&pid).into_iter().flatten());
        }
    }
    out
}

/// pid -> (parent pid, argv[0]) for every process.
fn process_table() -> HashMap<u32, (u32, String)> {
    let mut out = HashMap::new();
    let Ok(res) = Command::new("ps")
        .args(["-eo", "pid=,ppid=,args="])
        .output()
    else {
        return out;
    };
    for line in String::from_utf8_lossy(&res.stdout).lines() {
        let mut parts = line.split_whitespace();
        let (Some(pid), Some(ppid)) = (parts.next(), parts.next()) else {
            continue;
        };
        if let (Ok(pid), Ok(ppid)) = (pid.parse(), ppid.parse()) {
            out.insert(pid, (ppid, parts.next().unwrap_or("").to_string()));
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

fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}
