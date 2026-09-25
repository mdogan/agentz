//! Git worktrees: listing them and making new ones, like the `wt` tool.
//!
//! New worktrees go next to the repo: `~/src/app` → `~/src/app.worktrees/<branch>`.
//! After `git worktree add`, the git-ignored files and folders (`.env`,
//! `node_modules`, build caches, ...) are copied into the new worktree from
//! the one it started from. On APFS these are copy-on-write clones: instant,
//! and no extra disk space until a file changes.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Worktree {
    pub path: PathBuf,
    /// Short name, e.g. `main`. None when detached or bare.
    pub branch: Option<String>,
    /// The commit checked out.
    pub head: String,
    /// The main checkout, which git lists first.
    pub is_main: bool,
    pub bare: bool,
    pub locked: bool,
    /// Its folder is gone; only `git worktree prune` cleans it up.
    pub missing: bool,
}

/// A local branch, or a remote branch that has no local branch yet.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Branch {
    /// The local name, e.g. `feature/x`.
    pub name: String,
    /// E.g. `origin` for a remote-only branch; None for a local one.
    pub remote: Option<String>,
}

impl Branch {
    /// What `git worktree add` starts from: `feature/x` or `origin/feature/x`.
    pub fn git_ref(&self) -> String {
        match &self.remote {
            Some(r) => format!("{r}/{}", self.name),
            None => self.name.clone(),
        }
    }
}

/// A worktree that was just made, and what could not be copied into it.
#[derive(Clone, Debug, uniffi::Record)]
pub struct NewWorktree {
    pub path: PathBuf,
    pub warnings: Vec<String>,
}

/// Runs git in `dir` and returns its trimmed output. On failure the error
/// is git's own message, e.g. `fatal: ...`.
fn git(dir: &Path, args: &[&str]) -> Result<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .context("could not run git")?;
    if !out.status.success() {
        let msg = String::from_utf8_lossy(&out.stderr).trim().to_string();
        if msg.is_empty() {
            bail!("git {} failed", args.join(" "));
        }
        bail!(msg);
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim_end().to_string())
}

/// The worktrees of the repo `dir` is in, main first. None outside a repo.
pub fn list(dir: &Path) -> Option<Vec<Worktree>> {
    let out = git(dir, &["worktree", "list", "--porcelain"]).ok()?;
    let list = parse(&out);
    (!list.is_empty()).then_some(list)
}

fn parse(porcelain: &str) -> Vec<Worktree> {
    let mut list: Vec<Worktree> = Vec::new();
    for block in porcelain.split("\n\n") {
        let mut wt = Worktree {
            path: PathBuf::new(),
            branch: None,
            head: String::new(),
            is_main: list.is_empty(),
            bare: false,
            locked: false,
            missing: false,
        };
        for line in block.lines() {
            let (key, val) = line.split_once(' ').unwrap_or((line, ""));
            match key {
                "worktree" => wt.path = PathBuf::from(val),
                "HEAD" => wt.head = val.to_string(),
                "branch" => wt.branch = Some(val.trim_start_matches("refs/heads/").to_string()),
                "bare" => wt.bare = true,
                "locked" => wt.locked = true,
                "prunable" => wt.missing = true,
                _ => {}
            }
        }
        if !wt.path.as_os_str().is_empty() {
            list.push(wt);
        }
    }
    list
}

/// Local branches, then remote branches that have no local branch of the
/// same name. Each group is sorted by name.
pub fn branches(dir: &Path) -> Result<Vec<Branch>> {
    let local: Vec<String> = lines(&git(
        dir,
        &[
            "for-each-ref",
            "--sort=refname",
            "--format=%(refname:short)",
            "refs/heads",
        ],
    )?);
    let remotes = lines(&git(dir, &["remote"])?);
    let mut branches: Vec<Branch> = local
        .iter()
        .map(|name| Branch {
            name: name.clone(),
            remote: None,
        })
        .collect();
    for full in lines(&git(
        dir,
        &[
            "for-each-ref",
            "--sort=refname",
            "--format=%(refname)",
            "refs/remotes",
        ],
    )?) {
        let rest = full.trim_start_matches("refs/remotes/");
        // The longest match, since remote names may contain slashes.
        let Some(remote) = remotes
            .iter()
            .filter(|r| rest.starts_with(&format!("{r}/")))
            .max_by_key(|r| r.len())
        else {
            continue;
        };
        let name = &rest[remote.len() + 1..];
        if name == "HEAD" || local.iter().any(|l| l == name) {
            continue;
        }
        branches.push(Branch {
            name: name.to_string(),
            remote: Some(remote.clone()),
        });
    }
    Ok(branches)
}

fn lines(s: &str) -> Vec<String> {
    s.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect()
}

/// Where a new worktree for `branch` goes, for a repo whose main checkout
/// is `main`: `~/src/app` → `~/src/app.worktrees/feature-x`, with `-2`,
/// `-3`, ... when that folder is taken.
pub fn new_path(main: &Path, branch: &str) -> PathBuf {
    let repo = main
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let repo = repo.strip_suffix(".git").unwrap_or(&repo);
    let parent = main.parent().unwrap_or(main);
    let base = parent
        .join(format!("{repo}.worktrees"))
        .join(branch.replace('/', "-"));
    let mut path = base.clone();
    let mut i = 2;
    while path.symlink_metadata().is_ok() {
        path = PathBuf::from(format!("{}-{i}", base.display()));
        i += 1;
    }
    path
}

/// A short name for where `dir` is: the repo's name in its main checkout
/// or a subfolder of it, `repo/worktree` in a linked worktree, and the
/// folder's own name outside a repo. It reads the `.git` files instead of
/// running git, so it is cheap enough for every row of the list.
pub fn place(dir: &Path) -> String {
    for top in dir.ancestors() {
        let dot = top.join(".git");
        let Ok(meta) = fs::metadata(&dot) else {
            continue;
        };
        if meta.is_file()
            && let Some(main) = main_of_linked(top, &dot)
        {
            return format!("{}/{}", repo_name(&main), name(top));
        }
        return repo_name(top);
    }
    name(dir)
}

/// The main checkout (or the bare repo) of the linked worktree at `top`,
/// whose `.git` file says `gitdir: <repo>/.git/worktrees/<name>`. None for
/// other `.git` files, e.g. a submodule's.
fn main_of_linked(top: &Path, dot: &Path) -> Option<PathBuf> {
    let text = fs::read_to_string(dot).ok()?;
    let gitdir = top.join(text.trim().strip_prefix("gitdir:")?.trim());
    // Only linked worktrees point back to the shared `.git`.
    let common = fs::read_to_string(gitdir.join("commondir")).ok()?;
    let common = gitdir.join(common.trim()).canonicalize().ok()?;
    if common.file_name()? == ".git" {
        common.parent().map(Path::to_path_buf)
    } else {
        Some(common)
    }
}

/// `app` for `~/src/app`, and for a bare `~/src/app.git`.
fn repo_name(path: &Path) -> String {
    let n = name(path);
    n.strip_suffix(".git").map_or(n.clone(), String::from)
}

fn name(path: &Path) -> String {
    path.file_name().map_or_else(
        || path.display().to_string(),
        |n| n.to_string_lossy().into_owned(),
    )
}

fn open(dir: &Path) -> Result<Vec<Worktree>> {
    list(dir).with_context(|| format!("{} is not in a git repo", dir.display()))
}

/// Checks out an existing branch in a new worktree: a local one, or a
/// remote-only one (`x` or `origin/x`) as a new local tracking branch.
pub fn add(dir: &Path, branch: &str) -> Result<NewWorktree> {
    let wts = open(dir)?;
    let main = &wts[0];
    let all = branches(dir)?;
    let b = all
        .iter()
        .find(|b| b.remote.is_none() && b.name == branch)
        .or_else(|| all.iter().find(|b| b.git_ref() == branch))
        .or_else(|| all.iter().find(|b| b.name == branch))
        .with_context(|| format!("no branch named {branch}"))?;
    if b.remote.is_none()
        && let Some(wt) = wts.iter().find(|w| w.branch.as_deref() == Some(&b.name))
    {
        bail!("{} is already checked out in {}", b.name, wt.path.display());
    }
    let path = new_path(&main.path, &b.name);
    let p = path.to_string_lossy();
    let git_ref = b.git_ref();
    let args: Vec<&str> = if b.remote.is_some() {
        vec!["worktree", "add", "--track", "-b", &b.name, &p, &git_ref]
    } else {
        vec!["worktree", "add", &p, &b.name]
    };
    create(&wts, main, &path, &args)
}

/// Makes `new_branch` from the commit checked out in the worktree `from`,
/// in a new worktree. With `changes`, uncommitted changes and untracked
/// files are copied too; `from` itself is not changed.
pub fn fork(from: &Path, new_branch: &str, changes: bool) -> Result<NewWorktree> {
    let wts = open(from)?;
    let name = new_branch.trim();
    if name.is_empty() {
        bail!("A branch name is needed");
    }
    if git(from, &["check-ref-format", "--branch", name]).is_err() {
        bail!("{name} is not a valid branch name");
    }
    if git(
        from,
        &[
            "show-ref",
            "--verify",
            "--quiet",
            &format!("refs/heads/{name}"),
        ],
    )
    .is_ok()
    {
        bail!("A branch named {name} already exists");
    }
    let src = wts
        .iter()
        .find(|w| {
            w.path == from
                || w.path.canonicalize().ok().as_deref() == from.canonicalize().ok().as_deref()
        })
        .with_context(|| format!("{} is not the top of a worktree", from.display()))?;
    if src.bare {
        bail!("Cannot start from a bare repo");
    }
    if src.missing {
        bail!("The folder of {} is gone", src.path.display());
    }
    // A detached worktree starts from its commit.
    let start = src.branch.clone().unwrap_or_else(|| src.head.clone());
    let path = new_path(&wts[0].path, name);
    let p = path.to_string_lossy();
    let mut made = create(
        &wts,
        src,
        &path,
        &["worktree", "add", "-b", name, &p, &start],
    )?;
    if changes {
        carry_changes(&wts, src, &mut made);
    }
    Ok(made)
}

/// True if the worktree has uncommitted changes or untracked files.
pub fn has_changes(dir: &Path) -> bool {
    git(dir, &["status", "--porcelain"]).is_ok_and(|s| !s.is_empty())
}

/// Runs `git worktree add`, then copies ignored files from `src`.
fn create(wts: &[Worktree], src: &Worktree, path: &Path, args: &[&str]) -> Result<NewWorktree> {
    git(&wts[0].path, args)?;
    let mut made = NewWorktree {
        path: path.to_path_buf(),
        warnings: Vec::new(),
    };
    // A bare repo has no files to copy.
    if !src.bare {
        let others = others(wts, src, path);
        made.warnings = copy_others(&src.path, path, &others, true);
    }
    Ok(made)
}

/// Worktrees an ignored folder of `src` must not contain, or we would copy
/// worktrees into each other.
fn others(wts: &[Worktree], src: &Worktree, path: &Path) -> Vec<PathBuf> {
    let mut others = vec![path.to_path_buf()];
    others.extend(
        wts.iter()
            .filter(|w| w.path != src.path)
            .map(|w| w.path.clone()),
    );
    others
}

/// Copies uncommitted changes from `src` into the new worktree, which is on
/// the same commit. Changes to tracked files go through `git stash create`,
/// which neither touches `src` nor adds to `git stash list`. Staged changes
/// stay staged. Untracked files are copied.
fn carry_changes(wts: &[Worktree], src: &Worktree, made: &mut NewWorktree) {
    match git(&src.path, &["stash", "create"]) {
        Err(e) => made
            .warnings
            .push(format!("Could not read uncommitted changes: {e:#}")),
        Ok(stash) if !stash.is_empty() => {
            if let Err(e) = git(&made.path, &["stash", "apply", "--index", &stash]) {
                made.warnings
                    .push(format!("Could not carry over uncommitted changes: {e:#}"));
            }
        }
        Ok(_) => {}
    }
    let others = others(wts, src, &made.path);
    let warnings = copy_others(&src.path, &made.path, &others, false);
    made.warnings.extend(warnings);
}

/// Copies what `git ls-files --others` lists in `src` into `dst`: ignored
/// files with `ignored`, else untracked ones. Skips paths that already
/// exist in `dst` and folders that hold one of `others`. Returns what
/// failed.
fn copy_others(src: &Path, dst: &Path, others: &[PathBuf], ignored: bool) -> Vec<String> {
    let mut args = vec![
        "ls-files",
        "--others",
        "--exclude-standard",
        "--directory",
        "-z",
    ];
    if ignored {
        args.push("--ignored");
    }
    let out = match git(src, &args) {
        Ok(out) => out,
        Err(e) => return vec![format!("{e:#}")],
    };
    let mut failed = Vec::new();
    for entry in out.split('\0') {
        let entry = entry.trim_end_matches('/');
        if entry.is_empty() {
            continue;
        }
        let from = src.join(entry);
        let to = dst.join(entry);
        if others.iter().any(|o| o.starts_with(&from)) || to.symlink_metadata().is_ok() {
            continue;
        }
        let copied = to
            .parent()
            .map_or(Ok(()), fs::create_dir_all)
            .map_err(anyhow::Error::from)
            .and_then(|()| copy_path(&from, &to));
        if let Err(e) = copied {
            failed.push(format!("Could not copy {entry}: {e:#}"));
        }
    }
    failed
}

/// Copies a file, symlink or whole folder: a clone where the file system
/// can (APFS), else `cp`.
fn copy_path(from: &Path, to: &Path) -> Result<()> {
    if clone(from, to) {
        return Ok(());
    }
    // A failed clone may leave a partial copy behind.
    let _ = fs::remove_dir_all(to).or_else(|_| fs::remove_file(to));
    let out = Command::new("cp").arg("-pR").arg(from).arg(to).output()?;
    if !out.status.success() {
        bail!("{}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn clone(from: &Path, to: &Path) -> bool {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    // From <sys/clonefile.h>: don't follow a symlink, clone it.
    const CLONE_NOFOLLOW: u32 = 1;
    let (Ok(from), Ok(to)) = (
        CString::new(from.as_os_str().as_bytes()),
        CString::new(to.as_os_str().as_bytes()),
    ) else {
        return false;
    };
    // SAFETY: both are valid C strings for the duration of the call.
    unsafe { libc::clonefile(from.as_ptr(), to.as_ptr(), CLONE_NOFOLLOW) == 0 }
}

#[cfg(not(target_os = "macos"))]
fn clone(_: &Path, _: &Path) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(dir: &Path, args: &[&str]) -> String {
        git(dir, args).unwrap_or_else(|e| panic!("git {args:?}: {e:#}"))
    }

    fn repo() -> PathBuf {
        let base = std::env::temp_dir().join(format!("agentz-wt-{}", uuid::Uuid::new_v4()));
        let dir = base.join("app");
        fs::create_dir_all(&dir).unwrap();
        let dir = dir.canonicalize().unwrap();
        run(&dir, &["init", "-q", "-b", "main"]);
        run(&dir, &["config", "user.email", "t@t"]);
        run(&dir, &["config", "user.name", "t"]);
        fs::write(dir.join(".gitignore"), ".env\nnode_modules/\n").unwrap();
        fs::write(dir.join("a.txt"), "a\n").unwrap();
        run(&dir, &["add", "."]);
        run(&dir, &["commit", "-q", "-m", "first"]);
        fs::write(dir.join(".env"), "SECRET=1\n").unwrap();
        fs::create_dir_all(dir.join("node_modules/x")).unwrap();
        fs::write(dir.join("node_modules/x/i.js"), "x\n").unwrap();
        dir
    }

    #[test]
    fn parses_porcelain() {
        let out = "worktree /r\nHEAD abc\nbranch refs/heads/main\n\nworktree /r.worktrees/x\nHEAD def\ndetached\nlocked\n\nworktree /gone\nHEAD 123\nbranch refs/heads/feature/y\nprunable gitdir file points to non-existent location\n";
        let list = parse(out);
        assert_eq!(list.len(), 3);
        assert!(list[0].is_main);
        assert_eq!(list[0].branch.as_deref(), Some("main"));
        assert!(!list[1].is_main);
        assert_eq!(list[1].branch, None);
        assert!(list[1].locked);
        assert_eq!(list[2].branch.as_deref(), Some("feature/y"));
        assert!(list[2].missing);
    }

    #[test]
    fn new_path_goes_next_to_the_repo() {
        let dir = repo();
        let path = new_path(&dir, "feature/x");
        assert_eq!(path, dir.parent().unwrap().join("app.worktrees/feature-x"));
        fs::create_dir_all(&path).unwrap();
        assert_eq!(
            new_path(&dir, "feature/x"),
            dir.parent().unwrap().join("app.worktrees/feature-x-2")
        );
        fs::remove_dir_all(dir.parent().unwrap()).unwrap();
    }

    #[test]
    fn place_names_repo_and_worktree() {
        let dir = repo();
        fs::create_dir_all(dir.join("src/deep")).unwrap();
        assert_eq!(place(&dir), "app");
        assert_eq!(place(&dir.join("src/deep")), "app");

        let made = fork(&dir, "feature/x", false).unwrap();
        fs::create_dir_all(made.path.join("src")).unwrap();
        assert_eq!(place(&made.path), "app/feature-x");
        assert_eq!(place(&made.path.join("src")), "app/feature-x");

        let outside = dir.parent().unwrap().join("plain");
        fs::create_dir_all(&outside).unwrap();
        assert_eq!(place(&outside), "plain");
        fs::remove_dir_all(dir.parent().unwrap()).unwrap();
    }

    #[test]
    fn fork_and_add() {
        let dir = repo();
        fs::write(dir.join("a.txt"), "changed\n").unwrap();
        fs::write(dir.join("new.txt"), "new\n").unwrap();
        assert!(has_changes(&dir));

        let made = fork(&dir, "feature/x", true).unwrap();
        assert!(made.warnings.is_empty(), "{:?}", made.warnings);
        assert_eq!(
            fs::read_to_string(made.path.join(".env")).unwrap(),
            "SECRET=1\n"
        );
        assert!(made.path.join("node_modules/x/i.js").exists());
        assert_eq!(
            fs::read_to_string(made.path.join("a.txt")).unwrap(),
            "changed\n"
        );
        assert!(made.path.join("new.txt").exists());
        // The source is left as it was.
        assert_eq!(fs::read_to_string(dir.join("a.txt")).unwrap(), "changed\n");
        assert_eq!(run(&dir, &["stash", "list"]), "");

        assert!(fork(&dir, "feature/x", false).is_err(), "branch exists");
        assert!(fork(&dir, "bad..name", false).is_err());

        let wts = list(&dir).unwrap();
        assert_eq!(wts.len(), 2);
        assert_eq!(wts[1].branch.as_deref(), Some("feature/x"));

        // A free branch can be checked out; a busy one can't.
        run(&dir, &["branch", "free"]);
        let b = branches(&dir).unwrap();
        assert!(b.iter().any(|b| b.name == "free" && b.remote.is_none()));
        let added = add(&dir, "free").unwrap();
        assert!(added.path.ends_with("app.worktrees/free"));
        assert!(added.path.join(".env").exists());
        assert!(
            add(&dir, "main")
                .unwrap_err()
                .to_string()
                .contains("already checked out")
        );
        fs::remove_dir_all(dir.parent().unwrap()).unwrap();
    }
}
