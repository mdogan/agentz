//! Decides which sessions belong to the project agentz was started in.
//!
//! In a git repo the project is every worktree of that repo (`git worktree
//! list`), so sessions from the main checkout and from all worktrees show up.
//! Sessions started in a subfolder of a worktree count too. Outside a repo it
//! is only the folder agentz was started from, not its subfolders, since
//! those are usually other projects (think `~/Projects`).

use std::path::{Path, PathBuf};
use std::process::Command;

pub struct Project {
    roots: Vec<PathBuf>,
    /// Whether subfolders of a root belong to the project.
    nested: bool,
}

impl Project {
    /// Asks git again each time, so worktrees added while agentz runs are
    /// picked up.
    pub fn detect(dir: &Path) -> Self {
        let worktrees = git_worktrees(dir);
        let nested = worktrees.is_some();
        let mut roots = worktrees.unwrap_or_else(|| vec![dir.to_path_buf()]);
        // Match both spellings when a root sits behind a symlink.
        for i in 0..roots.len() {
            if let Ok(real) = roots[i].canonicalize()
                && !roots.contains(&real)
            {
                roots.push(real);
            }
        }
        Project { roots, nested }
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
}

fn git_worktrees(dir: &Path) -> Option<Vec<PathBuf>> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["worktree", "list", "--porcelain"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let roots: Vec<PathBuf> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.strip_prefix("worktree "))
        .map(PathBuf::from)
        .collect();
    (!roots.is_empty()).then_some(roots)
}
