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

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::action::{self, Action};

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum Agent {
    Claude,
    Codex,
    /// A plain shell started from agentz. It has no transcript.
    Shell,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Record)]
pub struct SessionKey {
    pub agent: Agent,
    pub id: String,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Session {
    pub agent: Agent,
    pub id: String,
    pub title: String,
    pub cwd: PathBuf,
    /// Codex's creator (`codex-tui`, `codex_exec`, ...).
    pub originator: Option<String>,
    pub created: SystemTime,
    pub updated: SystemTime,
    /// Whether `cwd` is in the project of the folder the scan was for.
    pub in_project: bool,
    /// The git branch it last worked on: Claude's branch at its last
    /// message, Codex's when it started.
    pub branch: Option<String>,
    /// The pull request Claude last opened or looked at.
    pub pr: Option<PullRequest>,
    /// The agent stopped at its plan's rate limit, and the session did not
    /// go on since.
    pub limit: Option<LimitStop>,
    /// When the last turn started: the user's last prompt to Claude, the
    /// start of Codex's last task.
    pub turn_started: Option<SystemTime>,
    /// The last tool the agent called in that turn.
    pub action: Option<Action>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct PullRequest {
    pub number: u64,
    pub url: String,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct LimitStop {
    /// What the agent said, with when the limit resets, e.g. `You've hit
    /// your session limit · resets 6:50pm (Europe/Istanbul)`.
    pub message: String,
    /// When it stopped.
    pub at: SystemTime,
}

/// What we learned from one transcript file. Claude files are parsed
/// incrementally: `offset` is where the next read starts.
#[derive(Default, Clone)]
struct Parsed {
    offset: u64,
    id: String,
    cwd: Option<String>,
    originator: Option<String>,
    first_prompt: Option<String>,
    ai_title: Option<String>,
    custom_title: Option<String>,
    summary: Option<String>,
    branch: Option<String>,
    pr: Option<PullRequest>,
    /// The last rate limit stop, and when it was, if the transcript says.
    limit: Option<(String, Option<SystemTime>)>,
    turn_started: Option<SystemTime>,
    action: Option<Action>,
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
    /// Codex rollout files from the last scan, newest first.
    codex_files: Vec<PathBuf>,
    thread_names: ThreadNames,
}

/// Codex's `session_index.jsonl`, read again only when it changes.
#[derive(Default)]
struct ThreadNames {
    /// Length and modification time when it was read.
    stamp: Option<(u64, SystemTime)>,
    names: HashMap<String, String>,
}

impl ThreadNames {
    fn read(&mut self, path: &Path) -> &HashMap<String, String> {
        let stamp = fs::metadata(path)
            .ok()
            .and_then(|m| Some((m.len(), m.modified().ok()?)));
        if stamp != self.stamp {
            self.stamp = stamp;
            self.names = codex_thread_names(path);
        }
        &self.names
    }
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
            // Taken out while `visit` borrows the scanner.
            let mut thread_names = std::mem::take(&mut self.thread_names);
            let names = thread_names.read(&home.join("session_index.jsonl"));
            let mut files = Vec::new();
            walk_jsonl(&home.join("sessions"), &mut files);
            let mut by_mtime = Vec::new();
            for path in files {
                if let Some(mut s) = self.visit(&path, Agent::Codex) {
                    if let Some(name) = names.get(&s.id) {
                        s.title = name.clone();
                    }
                    out.push(s);
                }
                if let Some(e) = self.cache.get(&path) {
                    by_mtime.push((e.mtime, path.clone()));
                }
                seen.push(path);
            }
            by_mtime.sort_by_key(|(mtime, _)| std::cmp::Reverse(*mtime));
            self.codex_files = by_mtime.into_iter().map(|(_, p)| p).collect();
            self.thread_names = thread_names;
        }

        let seen: std::collections::HashSet<_> = seen.into_iter().collect();
        self.cache.retain(|p, _| seen.contains(p));

        out.sort_by_key(|s| std::cmp::Reverse(s.updated));
        out
    }

    /// Codex rollout files from the last scan, newest first.
    pub fn codex_files(&self) -> &[PathBuf] {
        &self.codex_files
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
                e.parsed = parse(path, agent, prev, true);
                e.len = len;
                e.mtime = mtime;
                e
            }
            None => {
                let recent = SystemTime::now()
                    .duration_since(mtime)
                    .is_ok_and(|age| age < RECENT);
                let parsed = parse(path, agent, Parsed::default(), recent);
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
            originator: p.originator.clone(),
            created: entry.created,
            updated: entry.mtime,
            in_project: false,
            branch: p.branch.clone(),
            pr: p.pr.clone(),
            limit: p.limit.clone().map(|(message, at)| LimitStop {
                message,
                at: at.unwrap_or(entry.mtime),
            }),
            turn_started: p.turn_started,
            action: p.action.clone(),
        })
    }
}

/// Codex rollouts can be long, and only the end of one tells whether it
/// stopped at the rate limit. At the first scan only the files changed this
/// recently are read to the end; the others are read on from where the
/// first prompt was when they change.
const RECENT: std::time::Duration = std::time::Duration::from_secs(2 * 86_400);

/// `whole`: read a Codex rollout to its end, not only to its first prompt.
fn parse(path: &Path, agent: Agent, prev: Parsed, whole: bool) -> Parsed {
    match agent {
        Agent::Claude => parse_claude(path, prev),
        Agent::Codex => {
            if prev.skip {
                return prev;
            }
            // A scan can see the metadata before Codex writes the first
            // prompt. Re-read the file until we have a title.
            let p = if prev.first_prompt.is_some() {
                prev
            } else {
                parse_codex(path)
            };
            if whole && !p.skip && p.first_prompt.is_some() {
                parse_codex_tail(path, p)
            } else {
                p
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
    // Claude calls tools often, and only the last call matters, so only
    // that one is parsed, after the loop.
    let mut last_call = String::new();
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

        if line.contains("\"type\":\"tool_use\"") && line.contains("\"type\":\"assistant\"") {
            last_call.clone_from(&line);
        } else if line.contains("\"type\":\"user\"")
            // Not a tool's result, which most of them are.
            && !line.contains("\"tool_use_id\"")
            && let Ok(v) = serde_json::from_str::<Value>(&line)
            && is_prompt(&v)
        {
            p.turn_started = v["timestamp"].as_str().and_then(parse_time);
            p.action = None;
            last_call.clear();
        }
        if let Some(branch) = git_branch(&line) {
            p.branch = branch;
        }
        // Claude writes a stop at the limit as an error message of its own.
        // Anything the user or Claude says after it means it went on.
        let limit = line.contains("\"rate_limit\"") && line.contains("\"isApiErrorMessage\":true");
        let after_limit = p.limit.is_some()
            && (line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\""));
        if (limit || after_limit)
            && let Ok(v) = serde_json::from_str::<Value>(&line)
        {
            if v["type"] == "assistant"
                && v["isApiErrorMessage"] == true
                && v["error"] == "rate_limit"
            {
                if let Some(text) = message_text(&v["message"]["content"]) {
                    p.limit = Some((text, v["timestamp"].as_str().and_then(parse_time)));
                }
            } else if goes_on(&v) {
                p.limit = None;
            }
        }
        let wanted = line.contains("\"custom-title\"")
            || line.contains("\"ai-title\"")
            || line.contains("\"type\":\"summary\"")
            || line.contains("\"pr-link\"")
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
            Some("pr-link") => {
                if let (Some(number), Some(url)) = (v["prNumber"].as_u64(), str_field(&v, "prUrl"))
                {
                    p.pr = Some(PullRequest { number, url });
                }
            }
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
    if let Ok(v) = serde_json::from_str::<Value>(&last_call)
        && v["isSidechain"] != true
        && let Some(action) = action::claude(&v)
    {
        p.action = Some(action);
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
            p.originator = str_field(payload, "originator");
            p.branch = str_field(&payload["git"], "branch");
            // Sub-agent threads (e.g. reviews) have an object as `source`.
            if !payload["source"].is_string() || payload["thread_source"] == "subagent" {
                p.skip = true;
                return p;
            }
            continue;
        }
        if v["type"] == "event_msg" && payload["type"] == "task_started" {
            p.turn_started = v["timestamp"].as_str().and_then(parse_time);
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

/// True for a Claude transcript line that says the session went on: an
/// answer from the model, or a prompt the user typed.
fn goes_on(v: &Value) -> bool {
    match v["type"].as_str() {
        Some("assistant") => v["isApiErrorMessage"] != true,
        _ => is_prompt(v),
    }
}

/// True for a Claude transcript line with a prompt the user typed. Not for
/// what Claude adds by itself, like the output of a `/usage` the user ran.
fn is_prompt(v: &Value) -> bool {
    v["type"] == "user"
        && v["isMeta"] != true
        && message_text(&v["message"]["content"])
            .and_then(clean_prompt)
            .is_some()
}

/// Codex's tool calls, as `response_item` payload types.
const CODEX_CALLS: [&str; 4] = [
    "\"function_call\"",
    "\"custom_tool_call\"",
    "\"local_shell_call\"",
    "\"web_search_call\"",
];

/// Reads the rest of a Codex rollout, from where `p` stopped, for when its
/// last turn started, its last tool call, and a stop at the rate limit: a
/// turn that ended with `usage_limit_exceeded`. A new turn means it went on.
fn parse_codex_tail(path: &Path, mut p: Parsed) -> Parsed {
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
        if !line.contains("\"usage_limit_exceeded\"")
            && !line.contains("\"task_started\"")
            && !CODEX_CALLS.iter().any(|c| line.contains(c))
        {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let payload = &v["payload"];
        if v["type"] == "response_item" {
            if let Some(action) = action::codex(payload) {
                p.action = Some(action);
            }
            continue;
        }
        if v["type"] != "event_msg" {
            continue;
        }
        if payload["type"] == "task_started" {
            p.limit = None;
            p.turn_started = v["timestamp"].as_str().and_then(parse_time);
            p.action = None;
        } else if payload["error"]["codex_error_info"] == "usage_limit_exceeded"
            && let Some(message) = str_field(&payload["error"], "message")
        {
            p.limit = Some((message, v["timestamp"].as_str().and_then(parse_time)));
        }
    }
    p
}

/// A transcript's timestamp, like `2026-09-03T09:32:07.350Z`. Only UTC
/// times, which is what Claude and Codex write.
fn parse_time(s: &str) -> Option<SystemTime> {
    let s = s.strip_suffix('Z')?;
    let (date, time) = s.split_once('T')?;
    let mut d = date.splitn(3, '-').map(|x| x.parse::<i64>().ok());
    let (y, m, day) = (d.next()??, d.next()??, d.next()??);
    let (hms, frac) = time.split_once('.').unwrap_or((time, ""));
    let mut t = hms.splitn(3, ':').map(|x| x.parse::<u64>().ok());
    let (h, min, sec) = (t.next()??, t.next()??, t.next()??);
    if !(1..=12).contains(&m) || !(1..=31).contains(&day) || h > 23 || min > 59 || sec > 60 {
        return None;
    }
    // Days since 1970-01-01, from Howard Hinnant's days_from_civil.
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = u64::try_from(era * 146_097 + doe - 719_468).ok()?;
    let nanos = if frac.is_empty() {
        0
    } else {
        let digits: String = frac.chars().take(9).collect();
        digits.parse::<u64>().ok()? * 10u64.pow(9 - digits.len() as u32)
    };
    Some(
        SystemTime::UNIX_EPOCH
            + std::time::Duration::from_secs(days * 86_400 + h * 3600 + min * 60 + sec)
            + std::time::Duration::from_nanos(nanos),
    )
}

/// The `gitBranch` of a Claude transcript line: `Some(None)` outside a
/// branch, `None` if the line has none. Claude puts it on almost every
/// message, so it is found without parsing the line.
fn git_branch(line: &str) -> Option<Option<String>> {
    const KEY: &str = "\"gitBranch\":\"";
    let rest = &line[line.find(KEY)? + KEY.len()..];
    let mut value = rest[..rest.find('"')?].to_string();
    if value.contains('\\') {
        // Escaped, which a branch name almost never is.
        value = str_field(&serde_json::from_str(line).ok()?, "gitBranch")?;
    }
    // A detached HEAD, or not a git repo.
    Some((!value.is_empty() && value != "HEAD").then_some(value))
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
    env_dir("CLAUDE_CONFIG_DIR").or_else(|| dirs::home_dir().map(|h| h.join(".claude")))
}

fn claude_projects_dir() -> Option<PathBuf> {
    Some(claude_dir()?.join("projects"))
}

/// `$CODEX_HOME` or `~/.codex`.
pub fn codex_home() -> Option<PathBuf> {
    env_dir("CODEX_HOME").or_else(|| dirs::home_dir().map(|h| h.join(".codex")))
}

/// A folder from the environment. Empty counts as not set.
fn env_dir(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn codex_session_appears_after_prompt_is_appended() {
        let path =
            std::env::temp_dir().join(format!("agentz-codex-scan-{}.jsonl", uuid::Uuid::new_v4()));
        fs::write(
            &path,
            r#"{"type":"session_meta","payload":{"id":"test-id","cwd":"/tmp","source":"vscode","originator":"codex-tui","git":{"branch":"feature/y","commit_hash":"ed57"}}}
"#,
        )
        .unwrap();

        let mut scanner = Scanner::default();
        assert!(scanner.visit(&path, Agent::Codex).is_none());

        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(
            br#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"first prompt"}]}}
"#,
        )
        .unwrap();
        drop(file);

        let session = scanner.visit(&path, Agent::Codex).unwrap();
        assert_eq!(session.id, "test-id");
        assert_eq!(session.title, "first prompt");
        assert_eq!(session.cwd, Path::new("/tmp"));
        assert_eq!(session.originator.as_deref(), Some("codex-tui"));
        assert_eq!(session.branch.as_deref(), Some("feature/y"));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn claude_transcript_is_read_incrementally() {
        let path =
            std::env::temp_dir().join(format!("agentz-claude-{}.jsonl", uuid::Uuid::new_v4()));
        fs::write(
            &path,
            r#"{"type":"user","cwd":"/work","message":{"content":"<command>ignored</command>"}}
{"type":"user","cwd":"/work","message":{"content":[{"type":"text","text":"\n  fix the bug\nmore"}]}}
{"type":"ai-title","aiTitle":"half"#,
        )
        .unwrap();

        let mut scanner = Scanner::default();
        let session = scanner.visit(&path, Agent::Claude).unwrap();
        assert_eq!(session.title, "fix the bug");
        assert_eq!(session.cwd, Path::new("/work"));

        // The half-written line is read once it is complete.
        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(
            br#" title"}
{"type":"custom-title","customTitle":"Named"}
"#,
        )
        .unwrap();
        drop(file);
        let session = scanner.visit(&path, Agent::Claude).unwrap();
        assert_eq!(session.title, "Named");
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn claude_branch_and_pull_request_are_the_last_ones() {
        let path =
            std::env::temp_dir().join(format!("agentz-claude-{}.jsonl", uuid::Uuid::new_v4()));
        fs::write(
            &path,
            r#"{"type":"user","cwd":"/work","gitBranch":"main","message":{"content":"open a PR"}}
{"type":"assistant","gitBranch":"fix/x","message":{"content":[{"type":"text","text":"\"gitBranch\":\"not-this\""}]}}
{"type":"pr-link","sessionId":"s","prNumber":1555,"prUrl":"https://github.com/o/r/pull/1555","prRepository":"o/r"}
{"type":"user","message":{"content":"no branch on this line"}}
"#,
        )
        .unwrap();
        let mut scanner = Scanner::default();
        let session = scanner.visit(&path, Agent::Claude).unwrap();
        assert_eq!(session.branch.as_deref(), Some("fix/x"));
        assert_eq!(
            session.pr,
            Some(PullRequest {
                number: 1555,
                url: "https://github.com/o/r/pull/1555".into()
            })
        );

        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(
            br#"{"type":"pr-link","prNumber":1600,"prUrl":"https://github.com/o/r/pull/1600"}
{"type":"user","gitBranch":"HEAD","message":{"content":"detached"}}
"#,
        )
        .unwrap();
        drop(file);
        let session = scanner.visit(&path, Agent::Claude).unwrap();
        assert_eq!(session.branch, None);
        assert_eq!(session.pr.map(|pr| pr.number), Some(1600));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn claude_stop_at_the_rate_limit_lasts_until_it_goes_on() {
        let path =
            std::env::temp_dir().join(format!("agentz-claude-{}.jsonl", uuid::Uuid::new_v4()));
        let append = |text: &str| {
            let mut file = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .unwrap();
            file.write_all(text.as_bytes()).unwrap();
        };
        append(
            r#"{"type":"user","cwd":"/work","message":{"content":"fix the bug"}}
{"type":"assistant","timestamp":"2026-09-03T09:32:07.350Z","isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 2:10pm (Europe/Istanbul)"}]}}
"#,
        );
        let mut scanner = Scanner::default();
        let limit = scanner.visit(&path, Agent::Claude).unwrap().limit;
        assert_eq!(
            limit,
            Some(LimitStop {
                message: "You've hit your session limit · resets 2:10pm (Europe/Istanbul)".into(),
                at: SystemTime::UNIX_EPOCH + std::time::Duration::from_millis(1_788_427_927_350),
            })
        );
        // Other errors, what Claude adds by itself and commands do not end it.
        append(
            r#"{"type":"assistant","isApiErrorMessage":true,"error":"server_error","message":{"content":[{"type":"text","text":"API Error: 500"}]}}
{"type":"user","isMeta":true,"message":{"content":"Caveat: local commands"}}
{"type":"user","message":{"content":"<command-name>/usage</command-name>"}}
{"type":"system","subtype":"info","content":"\"type\":\"user\""}
"#,
        );
        assert!(scanner.visit(&path, Agent::Claude).unwrap().limit.is_some());
        append(
            r#"{"type":"user","message":{"content":"continue"}}
"#,
        );
        assert_eq!(scanner.visit(&path, Agent::Claude).unwrap().limit, None);
        // An answer ends it too.
        append(
            r#"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"content":[{"type":"text","text":"limit"}]}}
"#,
        );
        let limit = scanner.visit(&path, Agent::Claude).unwrap().limit.unwrap();
        // Without a timestamp, the file's time.
        assert!(limit.at > SystemTime::now() - std::time::Duration::from_secs(60));
        append(
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Going on."}]}}
"#,
        );
        assert_eq!(scanner.visit(&path, Agent::Claude).unwrap().limit, None);
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn codex_stop_at_the_rate_limit_lasts_until_the_next_turn() {
        let path =
            std::env::temp_dir().join(format!("agentz-codex-limit-{}.jsonl", uuid::Uuid::new_v4()));
        fs::write(
            &path,
            r#"{"type":"session_meta","payload":{"id":"c1","cwd":"/tmp","source":"cli","originator":"codex-tui"}}
{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}}
{"timestamp":"2026-07-31T07:19:09.611Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":null,"error":{"message":"You've hit your usage limit. Try again at Aug 5th, 2026 9:34 AM.","codex_error_info":"usage_limit_exceeded"}}}
"#,
        )
        .unwrap();
        let mut scanner = Scanner::default();
        let limit = scanner.visit(&path, Agent::Codex).unwrap().limit.unwrap();
        assert_eq!(
            limit.message,
            "You've hit your usage limit. Try again at Aug 5th, 2026 9:34 AM."
        );
        assert_eq!(
            limit.at,
            SystemTime::UNIX_EPOCH + std::time::Duration::from_millis(1_785_482_349_611)
        );
        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(
            br#"{"type":"event_msg","payload":{"type":"task_started"}}
"#,
        )
        .unwrap();
        drop(file);
        let session = scanner.visit(&path, Agent::Codex).unwrap();
        assert_eq!(session.limit, None);
        assert_eq!(session.title, "go");
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn claude_last_action_is_from_the_last_turn() {
        let path =
            std::env::temp_dir().join(format!("agentz-claude-{}.jsonl", uuid::Uuid::new_v4()));
        let append = |text: &str| {
            let mut file = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .unwrap();
            file.write_all(text.as_bytes()).unwrap();
        };
        append(
            r#"{"type":"user","cwd":"/work","timestamp":"2026-09-03T09:32:07.350Z","message":{"content":"run the tests"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/work/Makefile"}}]}}
{"type":"user","message":{"content":[{"tool_use_id":"t1","type":"tool_result","content":"test:"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"make test","description":"Run the tests"}}]}}
"#,
        );
        let mut scanner = Scanner::default();
        let session = scanner.visit(&path, Agent::Claude).unwrap();
        assert_eq!(
            session.turn_started,
            Some(SystemTime::UNIX_EPOCH + std::time::Duration::from_millis(1_788_427_927_350))
        );
        assert_eq!(
            session.action.map(|a| (a.kind, a.detail)),
            Some((action::ActionKind::Command, "Run the tests".into()))
        );
        // A tool's result and what Claude adds by itself start no turn.
        append(
            r#"{"type":"user","message":{"content":[{"tool_use_id":"t2","type":"tool_result","content":"ok"}]}}
{"type":"user","isMeta":true,"message":{"content":"Caveat: local commands"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"All pass."}]}}
"#,
        );
        let session = scanner.visit(&path, Agent::Claude).unwrap();
        assert!(session.turn_started.is_some());
        assert!(session.action.is_some());
        // A new prompt starts a turn without an action.
        append(
            r#"{"type":"user","timestamp":"2026-09-03T10:00:00Z","message":{"content":"thanks"}}
"#,
        );
        let session = scanner.visit(&path, Agent::Claude).unwrap();
        assert_eq!(
            session.turn_started,
            Some(SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_788_429_600))
        );
        assert_eq!(session.action, None);
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn codex_last_action_is_from_the_last_task() {
        let path = std::env::temp_dir().join(format!(
            "agentz-codex-action-{}.jsonl",
            uuid::Uuid::new_v4()
        ));
        let append = |text: &str| {
            let mut file = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .unwrap();
            file.write_all(text.as_bytes()).unwrap();
        };
        // The first task starts before the first prompt.
        append(
            r#"{"type":"session_meta","payload":{"id":"c2","cwd":"/tmp","source":"cli","originator":"codex-tui"}}
{"timestamp":"2026-09-03T09:32:07.350Z","type":"event_msg","payload":{"type":"task_started"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"build it"}]}}
{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"cargo build\"}"}}
{"type":"response_item","payload":{"type":"function_call_output","output":"\"function_call\""}}
{"type":"response_item","payload":{"type":"function_call","name":"write_stdin","arguments":"{\"session_id\":1}"}}
"#,
        );
        let mut scanner = Scanner::default();
        let session = scanner.visit(&path, Agent::Codex).unwrap();
        assert_eq!(
            session.turn_started,
            Some(SystemTime::UNIX_EPOCH + std::time::Duration::from_millis(1_788_427_927_350))
        );
        assert_eq!(
            session.action.map(|a| (a.kind, a.detail)),
            Some((action::ActionKind::Command, "cargo build".into()))
        );
        append(
            r#"{"timestamp":"2026-09-03T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}
"#,
        );
        let session = scanner.visit(&path, Agent::Codex).unwrap();
        assert_eq!(
            session.turn_started,
            Some(SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_788_429_600))
        );
        assert_eq!(session.action, None);
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn parses_transcript_times() {
        let at = |s| {
            parse_time(s).map(|t| {
                t.duration_since(SystemTime::UNIX_EPOCH)
                    .unwrap()
                    .as_millis()
            })
        };
        assert_eq!(at("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(at("2026-09-03T09:32:07.350Z"), Some(1_788_427_927_350));
        assert_eq!(at("2024-02-29T23:59:59.5Z"), Some(1_709_251_199_500));
        assert_eq!(at("2026-09-03T09:32:07+03:00"), None);
        assert_eq!(at("2026-13-03T09:32:07Z"), None);
        assert_eq!(at("soon"), None);
    }

    #[test]
    fn reads_escaped_branch_names() {
        assert_eq!(git_branch(r#"{"x":1}"#), None);
        assert_eq!(git_branch(r#"{"gitBranch":""}"#), Some(None));
        assert_eq!(
            git_branch(r#"{"gitBranch":"a\"b","type":"user"}"#),
            Some(Some("a\"b".into()))
        );
    }

    #[test]
    fn cleans_prompts() {
        let clean = |s: &str| clean_prompt(s.to_string());
        assert_eq!(clean("  "), None);
        assert_eq!(clean("# AGENTS.md instructions"), None);
        assert_eq!(clean("Caveat: the messages below"), None);
        assert_eq!(clean("\n\n  hello\nworld").as_deref(), Some("hello"));
        assert_eq!(clean(&"x".repeat(300)).map(|s| s.len()), Some(200));
    }
}
