//! Open tabs saved on normal quit and claimed by the next interactive launch.

use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::sessions::Agent;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct SavedTab {
    pub agent: Agent,
    /// None for a shell or an agent that has no transcript to resume yet.
    #[uniffi(default)]
    pub id: Option<String>,
    pub cwd: PathBuf,
    pub title: String,
}

#[derive(Clone, Default, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct SavedState {
    #[uniffi(default)]
    pub tabs: Vec<SavedTab>,
    /// The index of the tab that was shown.
    #[uniffi(default)]
    pub active: Option<u32>,
    /// The folder the window showed.
    #[uniffi(default)]
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<PathBuf>,
}

/// The name of the state file, and of its lock. `mac-` because a terminal
/// UI once kept its tabs in `open-tabs`.
const STEM: &str = "mac-open-tabs";

fn state_dir() -> Result<PathBuf> {
    Ok(dirs::data_local_dir()
        .context("could not find a data directory for session restore")?
        .join("agentz"))
}

pub fn save(state: SavedState) -> Result<()> {
    if state.tabs.is_empty() {
        return Ok(());
    }
    save_in(&state_dir()?, state)
}

pub fn take() -> Result<Option<SavedState>> {
    take_in(&state_dir()?)
}

fn save_in(dir: &Path, state: SavedState) -> Result<()> {
    if state.tabs.is_empty() {
        return Ok(());
    }
    with_lock(dir, || {
        let path = dir.join(format!("{STEM}.json"));
        let mut saved = read(&path)?.unwrap_or_default();
        let base = saved.tabs.len();
        saved.tabs.extend(state.tabs);
        let shown = state.active.map(|i| base + i as usize);
        saved.project = state.project.or(saved.project);
        // Two agentz windows can show the same agent. Resume that session
        // once, using the last window's tab and selection.
        let mut unique = Vec::new();
        let mut active: Option<usize> = None;
        for (i, tab) in saved.tabs.into_iter().enumerate() {
            if let Some(id) = &tab.id
                && let Some(previous) = unique.iter().position(|other: &SavedTab| {
                    other.agent == tab.agent && other.id.as_ref() == Some(id)
                })
            {
                unique.remove(previous);
                if let Some(selected) = active.as_mut() {
                    if *selected == previous {
                        active = None;
                    } else if *selected > previous {
                        *selected -= 1;
                    }
                }
            }
            if shown == Some(i) {
                active = Some(unique.len());
            }
            unique.push(tab);
        }
        saved.tabs = unique;
        saved.active = active.map(|i| i as u32);
        write_atomic(&path, &saved)
    })
}

fn take_in(dir: &Path) -> Result<Option<SavedState>> {
    with_lock(dir, || {
        let path = dir.join(format!("{STEM}.json"));
        let state = read(&path)?;
        if state.is_some() {
            fs::remove_file(&path)?;
        }
        Ok(state)
    })
}

fn read(path: &Path) -> Result<Option<SavedState>> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
    };
    serde_json::from_slice(&bytes)
        .with_context(|| format!("parsing {}", path.display()))
        .map(Some)
}

fn write_atomic(path: &Path, state: &SavedState) -> Result<()> {
    let dir = path.parent().context("state path has no parent")?;
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("state");
    let tmp = dir.join(format!(".{stem}-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| -> Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)?;
        serde_json::to_writer(&mut file, state)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(&tmp, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

fn with_lock<T>(dir: &Path, action: impl FnOnce() -> Result<T>) -> Result<T> {
    fs::create_dir_all(dir)?;
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(dir.join(format!("{STEM}.lock")))?;
    loop {
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) } == 0 {
            break;
        }
        let err = std::io::Error::last_os_error();
        if err.kind() != ErrorKind::Interrupted {
            return Err(err).context("locking saved tabs");
        }
    }
    let result = action();
    drop(lock); // flock is released when the file closes.
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saves_multiple_quits_and_restores_only_once() {
        let dir = std::env::temp_dir().join(format!("agentz-state-{}", uuid::Uuid::new_v4()));
        let tab = |agent, id: Option<&str>| SavedTab {
            agent,
            id: id.map(str::to_string),
            cwd: PathBuf::from("/tmp"),
            title: "tab".into(),
        };
        save_in(
            &dir,
            SavedState {
                tabs: vec![tab(Agent::Shell, None), tab(Agent::Claude, Some("one"))],
                active: Some(1),
                ..SavedState::default()
            },
        )
        .unwrap();
        save_in(
            &dir,
            SavedState {
                tabs: vec![
                    tab(Agent::Claude, Some("one")),
                    tab(Agent::Codex, Some("two")),
                ],
                active: Some(1),
                ..SavedState::default()
            },
        )
        .unwrap();
        let saved = take_in(&dir).unwrap().unwrap();
        assert_eq!(saved.tabs.len(), 3);
        assert_eq!(saved.tabs[0].agent, Agent::Shell);
        assert_eq!(saved.tabs[1].id.as_deref(), Some("one"));
        assert_eq!(saved.tabs[2].id.as_deref(), Some("two"));
        assert_eq!(saved.active, Some(2));
        assert_eq!(take_in(&dir).unwrap(), None);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn keeps_the_last_project_and_reads_older_files() {
        let dir = std::env::temp_dir().join(format!("agentz-state-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        // Written by an older build: sidebar fields, no null ids.
        fs::write(
            dir.join("mac-open-tabs.json"),
            br#"{"tabs":[{"agent":"shell","cwd":"/tmp","title":"fish"}],"active":0,"sidebar_focused":false,"sidebar_width":0,"project":"/repo"}"#,
        )
        .unwrap();
        let tab = SavedTab {
            agent: Agent::Claude,
            id: Some("one".into()),
            cwd: PathBuf::from("/repo"),
            title: "tab".into(),
        };
        let state = SavedState {
            tabs: vec![tab.clone()],
            ..SavedState::default()
        };
        save_in(&dir, state).unwrap();
        let saved = take_in(&dir).unwrap().unwrap();
        assert_eq!(saved.tabs.len(), 2);
        assert_eq!(saved.tabs[0].id, None);
        assert_eq!(saved.tabs[1], tab);
        assert_eq!(saved.project, Some(PathBuf::from("/repo")));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn malformed_state_is_not_consumed() {
        let dir = std::env::temp_dir().join(format!("agentz-state-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("mac-open-tabs.json"), b"broken").unwrap();
        assert!(take_in(&dir).is_err());
        assert!(dir.join("mac-open-tabs.json").exists());
        fs::remove_dir_all(dir).unwrap();
    }
}
