//! Open tabs saved on normal quit and claimed by the next interactive launch,
//! and pinned tabs, kept until unpinned so they come back after any start.

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
    /// Pinned tabs can't be closed, and come back even after a crash.
    #[uniffi(default = false)]
    #[serde(default, skip_serializing_if = "is_false")]
    pub pinned: bool,
}

fn is_false(b: &bool) -> bool {
    !b
}

/// Where the second pane goes when the pane area is split.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum SplitDirection {
    /// Side by side.
    Right,
    /// One above the other.
    Down,
}

/// Two panes that were shown at once.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct SavedSplit {
    pub direction: SplitDirection,
    /// The tab in the left or top pane, then in the right or bottom one, as
    /// indexes into `SavedState::tabs`. None for a pane with no terminal.
    pub panes: Vec<Option<u32>>,
    /// The pane the user worked in: 0 or 1.
    pub focused: u32,
}

#[derive(Clone, Default, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct SavedState {
    #[uniffi(default)]
    pub tabs: Vec<SavedTab>,
    /// The index of the tab that was shown, in the focused pane of a split.
    #[uniffi(default)]
    pub active: Option<u32>,
    /// The folder the window showed.
    #[uniffi(default)]
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project: Option<PathBuf>,
    /// The split, if the window showed two panes.
    #[uniffi(default)]
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub split: Option<SavedSplit>,
    /// Splits the window kept off screen while it showed other sessions.
    #[uniffi(default)]
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub hidden_splits: Vec<SavedSplit>,
}

/// The name of the state file, and of its lock.
const STEM: &str = "open-tabs";
/// The pinned tabs, rewritten each time they change.
const PINS: &str = "pinned-tabs.json";

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

pub fn save_pins(tabs: Vec<SavedTab>) -> Result<()> {
    save_pins_in(&state_dir()?, tabs)
}

pub fn pins() -> Result<Vec<SavedTab>> {
    pins_in(&state_dir()?)
}

fn save_pins_in(dir: &Path, tabs: Vec<SavedTab>) -> Result<()> {
    with_lock(dir, || {
        let path = dir.join(PINS);
        if tabs.is_empty() {
            return match fs::remove_file(&path) {
                Err(e) if e.kind() != ErrorKind::NotFound => Err(e.into()),
                _ => Ok(()),
            };
        }
        write_atomic(&path, &tabs)
    })
}

fn pins_in(dir: &Path) -> Result<Vec<SavedTab>> {
    with_lock(dir, || {
        let path = dir.join(PINS);
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
        };
        serde_json::from_slice(&bytes).with_context(|| format!("parsing {}", path.display()))
    })
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
        saved.project = state.project.or(saved.project);
        // Two agentz windows can show the same agent. Resume that session
        // once, using the last window's tab, selection and split.
        let mut unique = Vec::new();
        // Where each tab in `unique` was in `saved.tabs`.
        let mut origin = Vec::new();
        for (i, tab) in saved.tabs.into_iter().enumerate() {
            if let Some(id) = &tab.id
                && let Some(previous) = unique.iter().position(|other: &SavedTab| {
                    other.agent == tab.agent && other.id.as_ref() == Some(id)
                })
            {
                unique.remove(previous);
                origin.remove(previous);
            }
            unique.push(tab);
            origin.push(i);
        }
        // An index into the last window's tabs, as an index into `unique`.
        let kept = |i: u32| {
            let i = origin.iter().position(|&o| o == base + i as usize)?;
            Some(i as u32)
        };
        let kept_split = |split: SavedSplit| SavedSplit {
            panes: split.panes.iter().map(|p| p.and_then(kept)).collect(),
            ..split
        };
        saved.tabs = unique;
        saved.active = state.active.and_then(kept);
        saved.split = state.split.map(kept_split);
        saved.hidden_splits = state.hidden_splits.into_iter().map(kept_split).collect();
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

fn write_atomic(path: &Path, state: &impl Serialize) -> Result<()> {
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
            pinned: false,
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
            dir.join("open-tabs.json"),
            br#"{"tabs":[{"agent":"shell","cwd":"/tmp","title":"fish"}],"active":0,"sidebar_focused":false,"sidebar_width":0,"project":"/repo"}"#,
        )
        .unwrap();
        let tab = SavedTab {
            agent: Agent::Claude,
            id: Some("one".into()),
            cwd: PathBuf::from("/repo"),
            title: "tab".into(),
            pinned: false,
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
    fn keeps_the_last_split_with_its_tabs() {
        let dir = std::env::temp_dir().join(format!("agentz-state-{}", uuid::Uuid::new_v4()));
        let tab = |id: &str| SavedTab {
            agent: Agent::Claude,
            id: Some(id.into()),
            cwd: PathBuf::from("/tmp"),
            title: "tab".into(),
            pinned: false,
        };
        save_in(
            &dir,
            SavedState {
                tabs: vec![tab("one"), tab("two")],
                split: Some(SavedSplit {
                    direction: SplitDirection::Down,
                    panes: vec![Some(0), Some(1)],
                    focused: 0,
                }),
                ..SavedState::default()
            },
        )
        .unwrap();
        // The second window shows "one" too, so the first window's copy
        // goes, and the second window's tabs move down by one.
        save_in(
            &dir,
            SavedState {
                tabs: vec![tab("three"), tab("one"), tab("four"), tab("five")],
                active: Some(1),
                split: Some(SavedSplit {
                    direction: SplitDirection::Right,
                    panes: vec![Some(0), Some(1)],
                    focused: 1,
                }),
                hidden_splits: vec![SavedSplit {
                    direction: SplitDirection::Down,
                    panes: vec![Some(2), Some(3)],
                    focused: 0,
                }],
                ..SavedState::default()
            },
        )
        .unwrap();
        let text = fs::read_to_string(dir.join("open-tabs.json")).unwrap();
        assert!(text.contains(r#""direction":"right""#), "{text}");
        let saved = take_in(&dir).unwrap().unwrap();
        let ids: Vec<_> = saved.tabs.iter().filter_map(|t| t.id.as_deref()).collect();
        assert_eq!(ids, ["two", "three", "one", "four", "five"]);
        assert_eq!(saved.active, Some(2));
        assert_eq!(
            saved.split,
            Some(SavedSplit {
                direction: SplitDirection::Right,
                panes: vec![Some(1), Some(2)],
                focused: 1,
            })
        );
        assert_eq!(
            saved.hidden_splits,
            [SavedSplit {
                direction: SplitDirection::Down,
                panes: vec![Some(3), Some(4)],
                focused: 0,
            }]
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn pins_are_kept_until_unpinned() {
        let dir = std::env::temp_dir().join(format!("agentz-state-{}", uuid::Uuid::new_v4()));
        assert_eq!(pins_in(&dir).unwrap(), vec![]);
        let tab = SavedTab {
            agent: Agent::Claude,
            id: Some("one".into()),
            cwd: PathBuf::from("/repo"),
            title: "tab".into(),
            pinned: true,
        };
        save_pins_in(&dir, vec![tab.clone()]).unwrap();
        // Reading does not take them, unlike the open tabs.
        assert_eq!(pins_in(&dir).unwrap(), vec![tab.clone()]);
        assert_eq!(pins_in(&dir).unwrap(), vec![tab]);
        save_pins_in(&dir, vec![]).unwrap();
        assert!(!dir.join(PINS).exists());
        save_pins_in(&dir, vec![]).unwrap();
        assert_eq!(pins_in(&dir).unwrap(), vec![]);
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
