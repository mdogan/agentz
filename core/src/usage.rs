//! How much of their plan's rate limits Claude and Codex have left.
//!
//! Claude Code: sends `rate_limits` to its status line command. agentz
//!              starts Claude with its own status line (`agentz statusline`),
//!              which saves them to a file and then runs the user's one.
//!              Users can also install it in Claude's user settings, so
//!              manually launched sessions report their limits too.
//! Codex:       writes `rate_limits` into the rollout file after each turn.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::sessions::claude_dir;

/// Tells `agentz statusline` which status line command the user set up.
pub const USER_STATUS_LINE_VAR: &str = "AGENTZ_USER_STATUS_LINE";
const REGISTRATION_FILE: &str = "agentz-statusline.json";

#[derive(Serialize, Deserialize)]
struct Registration {
    installed_command: String,
    installed_line: Value,
    original: Option<Value>,
    settings_existed: bool,
}

/// Codex rollout files can be large; the last turn is near the end.
const CODEX_TAIL: u64 = 1024 * 1024;
/// How many of the most recently changed rollout files to look at.
const CODEX_FILES: usize = 5;

/// One rate limit window.
#[derive(Clone, Copy, Debug, PartialEq, uniffi::Record)]
pub struct Window {
    /// Percent of the limit used, 0-100.
    pub used: f64,
    /// Unix seconds when the window starts over.
    pub resets_at: u64,
}

#[uniffi::export]
impl Window {
    /// Percent left at `now` (Unix seconds). A window whose reset time has
    /// passed is fully available again.
    pub fn left(&self, now: u64) -> f64 {
        if self.resets_at <= now {
            100.0
        } else {
            (100.0 - self.used).clamp(0.0, 100.0)
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, uniffi::Record)]
pub struct Usage {
    /// The 5-hour window.
    pub session: Option<Window>,
    /// The weekly window.
    pub week: Option<Window>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, uniffi::Record)]
pub struct Limits {
    #[uniffi(default)]
    pub claude: Option<Usage>,
    #[uniffi(default)]
    pub codex: Option<Usage>,
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
/// user's, so their status line has to be run by ours. `exe` is the agentz
/// program that Claude runs as `<exe> statusline`.
pub fn claude_settings(cwd: &Path, exe: &Path) -> Option<(String, Option<String>)> {
    claude_settings_for(cwd, &claude_dir()?, exe)
}

fn claude_settings_for(
    cwd: &Path,
    config_dir: &Path,
    exe: &Path,
) -> Option<(String, Option<String>)> {
    let ours = status_line_command(exe);

    // Later files win, like in Claude Code, so look at them first.
    let mut files = vec![config_dir.join("settings.json")];
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
    let registration = active_registration(config_dir);
    let user_cmd = delegate_command(&line, registration.as_ref())
        .filter(|cmd| cmd != &ours && cmd.trim() != "agentz statusline");
    line["command"] = Value::String(ours);
    let settings = serde_json::json!({ "statusLine": line });
    Some((settings.to_string(), user_cmd))
}

fn status_line_command(exe: &Path) -> String {
    format!("{} statusline", shell_quote(&exe.to_string_lossy()))
}

fn command(line: &Value) -> Option<String> {
    line["command"]
        .as_str()
        .filter(|cmd| !cmd.trim().is_empty())
        .map(str::to_string)
}

fn delegate_command(line: &Value, registration: Option<&Registration>) -> Option<String> {
    let cmd = command(line)?;
    match registration {
        Some(reg) if cmd == reg.installed_command => reg.original.as_ref().and_then(command),
        _ => Some(cmd),
    }
}

fn settings_path(config_dir: &Path) -> PathBuf {
    config_dir.join("settings.json")
}

fn registration_path(config_dir: &Path) -> PathBuf {
    config_dir.join(REGISTRATION_FILE)
}

fn read_settings(path: &Path) -> anyhow::Result<Value> {
    match fs::read(path) {
        Ok(bytes) => {
            let value: Value = serde_json::from_slice(&bytes)?;
            anyhow::ensure!(
                value.is_object(),
                "{} must contain a JSON object",
                path.display()
            );
            Ok(value)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(serde_json::json!({})),
        Err(e) => Err(e.into()),
    }
}

fn read_registration(config_dir: &Path) -> anyhow::Result<Option<Registration>> {
    match fs::read(registration_path(config_dir)) {
        Ok(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}

fn active_registration(config_dir: &Path) -> Option<Registration> {
    let reg = read_registration(config_dir).ok()??;
    let settings = read_settings(&settings_path(config_dir)).ok()?;
    (command(&settings["statusLine"]).as_deref() == Some(reg.installed_command.as_str()))
        .then_some(reg)
}

fn saved_status_line_command(config_dir: &Path) -> Option<String> {
    active_registration(config_dir)?
        .original
        .as_ref()
        .and_then(command)
}

/// `agentz statusline install|uninstall`: installs or removes the Claude
/// user setting that reports limits from every manual `claude` launch. The
/// prior status line is saved for forwarding. Returns what was done.
pub fn configure_status_line(action: &str, exe: &Path) -> anyhow::Result<String> {
    let config_dir =
        claude_dir().ok_or_else(|| anyhow::anyhow!("Claude config directory not found"))?;
    let settings = settings_path(&config_dir);
    match action {
        "install" => {
            install_status_line(&config_dir, exe)?;
            Ok(format!(
                "Installed agentz status line in {}",
                settings.display()
            ))
        }
        "uninstall" => {
            uninstall_status_line(&config_dir)?;
            Ok(format!(
                "Restored Claude status line in {}",
                settings.display()
            ))
        }
        _ => anyhow::bail!("usage: agentz statusline [install|uninstall]"),
    }
}

fn install_status_line(config_dir: &Path, exe: &Path) -> anyhow::Result<()> {
    let path = settings_path(config_dir);
    if fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink()) {
        anyhow::bail!("refusing to replace symlink {}", path.display());
    }
    let existed = path.exists();
    let mut settings = read_settings(&path)?;
    let previous = read_registration(config_dir)?;
    let current = settings.get("statusLine").cloned();
    let (original, settings_existed) = match previous {
        Some(reg) if current.as_ref() == Some(&reg.installed_line) => {
            (reg.original, reg.settings_existed)
        }
        Some(reg)
            if current.as_ref().and_then(command).as_deref() == Some(&reg.installed_command) =>
        {
            anyhow::bail!("Claude statusLine changed since installation; leaving it untouched")
        }
        _ => (current, existed),
    };
    anyhow::ensure!(
        original
            .as_ref()
            .is_none_or(|v| v.is_object() || v.is_null()),
        "existing statusLine must be a JSON object"
    );
    let ours = status_line_command(exe);
    anyhow::ensure!(
        !original
            .as_ref()
            .and_then(command)
            .is_some_and(|cmd| cmd == ours || cmd.trim() == "agentz statusline"),
        "statusLine already points to agentz, but no prior status line was saved"
    );
    let mut line = original
        .clone()
        .filter(Value::is_object)
        .unwrap_or_else(|| serde_json::json!({ "type": "command" }));
    line["type"] = Value::String("command".into());
    line["command"] = Value::String(ours.clone());
    settings["statusLine"] = line.clone();
    let reg = Registration {
        installed_command: ours,
        installed_line: line,
        original,
        settings_existed,
    };
    write_json_atomic(&registration_path(config_dir), &reg)?;
    write_json_atomic(&path, &settings)?;
    Ok(())
}

fn uninstall_status_line(config_dir: &Path) -> anyhow::Result<()> {
    let reg = read_registration(config_dir)?
        .ok_or_else(|| anyhow::anyhow!("agentz status line is not installed"))?;
    let path = settings_path(config_dir);
    let mut settings = read_settings(&path)?;
    anyhow::ensure!(
        settings.get("statusLine") == Some(&reg.installed_line),
        "Claude statusLine changed since installation; leaving it untouched"
    );
    match reg.original {
        Some(line) => settings["statusLine"] = line,
        None => {
            settings.as_object_mut().unwrap().remove("statusLine");
        }
    }
    if !reg.settings_existed && settings.as_object().is_some_and(|v| v.is_empty()) {
        fs::remove_file(&path)?;
    } else {
        write_json_atomic(&path, &settings)?;
    }
    fs::remove_file(registration_path(config_dir))?;
    Ok(())
}

fn write_json_atomic(path: &Path, value: &impl Serialize) -> anyhow::Result<()> {
    use std::fs::OpenOptions;
    use std::os::unix::fs::OpenOptionsExt;

    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("path has no parent"))?;
    fs::create_dir_all(parent)?;
    if fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink()) {
        anyhow::bail!("refusing to replace symlink {}", path.display());
    }
    let tmp = parent.join(format!(".agentz-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| -> anyhow::Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)?;
        if let Ok(meta) = fs::metadata(path) {
            fs::set_permissions(&tmp, meta.permissions())?;
        }
        let mut bytes = serde_json::to_vec_pretty(value)?;
        bytes.push(b'\n');
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&tmp, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

/// `agentz statusline`: Claude runs this with its status as JSON on stdin.
/// Saves the rate limits, then runs the user's own status line and returns
/// its exit code.
pub fn status_line() -> anyhow::Result<i32> {
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
        .or_else(|| {
            let dir = claude_dir()?;
            saved_status_line_command(&dir)
        })
        .filter(|cmd| cmd.trim() != "agentz statusline")
    else {
        return Ok(0);
    };
    let mut child = Command::new("sh")
        .arg("-c")
        .arg(cmd)
        .stdin(Stdio::piped())
        .spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(&input);
    }
    Ok(child.wait()?.code().unwrap_or(1))
}

/// Quotes `s` for `sh`.
pub fn shell_quote(s: &str) -> String {
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

    #[test]
    fn installing_and_removing_preserves_claude_settings_and_status_line() {
        let dir = std::env::temp_dir().join(format!("agentz-statusline-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        let original = serde_json::json!({
            "permissions": { "allow": ["Read"] },
            "statusLine": { "type": "command", "command": "printf own", "padding": 2 }
        });
        fs::write(settings_path(&dir), original.to_string()).unwrap();
        let exe = Path::new("/tmp/agentz's bin");
        install_status_line(&dir, exe).unwrap();
        let installed = read_settings(&settings_path(&dir)).unwrap();
        assert_eq!(installed["permissions"], original["permissions"]);
        assert_eq!(installed["statusLine"]["padding"], 2);
        assert_eq!(
            active_registration(&dir).unwrap().original,
            Some(original["statusLine"].clone())
        );
        assert_eq!(
            saved_status_line_command(&dir).as_deref(),
            Some("printf own")
        );
        let (_, delegate) = claude_settings_for(&dir, &dir, exe).unwrap();
        assert_eq!(delegate.as_deref(), Some("printf own"));
        let project = dir.join("project");
        fs::create_dir_all(project.join(".claude")).unwrap();
        fs::write(
            project.join(".claude/settings.json"),
            r#"{"statusLine":{"type":"command","command":"printf project"}}"#,
        )
        .unwrap();
        let (_, project_delegate) = claude_settings_for(&project, &dir, exe).unwrap();
        assert_eq!(project_delegate.as_deref(), Some("printf project"));

        // Reinstalling after the executable moves must keep the real original.
        install_status_line(&dir, Path::new("/tmp/new-agentz")).unwrap();
        assert_eq!(
            active_registration(&dir).unwrap().original,
            Some(original["statusLine"].clone())
        );
        uninstall_status_line(&dir).unwrap();
        assert_eq!(read_settings(&settings_path(&dir)).unwrap(), original);
        assert!(!registration_path(&dir).exists());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn uninstall_keeps_a_status_line_changed_after_install() {
        let dir = std::env::temp_dir().join(format!("agentz-statusline-{}", uuid::Uuid::new_v4()));
        install_status_line(&dir, Path::new("/tmp/agentz")).unwrap();
        assert!(settings_path(&dir).exists());
        assert!(saved_status_line_command(&dir).is_none());
        let replacement = serde_json::json!({ "statusLine": { "type": "command", "command": status_line_command(Path::new("/tmp/agentz")), "padding": 3 } });
        write_json_atomic(&settings_path(&dir), &replacement).unwrap();
        assert!(uninstall_status_line(&dir).is_err());
        assert_eq!(read_settings(&settings_path(&dir)).unwrap(), replacement);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn uninstall_removes_settings_file_that_did_not_exist_before() {
        let dir = std::env::temp_dir().join(format!("agentz-statusline-{}", uuid::Uuid::new_v4()));
        install_status_line(&dir, Path::new("/tmp/agentz")).unwrap();
        uninstall_status_line(&dir).unwrap();
        assert!(!settings_path(&dir).exists());
        fs::remove_dir_all(dir).unwrap();
    }
}
