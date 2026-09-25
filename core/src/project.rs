//! Decides which sessions belong to the project agentz was started in.
//!
//! In a git repo the project is every worktree of that repo (`git worktree
//! list`), so sessions from the main checkout and from all worktrees show up.
//! Sessions started in a subfolder of a worktree count too. Outside a repo it
//! is only the folder agentz was started from, not its subfolders, since
//! those are usually other projects (think `~/Projects`).

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::SystemTime;

use crate::worktree::{self, Worktree};

pub struct Project {
    roots: Vec<PathBuf>,
    /// Whether subfolders of a root belong to the project.
    nested: bool,
    /// The repo's worktrees, main first. Empty outside a repo.
    worktrees: Vec<Worktree>,
    /// Change when `detect` would find something else: git adds and
    /// removes a folder in `<git dir>/worktrees` for each worktree, and
    /// rewrites a worktree's `HEAD` when it switches branch. Outside a
    /// repo, it is the `.git` that `git init` would create.
    watched: Vec<PathBuf>,
    stamps: Vec<Option<SystemTime>>,
}

impl Project {
    pub fn detect(dir: &Path) -> Self {
        let watched =
            git_common_dir(dir).map_or_else(|| vec![dir.join(".git")], |d| watch_list(&d));
        // Before asking git, so a change while it runs shows next time.
        let stamps = watched.iter().map(|p| modified(p)).collect();
        let worktrees = worktree::list(dir).unwrap_or_default();
        let nested = !worktrees.is_empty();
        let mut roots: Vec<PathBuf> = if nested {
            worktrees.iter().map(|w| w.path.clone()).collect()
        } else {
            vec![dir.to_path_buf()]
        };
        // Match both spellings when a root sits behind a symlink.
        for i in 0..roots.len() {
            if let Ok(real) = roots[i].canonicalize()
                && !roots.contains(&real)
            {
                roots.push(real);
            }
        }
        Project {
            roots,
            nested,
            worktrees,
            watched,
            stamps,
        }
    }

    /// True once a worktree was added, removed or switched branch, or the
    /// folder became a repo. Cheaper than asking git.
    pub fn is_stale(&self) -> bool {
        self.watched
            .iter()
            .zip(&self.stamps)
            .any(|(p, s)| modified(p) != *s)
    }

    pub fn contains(&self, cwd: &Path) -> bool {
        self.roots.iter().any(|root| {
            if self.nested {
                cwd.starts_with(root)
            } else {
                cwd == root
            }
        })
    }

    pub fn worktrees(&self) -> &[Worktree] {
        &self.worktrees
    }
}

/// What to watch in the repo's `.git` folder: the list of worktrees and
/// the `HEAD` of each one.
fn watch_list(common: &Path) -> Vec<PathBuf> {
    let linked = common.join("worktrees");
    let mut watched = vec![linked.clone(), common.join("HEAD")];
    if let Ok(entries) = fs::read_dir(&linked) {
        watched.extend(entries.flatten().map(|e| e.path().join("HEAD")));
    }
    watched
}

/// The folder new sessions start in: the top of the git worktree `dir` is
/// in, or `dir` itself outside a repo.
pub fn root_of(dir: &Path) -> PathBuf {
    Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .filter(|out| out.status.success())
        .map(|out| String::from_utf8_lossy(&out.stdout).trim_end().to_string())
        .filter(|s| !s.is_empty())
        .map_or_else(|| dir.to_path_buf(), PathBuf::from)
}

fn modified(path: &Path) -> Option<SystemTime> {
    fs::metadata(path).and_then(|m| m.modified()).ok()
}

/// The repo's `.git` folder, shared by all its worktrees.
fn git_common_dir(dir: &Path) -> Option<PathBuf> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["rev-parse", "--git-common-dir"])
        .output()
        .ok()
        .filter(|out| out.status.success())?;
    let path = String::from_utf8_lossy(&out.stdout).trim_end().to_string();
    // It is relative to `dir` unless git gives an absolute path.
    (!path.is_empty()).then(|| dir.join(path))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn git(dir: &Path, args: &[&str]) {
        let ok = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .output()
            .unwrap()
            .status
            .success();
        assert!(ok, "git {args:?}");
    }

    #[test]
    fn outside_a_repo_only_the_folder_counts() {
        let dir = std::env::temp_dir().join(format!("agentz-project-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        let project = Project::detect(&dir);
        assert!(project.contains(&dir));
        assert!(!project.contains(&dir.join("sub")));
        assert_eq!(root_of(&dir), dir);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn goes_stale_when_worktrees_change() {
        let dir = std::env::temp_dir().join(format!("agentz-project-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        // git reports the real path, e.g. /private/var rather than /var.
        let dir = dir.canonicalize().unwrap();
        let project = Project::detect(&dir);
        assert!(!project.is_stale());

        git(&dir, &["init", "-q"]);
        assert!(project.is_stale());
        let project = Project::detect(&dir);
        assert!(!project.is_stale());
        assert!(project.contains(&dir.join("sub")));

        // Switching branch rewrites HEAD.
        git(&dir, &["checkout", "-q", "-b", "other"]);
        assert!(project.is_stale());
        let project = Project::detect(&dir);
        assert_eq!(project.worktrees()[0].branch.as_deref(), Some("other"));

        // What `git worktree add` does first.
        fs::create_dir_all(dir.join(".git/worktrees/other")).unwrap();
        assert!(project.is_stale());
        fs::remove_dir_all(dir).unwrap();
    }
}
