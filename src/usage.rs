//! How much of their plan's rate limits Claude and Codex have left.
//!
//! Claude Code: sends `rate_limits` to its status line command. agentz
//!              starts Claude with its own status line (`agentz statusline`),
//!              which saves them to a file and then runs the user's one.
//! Codex:       writes `rate_limits` into the rollout file after each turn.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

use crate::sessions::claude_dir;

/// Tells `agentz statusline` which status line command the user set up.
pub const USER_STATUS_LINE_VAR: &str = "AGENTZ_USER_STATUS_LINE";

/// Codex rollout files can be large; the last turn is near the end.
const CODEX_TAIL: u64 = 1024 * 1024;
/// How many of the most recently changed rollout files to look at.
const CODEX_FILES: usize = 5;

/// One rate limit window.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Window {
    /// Percent of the limit used, 0-100.
    pub used: f64,
    /// Unix seconds when the window starts over.
    pub resets_at: u64,
}

impl Window {
    /// Percent left right now. A window whose reset time has passed is
    /// fully available again.
    pub fn left(&self, now: u64) -> f64 {
        if self.resets_at <= now {
            100.0
        } else {
            (100.0 - self.used).clamp(0.0, 100.0)
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Usage {
    /// The 5-hour window.
    pub session: Option<Window>,
    /// The weekly window.
    pub week: Option<Window>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Limits {
    pub claude: Option<Usage>,
    pub codex: Option<Usage>,
}

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

// ---------- Claude ----------

/// Where `agentz statusline` saves Claude's last `rate_limits`.
fn claude_file() -> Option<PathBuf> {
    Some(
        dirs::cache_dir()?
            .join("agentz")
            .join("claude-rate-limits.json"),
    )
}

pub fn claude() -> Option<Usage> {
    let text = fs::read_to_string(claude_file()?).ok()?;
    parse_claude(&serde_json::from_str(&text).ok()?)
}

/// `{"five_hour": {"used_percentage", "resets_at"}, "seven_day": {...}}`
fn parse_claude(v: &Value) -> Option<Usage> {
    let window = |w: &Value| {
        Some(Window {
            used: w["used_percentage"].as_f64()?,
            resets_at: w["resets_at"].as_u64()?,
        })
    };
    let usage = Usage {
        session: window(&v["five_hour"]),
        week: window(&v["seven_day"]),
    };
    (usage != Usage::default()).then_some(usage)
}

/// The `--settings` value that makes Claude run `agentz statusline`, and
/// the user's own status line command to pass on in
/// `AGENTZ_USER_STATUS_LINE`. Settings from `--settings` win over the
/// user's, so their status line has to be run by ours.
pub fn claude_settings(cwd: &Path) -> Option<(String, Option<String>)> {
    let exe = std::env::current_exe().ok()?;
    let ours = format!("{} statusline", shell_quote(&exe.to_string_lossy()));

    // Later files win, like in Claude Code, so look at them first.
    let mut files: Vec<PathBuf> = claude_dir()
        .map(|d| d.join("settings.json"))
        .into_iter()
        .collect();
    files.push(cwd.join(".claude").join("settings.json"));
    files.push(cwd.join(".claude").join("settings.local.json"));
    let theirs = files
        .iter()
        .rev()
        .filter_map(|f| fs::read_to_string(f).ok())
        .filter_map(|t| serde_json::from_str::<Value>(&t).ok())
        .filter_map(|v| v.get("statusLine").filter(|s| s.is_object()).cloned())
        .next();

    // Keep the rest of their settings, e.g. `padding`.
    let mut line = theirs.unwrap_or_else(|| serde_json::json!({ "type": "command" }));
    let user_cmd = line["command"]
        .as_str()
        .filter(|c| !c.trim().is_empty())
        .map(str::to_string);
    line["command"] = Value::String(ours);
    let settings = serde_json::json!({ "statusLine": line });
    Some((settings.to_string(), user_cmd))
}

/// `agentz statusline`: Claude runs this with its status as JSON on stdin.
/// Saves the rate limits, then prints the user's own status line.
pub fn status_line() -> anyhow::Result<()> {
    let mut input = Vec::new();
    std::io::stdin().read_to_end(&mut input)?;
    if let Ok(v) = serde_json::from_slice::<Value>(&input)
        && parse_claude(&v["rate_limits"]).is_some()
        && let Some(path) = claude_file()
    {
        // Write and rename, so the UI never reads half a file.
        let _ = fs::create_dir_all(path.parent().unwrap_or(Path::new(".")));
        let tmp = path.with_extension(format!("{}.tmp", std::process::id()));
        if fs::write(&tmp, v["rate_limits"].to_string()).is_ok() {
            let _ = fs::rename(&tmp, &path);
        }
    }

    let Some(cmd) = std::env::var(USER_STATUS_LINE_VAR)
        .ok()
        .filter(|c| !c.is_empty())
    else {
        return Ok(());
    };
    let mut child = Command::new("sh")
        .arg("-c")
        .arg(cmd)
        .stdin(Stdio::piped())
        .spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(&input);
    }
    let status = child.wait()?;
    std::process::exit(status.code().unwrap_or(1));
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

// ---------- Codex ----------

/// Remembers what each rollout file had, so unchanged files are not read
/// again on every scan.
#[derive(Default)]
pub struct CodexReader {
    cache: HashMap<PathBuf, (u64, Option<(String, Usage)>)>,
}

impl CodexReader {
    /// The most recent limits in the rollout files that changed last. The
    /// limits are per account, so any session's file will do. A file can
    /// change without a new turn, e.g. when an old session is resumed, so
    /// the newest file may hold old limits: compare when they were written.
    /// `files` is newest first.
    pub fn read(&mut self, files: &[PathBuf]) -> Option<Usage> {
        let files = &files[..files.len().min(CODEX_FILES)];
        self.cache.retain(|p, _| files.contains(p));
        let mut newest: Option<(String, Usage)> = None;
        for path in files {
            let Ok(len) = fs::metadata(path).map(|m| m.len()) else {
                continue;
            };
            let found = match self.cache.get(path) {
                Some((l, found)) if *l == len => found.clone(),
                _ => {
                    let found = codex_tail(path, len);
                    self.cache.insert(path.clone(), (len, found.clone()));
                    found
                }
            };
            // RFC 3339 times in UTC sort as strings.
            if let Some((time, usage)) = found
                && newest.as_ref().is_none_or(|(t, _)| time > *t)
            {
                newest = Some((time, usage));
            }
        }
        newest.map(|(_, usage)| usage)
    }
}

/// The last `rate_limits` in the end of a rollout file, and when it was
/// written.
fn codex_tail(path: &Path, len: u64) -> Option<(String, Usage)> {
    let mut file = File::open(path).ok()?;
    let start = len.saturating_sub(CODEX_TAIL);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut buf = Vec::new();
    file.take(len - start).read_to_end(&mut buf).ok()?;
    let text = String::from_utf8_lossy(&buf);
    text.lines()
        .rev()
        .filter(|l| l.contains("\"rate_limits\""))
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .find_map(|v| {
            let usage = parse_codex(&v["payload"]["rate_limits"])?;
            Some((v["timestamp"].as_str()?.to_string(), usage))
        })
}

/// `{"limit_id": "codex", "primary": {"used_percent", "window_minutes",
/// "resets_at"}, "secondary": {...}}`
fn parse_codex(v: &Value) -> Option<Usage> {
    // Some models have limits of their own; show the main one.
    if v["limit_id"].as_str().is_some_and(|id| id != "codex") {
        return None;
    }
    let mut usage = Usage::default();
    for (key, default_short) in [("primary", true), ("secondary", false)] {
        let w = &v[key];
        let Some(used) = w["used_percent"].as_f64() else {
            continue;
        };
        let Some(resets_at) = w["resets_at"].as_u64() else {
            continue;
        };
        let window = Window { used, resets_at };
        let short = w["window_minutes"]
            .as_u64()
            .map_or(default_short, |m| m <= 24 * 60);
        if short {
            usage.session = Some(window);
        } else {
            usage.week = Some(window);
        }
    }
    (usage != Usage::default()).then_some(usage)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_uses_last_rate_limits_in_file() {
        let path =
            std::env::temp_dir().join(format!("agentz-codex-usage-{}.jsonl", uuid::Uuid::new_v4()));
        fs::write(
            &path,
            r#"{"type":"session_meta","payload":{"id":"x"}}
{"timestamp":"2026-09-24T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":10.0,"window_minutes":300,"resets_at":100},"secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":200}}}}
{"timestamp":"2026-09-24T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":25.0,"window_minutes":300,"resets_at":1790011725},"secondary":{"used_percent":4.0,"window_minutes":10080,"resets_at":1790598525}}}}
{"timestamp":"2026-09-24T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex_other","primary":{"used_percent":90.0,"window_minutes":300,"resets_at":5}}}}
{"timestamp":"2026-09-24T10:03:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":null}}
"#,
        )
        .unwrap();
        // A file that changed later but has older limits.
        let old = path.with_extension("old.jsonl");
        fs::write(
            &old,
            r#"{"timestamp":"2026-09-21T13:32:25.051Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":99.0,"window_minutes":300,"resets_at":1}}}}
"#,
        )
        .unwrap();
        let usage = CodexReader::default()
            .read(&[old.clone(), path.clone()])
            .unwrap();
        assert_eq!(
            usage.session,
            Some(Window {
                used: 25.0,
                resets_at: 1790011725
            })
        );
        assert_eq!(
            usage.week,
            Some(Window {
                used: 4.0,
                resets_at: 1790598525
            })
        );
        fs::remove_file(path).unwrap();
        fs::remove_file(old).unwrap();
    }

    #[test]
    fn claude_rate_limits() {
        let v: Value = serde_json::from_str(
            r#"{"five_hour":{"used_percentage":42,"resets_at":1790011725},"seven_day":{"used_percentage":12.5,"resets_at":1790598525}}"#,
        )
        .unwrap();
        let usage = parse_claude(&v).unwrap();
        assert_eq!(usage.session.unwrap().left(0), 58.0);
        assert_eq!(usage.week.unwrap().left(0), 87.5);
        // The window started over.
        assert_eq!(usage.session.unwrap().left(1790011725), 100.0);
        assert!(parse_claude(&Value::Null).is_none());
    }
}
