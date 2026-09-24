//! Discovers Claude Code and Codex sessions from their on-disk transcripts.
//!
//! Claude Code: `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`
//! Codex:       `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<session-id>.jsonl`
//!              plus `~/.codex/session_index.jsonl` for thread names.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde_json::Value;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Agent {
    Claude,
    Codex,
    /// A plain shell started from agentz. It has no transcript.
    Shell,
}

impl Agent {
    pub fn name(self) -> &'static str {
        match self {
            Agent::Claude => "claude",
            Agent::Codex => "codex",
            Agent::Shell => "shell",
        }
    }
}

pub type SessionKey = (Agent, String);

#[derive(Clone, Debug)]
pub struct Session {
    pub agent: Agent,
    pub id: String,
    pub title: String,
    pub cwd: PathBuf,
    pub created: SystemTime,
    pub updated: SystemTime,
}

impl Session {
    pub fn key(&self) -> SessionKey {
        (self.agent, self.id.clone())
    }
}

/// What we learned from one transcript file. Claude files are parsed
/// incrementally: `offset` is where the next read starts.
#[derive(Default, Clone)]
struct Parsed {
    offset: u64,
    id: String,
    cwd: Option<String>,
    first_prompt: Option<String>,
    ai_title: Option<String>,
    custom_title: Option<String>,
    summary: Option<String>,
    skip: bool,
}

struct CacheEntry {
    len: u64,
    mtime: SystemTime,
    created: SystemTime,
    parsed: Parsed,
}

#[derive(Default)]
pub struct Scanner {
    cache: HashMap<PathBuf, CacheEntry>,
}

impl Scanner {
    pub fn scan(&mut self) -> Vec<Session> {
        let mut out = Vec::new();
        let mut seen = Vec::new();

        if let Some(dir) = claude_projects_dir() {
            for path in claude_files(&dir) {
                if let Some(s) = self.visit(&path, Agent::Claude) {
                    out.push(s);
                }
                seen.push(path);
            }
        }

        if let Some(home) = codex_home() {
            let names = codex_thread_names(&home.join("session_index.jsonl"));
            let mut files = Vec::new();
            walk_jsonl(&home.join("sessions"), &mut files);
            for path in files {
                if let Some(mut s) = self.visit(&path, Agent::Codex) {
                    if let Some(name) = names.get(&s.id) {
                        s.title = name.clone();
                    }
                    out.push(s);
                }
                seen.push(path);
            }
        }

        let seen: std::collections::HashSet<_> = seen.into_iter().collect();
        self.cache.retain(|p, _| seen.contains(p));

        out.sort_by_key(|s| std::cmp::Reverse(s.updated));
        out
    }

    fn visit(&mut self, path: &Path, agent: Agent) -> Option<Session> {
        let meta = fs::metadata(path).ok()?;
        let len = meta.len();
        let mtime = meta.modified().ok()?;
        let created = meta.created().unwrap_or(mtime);

        let entry = match self.cache.get_mut(path) {
            Some(e) if e.len == len && e.mtime == mtime => e,
            Some(e) => {
                // Claude transcripts are append-only; continue from where we
                // stopped. If the file shrank, start over.
                let prev = if len >= e.len {
                    e.parsed.clone()
                } else {
                    Parsed::default()
                };
                e.parsed = parse(path, agent, prev);
                e.len = len;
                e.mtime = mtime;
                e
            }
            None => {
                let parsed = parse(path, agent, Parsed::default());
                self.cache.insert(
                    path.to_path_buf(),
                    CacheEntry {
                        len,
                        mtime,
                        created,
                        parsed,
                    },
                );
                self.cache.get_mut(path).unwrap()
            }
        };

        let p = &entry.parsed;
        if p.skip || p.id.is_empty() {
            return None;
        }
        let title = p
            .custom_title
            .clone()
            .or_else(|| p.ai_title.clone())
            .or_else(|| p.summary.clone())
            .or_else(|| p.first_prompt.clone())?;
        Some(Session {
            agent,
            id: p.id.clone(),
            title,
            cwd: PathBuf::from(p.cwd.clone()?),
            created: entry.created,
            updated: entry.mtime,
        })
    }
}

fn parse(path: &Path, agent: Agent, prev: Parsed) -> Parsed {
    match agent {
        Agent::Claude => parse_claude(path, prev),
        Agent::Codex => {
            // Codex metadata sits at the top of the file and never changes.
            if prev.offset > 0 {
                prev
            } else {
                parse_codex(path)
            }
        }
        Agent::Shell => prev,
    }
}

fn parse_claude(path: &Path, mut p: Parsed) -> Parsed {
    if p.id.is_empty() {
        p.id = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or_default()
            .to_string();
    }
    let Ok(mut file) = File::open(path) else {
        return p;
    };
    if file.seek(SeekFrom::Start(p.offset)).is_err() {
        return p;
    }
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    loop {
        line.clear();
        let n = match reader.read_line(&mut line) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        // A line without a newline is still being written; read it next time.
        if !line.ends_with('\n') {
            break;
        }
        p.offset += n as u64;

        let wanted = line.contains("\"custom-title\"")
            || line.contains("\"ai-title\"")
            || line.contains("\"type\":\"summary\"")
            || (p.cwd.is_none() && line.contains("\"cwd\""))
            || (p.first_prompt.is_none() && line.contains("\"type\":\"user\""));
        if !wanted {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        match v["type"].as_str() {
            Some("custom-title") => p.custom_title = str_field(&v, "customTitle"),
            Some("ai-title") => p.ai_title = str_field(&v, "aiTitle"),
            Some("summary") => p.summary = str_field(&v, "summary"),
            Some("user")
                if p.first_prompt.is_none()
                    && v["isMeta"].as_bool() != Some(true)
                    && v["isSidechain"].as_bool() != Some(true) =>
            {
                p.first_prompt = message_text(&v["message"]["content"]).and_then(clean_prompt);
            }
            _ => {}
        }
        if p.cwd.is_none() {
            p.cwd = str_field(&v, "cwd");
        }
    }
    p
}

fn parse_codex(path: &Path) -> Parsed {
    let mut p = Parsed::default();
    let Ok(file) = File::open(path) else { return p };
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    for i in 0..400 {
        line.clear();
        let n = match reader.read_line(&mut line) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        p.offset += n as u64;
        let Ok(v) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let payload = &v["payload"];
        if i == 0 {
            if v["type"] != "session_meta" {
                p.skip = true;
                return p;
            }
            p.id = str_field(payload, "id").unwrap_or_default();
            p.cwd = str_field(payload, "cwd");
            // Sub-agent threads (e.g. reviews) have an object as `source`.
            if !payload["source"].is_string() || payload["thread_source"] == "subagent" {
                p.skip = true;
                return p;
            }
            continue;
        }
        let is_user_msg = v["type"] == "response_item"
            && payload["type"] == "message"
            && payload["role"] == "user";
        if is_user_msg && let Some(text) = message_text(&payload["content"]).and_then(clean_prompt)
        {
            p.first_prompt = Some(text);
            break;
        }
    }
    p
}

fn str_field(v: &Value, key: &str) -> Option<String> {
    v[key]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// Returns the first text part of a message `content`, which is either a
/// plain string or an array of `{type, text}` blocks.
fn message_text(content: &Value) -> Option<String> {
    if let Some(s) = content.as_str() {
        return Some(s.to_string());
    }
    content.as_array()?.iter().find_map(|block| {
        let t = block["type"].as_str()?;
        if t == "text" || t == "input_text" {
            block["text"].as_str().map(str::to_string)
        } else {
            None
        }
    })
}

/// Drops injected context (AGENTS.md, environment, slash-command wrappers)
/// and keeps the first line of what the user actually typed.
fn clean_prompt(text: String) -> Option<String> {
    let t = text.trim();
    if t.is_empty()
        || t.starts_with('<')
        || t.starts_with("# AGENTS.md")
        || t.starts_with("Caveat:")
    {
        return None;
    }
    let first = t.lines().find(|l| !l.trim().is_empty())?.trim();
    Some(first.chars().take(200).collect())
}

/// `$CLAUDE_CONFIG_DIR` or `~/.claude`.
pub fn claude_dir() -> Option<PathBuf> {
    std::env::var_os("CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .or_else(|| dirs::home_dir().map(|h| h.join(".claude")))
}

fn claude_projects_dir() -> Option<PathBuf> {
    Some(claude_dir()?.join("projects"))
}

fn codex_home() -> Option<PathBuf> {
    std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .or_else(|| dirs::home_dir().map(|h| h.join(".codex")))
}

/// Top-level `*.jsonl` files in each project dir. Sub-agent transcripts live
/// in nested folders and are skipped on purpose.
fn claude_files(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(projects) = fs::read_dir(dir) else {
        return out;
    };
    for project in projects.flatten() {
        let Ok(files) = fs::read_dir(project.path()) else {
            continue;
        };
        for f in files.flatten() {
            let path = f.path();
            if path.extension().is_some_and(|e| e == "jsonl") && path.is_file() {
                out.push(path);
            }
        }
    }
    out
}

fn walk_jsonl(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let path = e.path();
        let Ok(ft) = e.file_type() else { continue };
        if ft.is_dir() {
            walk_jsonl(&path, out);
        } else if path.extension().is_some_and(|e| e == "jsonl") {
            out.push(path);
        }
    }
}

/// Latest `thread_name` per thread id. Later lines win (renames append).
fn codex_thread_names(path: &Path) -> HashMap<String, String> {
    let mut names = HashMap::new();
    let Ok(file) = File::open(path) else {
        return names;
    };
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Ok(v) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if let (Some(id), Some(name)) = (v["id"].as_str(), v["thread_name"].as_str())
            && !name.is_empty()
        {
            names.insert(id.to_string(), name.to_string());
        }
    }
    names
}
