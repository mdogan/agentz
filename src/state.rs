//! Open tabs saved on normal quit and claimed by the next interactive launch.

use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::sessions::Agent;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedTab {
    pub agent: Agent,
    /// None for a shell or an agent that has no transcript to resume yet.
    pub id: Option<String>,
    pub cwd: PathBuf,
    pub title: String,
}

#[derive(Default, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedState {
    pub tabs: Vec<SavedTab>,
    pub active: Option<usize>,
    pub sidebar_focused: bool,
    pub sidebar_width: u16,
}

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
        let path = dir.join("open-tabs.json");
        let mut saved = read(&path)?.unwrap_or_default();
        let base = saved.tabs.len();
        saved.tabs.extend(state.tabs);
        saved.active = state.active.map(|i| base + i);
        saved.sidebar_focused = state.sidebar_focused;
        saved.sidebar_width = state.sidebar_width;
        // Two agentz windows can show the same agent. Resume that session
        // once, using the last window's tab and selection.
        let mut unique = Vec::new();
        let mut active = None;
        for (i, tab) in saved.tabs.into_iter().enumerate() {
            if let Some(id) = &tab.id
                && let Some(previous) = unique.iter().position(|other: &SavedTab| {
                    other.agent == tab.agent && other.id.as_ref() == Some(id)
                })
            {
                unique.remove(previous);
                if let Some(selected) = active.as_mut() {
                    let selected: &mut usize = selected;
                    if *selected == previous {
                        active = None;
                    } else if *selected > previous {
                        *selected -= 1;
                    }
                }
            }
            if saved.active == Some(i) {
                active = Some(unique.len());
            }
            unique.push(tab);
        }
        saved.tabs = unique;
        saved.active = active;
        write_atomic(&path, &saved)
    })
}

fn take_in(dir: &Path) -> Result<Option<SavedState>> {
    with_lock(dir, || {
        let path = dir.join("open-tabs.json");
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
    let tmp = dir.join(format!(".open-tabs-{}.tmp", uuid::Uuid::new_v4()));
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
        .open(dir.join("open-tabs.lock"))?;
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
                sidebar_focused: true,
                sidebar_width: 51,
            },
        )
        .unwrap();
        let saved = take_in(&dir).unwrap().unwrap();
        assert_eq!(saved.tabs.len(), 3);
        assert_eq!(saved.tabs[0].agent, Agent::Shell);
        assert_eq!(saved.tabs[1].id.as_deref(), Some("one"));
        assert_eq!(saved.tabs[2].id.as_deref(), Some("two"));
        assert_eq!(saved.active, Some(2));
        assert!(saved.sidebar_focused);
        assert_eq!(saved.sidebar_width, 51);
        assert_eq!(take_in(&dir).unwrap(), None);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn malformed_state_is_not_consumed() {
        let dir = std::env::temp_dir().join(format!("agentz-state-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("open-tabs.json"), b"broken").unwrap();
        assert!(take_in(&dir).is_err());
        assert!(dir.join("open-tabs.json").exists());
        fs::remove_dir_all(dir).unwrap();
    }
}
