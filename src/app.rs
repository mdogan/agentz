use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

use crossterm::event::{
    Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use portable_pty::CommandBuilder;
use ratatui::Frame;
use ratatui::layout::{Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::AppEvent;
use crate::project::{self, Project};
use crate::sessions::{Agent, Session, SessionKey};
use crate::term::{self, Term};

const SIDEBAR_WIDTH: u16 = 42;
const MIN_SIDEBAR_WIDTH: u16 = 20;
const MIN_PANE_WIDTH: u16 = 20;
/// Lines per session in the list: two lines of text and a blank gap.
const ROW_HEIGHT: u16 = 3;
/// The UI colors. The light set is used when the outer terminal reports a
/// light background.
struct Theme {
    claude: Color,
    codex: Color,
    shell: Color,
    accent: Color,
    muted: Color,
    /// Status messages and the busy spinner.
    warn: Color,
    separator: Color,
    folder: Color,
    cursor_bg: Color,
    cursor_bg_unfocused: Color,
    header_bg: Color,
    header_bg_unfocused: Color,
}

const DARK: Theme = Theme {
    claude: Color::Rgb(217, 119, 87),
    codex: Color::Rgb(120, 160, 255),
    shell: Color::Rgb(190, 190, 200),
    accent: Color::Rgb(120, 200, 140),
    muted: Color::Rgb(120, 120, 130),
    warn: Color::Yellow,
    separator: Color::Rgb(60, 60, 70),
    folder: Color::Rgb(160, 160, 175),
    cursor_bg: Color::Rgb(45, 50, 65),
    cursor_bg_unfocused: Color::Rgb(35, 37, 45),
    header_bg: Color::Rgb(40, 44, 58),
    header_bg_unfocused: Color::Rgb(30, 30, 36),
};

const LIGHT: Theme = Theme {
    claude: Color::Rgb(190, 85, 50),
    codex: Color::Rgb(45, 95, 215),
    shell: Color::Rgb(85, 85, 100),
    accent: Color::Rgb(25, 135, 65),
    muted: Color::Rgb(115, 115, 125),
    warn: Color::Rgb(165, 105, 0),
    separator: Color::Rgb(200, 200, 210),
    folder: Color::Rgb(80, 80, 95),
    cursor_bg: Color::Rgb(215, 222, 240),
    cursor_bg_unfocused: Color::Rgb(230, 232, 238),
    header_bg: Color::Rgb(218, 223, 238),
    header_bg_unfocused: Color::Rgb(234, 234, 238),
};

fn theme() -> &'static Theme {
    static THEME: OnceLock<&Theme> = OnceLock::new();
    THEME.get_or_init(|| {
        if term::light_background() {
            &LIGHT
        } else {
            &DARK
        }
    })
}

const SPINNER: [&str; 4] = ["◐", "◓", "◑", "◒"];

#[derive(PartialEq, Eq, Clone, Copy)]
enum Focus {
    Sidebar,
    Terminal,
}

/// An agent process we started, keyed by the session it belongs to.
struct Running {
    key: SessionKey,
    term: Term,
    cwd: PathBuf,
    spawned_at: SystemTime,
    fallback_title: String,
    /// A shell we opened by ourselves after an agent quit, and that the user
    /// has not typed into yet. It is closed when the user switches away.
    placeholder: bool,
    /// For a shell: the session of the agent the user started inside it.
    linked: Option<SessionKey>,
}

impl Running {
    /// True if this process shows `key`: its own session, or the session of
    /// the agent running inside it.
    fn is(&self, key: &SessionKey) -> bool {
        &self.key == key || self.linked.as_ref() == Some(key)
    }
}

/// One row in the sidebar.
struct Row {
    key: SessionKey,
    title: String,
    cwd: PathBuf,
    updated: SystemTime,
}

pub struct App {
    sessions: Vec<Session>,
    loaded: bool,
    project: Option<Project>,
    /// Show sessions from other repos too (`a`).
    all_repos: bool,
    /// Show only sessions with a running agent or shell (`i`).
    hide_inactive: bool,
    running: Vec<Running>,
    rows: Vec<Row>,
    cursor: usize,
    cursor_key: Option<SessionKey>,
    list_offset: usize,
    current: Option<SessionKey>,
    focus: Focus,
    /// False while the outer terminal window is in the background.
    window_focused: bool,
    filter: String,
    filtering: bool,
    status: Option<(String, Instant)>,
    confirm_quit: bool,
    /// Sidebar width the user picked by dragging the separator.
    sidebar_width: u16,
    /// True while the user drags the separator.
    resizing: bool,
    sidebar: Rect,
    list_area: Rect,
    pane: Rect,
    events: Sender<AppEvent>,
    redraw: Arc<AtomicBool>,
    /// Pids of our running shells, read by the session scanner.
    shell_pids: Arc<Mutex<Vec<u32>>>,
    next_term_id: u64,
    next_new_id: u64,
    /// Where new sessions start: the project root, see `project::root_of`.
    root: PathBuf,
    started: Instant,
    pub quit: bool,
}

impl App {
    pub fn new(
        events: Sender<AppEvent>,
        redraw: Arc<AtomicBool>,
        shell_pids: Arc<Mutex<Vec<u32>>>,
    ) -> Self {
        App {
            sessions: Vec::new(),
            loaded: false,
            project: None,
            all_repos: false,
            hide_inactive: false,
            running: Vec::new(),
            rows: Vec::new(),
            cursor: 0,
            cursor_key: None,
            list_offset: 0,
            current: None,
            focus: Focus::Sidebar,
            window_focused: true,
            filter: String::new(),
            filtering: false,
            status: None,
            confirm_quit: false,
            sidebar_width: SIDEBAR_WIDTH,
            resizing: false,
            sidebar: Rect::default(),
            list_area: Rect::default(),
            pane: Rect::default(),
            events,
            redraw,
            shell_pids,
            next_term_id: 1,
            next_new_id: 1,
            root: project::root_of(&std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))),
            started: Instant::now(),
            quit: false,
        }
    }

    /// Gives every terminal the output its agent printed since last time.
    pub fn pump(&self) {
        for r in &self.running {
            r.term.pump();
        }
    }

    /// True while the shown agent is in the middle of drawing a frame.
    pub fn current_synchronized(&self) -> bool {
        self.current_running()
            .is_some_and(|r| r.term.synchronized())
    }

    /// Agents that just finished working while the user was not looking at
    /// them, as (agent, session title). Looking means the window is focused
    /// and the agent is the one shown in the pane.
    pub fn finished_unseen(&mut self) -> Vec<(Agent, String)> {
        let mut done = Vec::new();
        for r in &mut self.running {
            // Poll every process so each one's busy state stays current.
            if !r.term.finished_work() {
                continue;
            }
            if self.window_focused && self.current.as_ref() == Some(&r.key) {
                continue;
            }
            // A plain shell only counts while an agent runs inside it.
            let key = if r.key.0 == Agent::Shell {
                r.linked.as_ref()
            } else {
                Some(&r.key)
            };
            let Some(key) = key else {
                continue;
            };
            let title = self
                .sessions
                .iter()
                .find(|s| &s.key() == key)
                .map_or_else(|| r.fallback_title.clone(), |s| s.title.clone());
            done.push((key.0, title));
        }
        done
    }

    pub fn handle(&mut self, ev: AppEvent) {
        match ev {
            AppEvent::Input(e) => self.on_input(e),
            AppEvent::Redraw => return,
            AppEvent::Exited(id) => {
                let Some(i) = self.running.iter().position(|r| r.term.id == id) else {
                    return;
                };
                self.running[i].term.mark_exited();
                let key = self.running[i].key.clone();
                if self.current.as_ref() != Some(&key) {
                    self.running.remove(i);
                    self.rebuild_rows();
                } else if key.0 == Agent::Shell {
                    // Like closing a terminal tab.
                    self.running.remove(i);
                    self.current = None;
                    self.focus = Focus::Sidebar;
                    self.rebuild_rows();
                } else {
                    self.replace_with_shell(i);
                }
            }
            AppEvent::Sessions(list, project, links) => {
                self.sessions = list;
                self.project = Some(project);
                self.loaded = true;
                self.link_shells(&links);
                self.bind_new_codex_sessions();
                self.rebuild_rows();
            }
        }
        *self.shell_pids.lock().unwrap() = self
            .running
            .iter()
            .filter(|r| r.key.0 == Agent::Shell && r.term.is_running())
            .filter_map(|r| r.term.pid)
            .collect();
    }

    // ---------- sessions & rows ----------

    /// Attaches each shell to the session of the agent the user started in
    /// it, so that session's row opens the shell instead of a second copy.
    fn link_shells(&mut self, links: &[(u32, SessionKey)]) {
        for r in &mut self.running {
            if r.key.0 != Agent::Shell {
                continue;
            }
            let linked = links
                .iter()
                .find(|(pid, _)| Some(*pid) == r.term.pid)
                .map(|(_, key)| key.clone());
            if linked.is_some() {
                // The shell's row is about to be hidden behind the session's.
                if self.cursor_key.as_ref() == Some(&r.key) {
                    self.cursor_key = linked.clone();
                }
                r.placeholder = false;
            } else if let Some(old) = &r.linked
                && self.cursor_key.as_ref() == Some(old)
            {
                self.cursor_key = Some(r.key.clone());
            }
            r.linked = linked;
        }
    }

    /// Codex does not let us choose the id of a new session. Once its
    /// transcript shows up, attach it to the process we started.
    fn bind_new_codex_sessions(&mut self) {
        for i in 0..self.running.len() {
            let r = &self.running[i];
            if r.key.0 != Agent::Codex || !r.key.1.starts_with("new-") {
                continue;
            }
            let since = r.spawned_at - Duration::from_secs(5);
            let found = self
                .sessions
                .iter()
                .filter(|s| s.agent == Agent::Codex && s.cwd == r.cwd && s.created >= since)
                .filter(|s| !self.running.iter().any(|o| o.is(&s.key())))
                .min_by_key(|s| s.created)
                .map(|s| s.key());
            if let Some(key) = found {
                let old = std::mem::replace(&mut self.running[i].key, key.clone());
                if self.current.as_ref() == Some(&old) {
                    self.current = Some(key.clone());
                }
                if self.cursor_key.as_ref() == Some(&old) {
                    self.cursor_key = Some(key);
                }
            }
        }
    }

    fn rebuild_rows(&mut self) {
        let mut rows: Vec<Row> = self
            .sessions
            .iter()
            .map(|s| Row {
                key: s.key(),
                title: s.title.clone(),
                cwd: s.cwd.clone(),
                updated: s.updated,
            })
            .collect();
        // Sessions we started that have no transcript yet, and shells. A
        // shell running an agent is shown as that agent's session.
        for r in &self.running {
            if !rows.iter().any(|row| r.is(&row.key)) {
                rows.push(Row {
                    key: r.key.clone(),
                    title: r.fallback_title.clone(),
                    cwd: r.cwd.clone(),
                    updated: r.spawned_at,
                });
            }
        }
        // Rows with a process of ours stay visible either way, so a running
        // agent can't get lost behind a hidden row.
        rows.retain(|row| {
            let active = self.running.iter().any(|r| r.is(&row.key));
            let in_project =
                self.all_repos || self.project.as_ref().is_none_or(|p| p.contains(&row.cwd));
            active || (in_project && !self.hide_inactive)
        });
        if !self.filter.is_empty() {
            let q = self.filter.to_lowercase();
            rows.retain(|row| {
                row.title.to_lowercase().contains(&q)
                    || row.cwd.to_string_lossy().to_lowercase().contains(&q)
                    || row.key.0.name().contains(&q)
            });
        }
        rows.sort_by_key(|r| std::cmp::Reverse(r.updated));
        self.rows = rows;

        // Keep the cursor on the same session even if the order changed.
        self.cursor = self
            .cursor_key
            .as_ref()
            .and_then(|k| self.rows.iter().position(|r| &r.key == k))
            .unwrap_or(self.cursor.min(self.rows.len().saturating_sub(1)));
        self.cursor_key = self.rows.get(self.cursor).map(|r| r.key.clone());
    }

    fn move_cursor(&mut self, delta: isize) {
        if self.rows.is_empty() {
            return;
        }
        let max = self.rows.len() as isize - 1;
        self.cursor = (self.cursor as isize + delta).clamp(0, max) as usize;
        self.cursor_key = Some(self.rows[self.cursor].key.clone());
    }

    fn current_running(&self) -> Option<&Running> {
        let key = self.current.as_ref()?;
        self.running.iter().find(|r| &r.key == key)
    }

    fn current_running_mut(&mut self) -> Option<&mut Running> {
        let key = self.current.as_ref()?;
        self.running.iter_mut().find(|r| &r.key == key)
    }

    fn set_status(&mut self, msg: impl Into<String>) {
        self.status = Some((msg.into(), Instant::now()));
    }

    // ---------- starting and switching ----------

    /// Shows the session. If its agent is already running we just switch to
    /// it; otherwise we resume it in a new PTY.
    fn open(&mut self, key: SessionKey) {
        self.prune(Some(&key));

        if let Some(i) = self.running.iter().position(|r| r.is(&key)) {
            if self.running[i].term.is_running() {
                self.current = Some(self.running[i].key.clone());
                self.focus = Focus::Terminal;
                return;
            }
            self.running.remove(i);
        }

        let Some(row) = self.rows.iter().find(|r| r.key == key) else {
            return;
        };
        let (cwd, title) = (row.cwd.clone(), row.title.clone());
        if key.1.starts_with("new-") {
            // A Codex session that never got a transcript; start fresh.
            self.start(key.0, None, cwd, title);
        } else {
            self.start(key.0, Some(key.1.clone()), cwd, title);
        }
    }

    fn new_session(&mut self, agent: Agent) {
        self.prune(None);
        let cwd = self.root.clone();
        let title = match agent {
            Agent::Shell => shell_name(),
            _ => format!("New {} session", agent.name()),
        };
        self.start(agent, None, cwd, title);
    }

    /// Finished processes are only kept around so their last output stays
    /// visible, and placeholder shells only until the user moves on. Drops
    /// both, except `keep`.
    fn prune(&mut self, keep: Option<&SessionKey>) {
        self.running
            .retain(|r| keep.is_some_and(|k| r.is(k)) || (r.term.is_running() && !r.placeholder));
    }

    /// The shown agent quit. Puts a fresh shell in its place, in the same
    /// folder, so the user can start `claude` or `codex` by hand.
    fn replace_with_shell(&mut self, i: usize) {
        let r = &self.running[i];
        let (key, cwd, code) = (r.key.clone(), r.cwd.clone(), r.term.exit_code);
        let focus = self.focus;
        if !self.start(Agent::Shell, None, cwd, shell_name()) {
            // Keep the agent's last screen; Enter resumes it.
            return;
        }
        if let Some(shell) = self.running.last_mut() {
            shell.placeholder = true;
        }
        self.running.retain(|r| r.key != key);
        self.focus = focus;
        self.rebuild_rows();
        if let Some(code) = code.filter(|c| *c != 0) {
            self.set_status(format!("{} exited ({code})", key.0.name()));
        }
    }

    /// Spawns an agent or shell. `resume` is the session id to resume, or
    /// `None` for a new session. Returns false if it could not start.
    fn start(&mut self, agent: Agent, resume: Option<String>, cwd: PathBuf, title: String) -> bool {
        if !cwd.is_dir() {
            self.set_status(format!("Folder no longer exists: {}", cwd.display()));
            return false;
        }
        let (key, args): (SessionKey, Vec<String>) = match (agent, resume) {
            (Agent::Claude, Some(id)) => ((agent, id.clone()), vec!["--resume".into(), id]),
            (Agent::Claude, None) => {
                let id = uuid::Uuid::new_v4().to_string();
                ((agent, id.clone()), vec!["--session-id".into(), id])
            }
            (Agent::Codex, Some(id)) => ((agent, id.clone()), vec!["resume".into(), id]),
            (Agent::Codex, None) => {
                let id = format!("new-{}", self.next_new_id);
                self.next_new_id += 1;
                ((agent, id), vec![])
            }
            (Agent::Shell, _) => {
                let id = format!("shell-{}", self.next_new_id);
                self.next_new_id += 1;
                ((agent, id), vec![])
            }
        };

        let cmd = build_command(agent, &args, &cwd);
        let (rows, cols) = self.term_size();
        let id = self.next_term_id;
        self.next_term_id += 1;
        match Term::spawn(
            id,
            cmd,
            rows,
            cols,
            self.events.clone(),
            self.redraw.clone(),
        ) {
            Ok(term) => {
                self.running.push(Running {
                    key: key.clone(),
                    term,
                    cwd,
                    spawned_at: SystemTime::now(),
                    fallback_title: title,
                    placeholder: false,
                    linked: None,
                });
                self.current = Some(key.clone());
                self.cursor_key = Some(key);
                self.focus = Focus::Terminal;
                self.rebuild_rows();
                true
            }
            Err(e) => {
                self.set_status(format!("Could not start {}: {e:#}", agent.name()));
                false
            }
        }
    }

    fn stop(&mut self, key: &SessionKey) {
        if let Some(r) = self.running.iter_mut().find(|r| r.is(key)) {
            r.term.kill();
        }
    }

    fn term_size(&self) -> (u16, u16) {
        let area = pane_body(self.pane);
        if area.height == 0 {
            (24, 80)
        } else {
            (area.height, area.width)
        }
    }

    // ---------- input ----------

    fn on_input(&mut self, ev: Event) {
        match ev {
            Event::Key(k) if k.kind != KeyEventKind::Release => self.on_key(k),
            Event::Paste(text) => {
                if self.filtering {
                    self.filter.push_str(&text);
                    self.rebuild_rows();
                } else if self.focus == Focus::Terminal
                    && let Some(r) = self.current_running_mut()
                {
                    r.placeholder = false;
                    r.term.paste(&text);
                }
            }
            Event::Mouse(m) => self.on_mouse(m),
            Event::FocusGained => self.window_focused = true,
            Event::FocusLost => self.window_focused = false,
            _ => {}
        }
    }

    fn on_key(&mut self, k: KeyEvent) {
        // Ctrl+\ always toggles between the list and the agent. Legacy
        // terminals report it as Ctrl+4.
        let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
        if ctrl && matches!(k.code, KeyCode::Char('\\') | KeyCode::Char('4')) {
            self.focus = match self.focus {
                Focus::Terminal => Focus::Sidebar,
                Focus::Sidebar if self.current_running().is_some() => Focus::Terminal,
                Focus::Sidebar => Focus::Sidebar,
            };
            return;
        }
        match self.focus {
            Focus::Terminal => self.on_terminal_key(k),
            Focus::Sidebar if self.filtering => self.on_filter_key(k),
            Focus::Sidebar => self.on_sidebar_key(k),
        }
    }

    fn on_terminal_key(&mut self, k: KeyEvent) {
        let Some(r) = self.current_running_mut() else {
            self.focus = Focus::Sidebar;
            return;
        };
        if r.term.is_running() {
            r.placeholder = false;
            r.term.send_key(k);
        } else if k.code == KeyCode::Enter {
            let key = r.key.clone();
            self.open(key);
        } else if k.code == KeyCode::Esc {
            self.focus = Focus::Sidebar;
        }
    }

    fn on_filter_key(&mut self, k: KeyEvent) {
        match k.code {
            KeyCode::Esc => {
                self.filtering = false;
                self.filter.clear();
            }
            KeyCode::Enter => self.filtering = false,
            KeyCode::Backspace => {
                self.filter.pop();
            }
            KeyCode::Up => self.move_cursor(-1),
            KeyCode::Down => self.move_cursor(1),
            KeyCode::Char(c) if !k.modifiers.contains(KeyModifiers::CONTROL) => self.filter.push(c),
            _ => return,
        }
        self.cursor = 0;
        self.cursor_key = None;
        self.rebuild_rows();
    }

    fn on_sidebar_key(&mut self, k: KeyEvent) {
        let page = (self.list_area.height / ROW_HEIGHT).max(1) as isize;
        if k.code != KeyCode::Char('q') {
            self.confirm_quit = false;
        }
        match k.code {
            KeyCode::Up | KeyCode::Char('k') => self.move_cursor(-1),
            KeyCode::Down | KeyCode::Char('j') => self.move_cursor(1),
            KeyCode::PageUp => self.move_cursor(-page),
            KeyCode::PageDown => self.move_cursor(page),
            KeyCode::Home | KeyCode::Char('g') => self.move_cursor(-(self.rows.len() as isize)),
            KeyCode::End | KeyCode::Char('G') => self.move_cursor(self.rows.len() as isize),
            KeyCode::Enter | KeyCode::Right | KeyCode::Char('l') => {
                if let Some(key) = self.cursor_key.clone() {
                    self.open(key);
                }
            }
            KeyCode::Esc => {
                if !self.filter.is_empty() {
                    self.filter.clear();
                    self.rebuild_rows();
                } else if self.current_running().is_some() {
                    self.focus = Focus::Terminal;
                }
            }
            KeyCode::Char('/') => self.filtering = true,
            KeyCode::Char('n') => self.new_session(Agent::Claude),
            KeyCode::Char('N') => self.new_session(Agent::Codex),
            KeyCode::Char('t') => self.new_session(Agent::Shell),
            KeyCode::Char('a') => {
                self.all_repos = !self.all_repos;
                self.rebuild_rows();
                self.set_status(if self.all_repos {
                    "Showing sessions from all repos"
                } else {
                    "Showing sessions from this repo only"
                });
            }
            KeyCode::Char('i') => {
                self.hide_inactive = !self.hide_inactive;
                self.rebuild_rows();
                self.set_status(if self.hide_inactive {
                    "Hiding inactive sessions"
                } else {
                    "Showing inactive sessions"
                });
            }
            KeyCode::Char('x') => {
                if let Some(key) = self.cursor_key.clone() {
                    self.stop(&key);
                }
            }
            KeyCode::Char('q') => {
                // Agents (also those started by hand in a shell) block quitting;
                // plain shells only need a second q.
                let live: Vec<&Running> = self
                    .running
                    .iter()
                    .filter(|r| r.term.is_running() && !r.placeholder)
                    .collect();
                let agents = live
                    .iter()
                    .filter(|r| r.key.0 != Agent::Shell || r.linked.is_some())
                    .count();
                let shells = live.len() - agents;
                if agents > 0 {
                    self.set_status(format!(
                        "{agents} agent(s) running. Stop them with x before quitting."
                    ));
                } else if shells == 0 || self.confirm_quit {
                    self.quit = true;
                } else {
                    self.confirm_quit = true;
                    self.set_status(format!(
                        "{shells} shell(s) open. Press q again to close them and quit."
                    ));
                }
            }
            _ => {}
        }
    }

    fn on_mouse(&mut self, m: MouseEvent) {
        if self.resizing {
            match m.kind {
                MouseEventKind::Drag(MouseButton::Left) => {
                    let total = self.pane.right().saturating_sub(self.sidebar.x);
                    let max = total.saturating_sub(MIN_PANE_WIDTH).max(MIN_SIDEBAR_WIDTH);
                    self.sidebar_width = (m.column + 1)
                        .saturating_sub(self.sidebar.x)
                        .clamp(MIN_SIDEBAR_WIDTH, max);
                }
                MouseEventKind::Up(_) => self.resizing = false,
                _ => {}
            }
            return;
        }
        let pos = Position::new(m.column, m.row);
        let separator = self.sidebar.x + self.sidebar.width.saturating_sub(1);
        if self.sidebar.contains(pos)
            && m.column == separator
            && m.kind == MouseEventKind::Down(MouseButton::Left)
        {
            // Start from the width on screen, which may be clamped.
            self.sidebar_width = self.sidebar.width;
            self.resizing = true;
            return;
        }
        if self.list_area.contains(pos) {
            match m.kind {
                MouseEventKind::Down(MouseButton::Left) => {
                    let dy = m.row - self.list_area.y;
                    let i = self.list_offset + (dy / ROW_HEIGHT) as usize;
                    // Clicks on the gap between sessions do nothing.
                    let on_gap = dy % ROW_HEIGHT == ROW_HEIGHT - 1;
                    if let Some(row) = self.rows.get(i).filter(|_| !on_gap) {
                        let key = row.key.clone();
                        self.cursor = i;
                        self.cursor_key = Some(key.clone());
                        self.open(key);
                    }
                }
                MouseEventKind::ScrollUp => self.move_cursor(-3),
                MouseEventKind::ScrollDown => self.move_cursor(3),
                _ => {}
            }
            return;
        }
        if self.sidebar.contains(pos) {
            if matches!(m.kind, MouseEventKind::Down(_)) {
                self.focus = Focus::Sidebar;
            }
            return;
        }
        let body = pane_body(self.pane);
        if body.contains(pos) {
            if matches!(m.kind, MouseEventKind::Down(_)) && self.current_running().is_some() {
                self.focus = Focus::Terminal;
            }
            if let Some(r) = self.current_running() {
                r.term.mouse(m, m.column - body.x, m.row - body.y);
            }
        }
    }

    // ---------- drawing ----------

    pub fn draw(&mut self, f: &mut Frame) {
        let area = f.area();
        let side_w = self
            .sidebar_width
            .min(area.width.saturating_sub(MIN_PANE_WIDTH))
            .max(MIN_SIDEBAR_WIDTH)
            .min(area.width);
        self.sidebar = Rect::new(area.x, area.y, side_w, area.height);
        self.pane = Rect::new(area.x + side_w, area.y, area.width - side_w, area.height);

        // All agents share the pane size, so switching never needs a resize.
        let body = pane_body(self.pane);
        for r in &self.running {
            r.term.resize(body.height, body.width);
        }

        self.draw_sidebar(f);
        self.draw_pane(f);
    }

    fn draw_sidebar(&mut self, f: &mut Frame) {
        let area = self.sidebar;
        if area.width < 4 || area.height < 4 {
            return;
        }
        let focused = self.focus == Focus::Sidebar;
        let inner_w = area.width - 1; // last column is the separator

        // Separator line.
        let sep_style = Style::default().fg(if focused || self.resizing {
            theme().accent
        } else {
            theme().separator
        });
        for y in area.y..area.y + area.height {
            if let Some(c) = f.buffer_mut().cell_mut((area.x + inner_w, y)) {
                c.set_symbol("│").set_style(sep_style);
            }
        }

        // Header: name and counts, or the filter input.
        let header = Rect::new(area.x, area.y, inner_w, 1);
        let header_line = if self.filtering || !self.filter.is_empty() {
            let cursor = if self.filtering { "▏" } else { "" };
            Line::from(vec![
                Span::styled(
                    " / ",
                    Style::default()
                        .fg(theme().accent)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::raw(format!("{}{cursor}", self.filter)),
            ])
        } else {
            let n_run = self.running.iter().filter(|r| r.term.is_running()).count();
            let title_style = if focused {
                Style::default()
                    .fg(theme().accent)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().add_modifier(Modifier::BOLD)
            };
            Line::from(vec![
                Span::styled(" agentz", title_style),
                Span::styled(
                    format!("  {} sessions · {n_run} running", self.rows.len()),
                    Style::default().fg(theme().muted),
                ),
            ])
        };
        f.render_widget(Paragraph::new(header_line), header);

        // Footer: status message or key hints.
        let footer_h = 3;
        let footer = Rect::new(area.x, area.y + area.height - footer_h, inner_w, footer_h);
        let status = self
            .status
            .as_ref()
            .filter(|(_, t)| t.elapsed() < Duration::from_secs(6));
        let footer_lines = if let Some((msg, _)) = status {
            vec![Line::styled(
                format!(" {msg}"),
                Style::default().fg(theme().warn),
            )]
        } else if focused {
            vec![
                hint_line(&[
                    ("↵", "open"),
                    ("n", "claude"),
                    ("N", "codex"),
                    ("/", "filter"),
                ]),
                hint_line(&[
                    ("t", "shell"),
                    ("x", "stop"),
                    ("q", "quit"),
                    ("C-\\", "agent"),
                ]),
                hint_line(&[
                    (
                        "a",
                        if self.all_repos {
                            "this repo"
                        } else {
                            "all repos"
                        },
                    ),
                    (
                        "i",
                        if self.hide_inactive {
                            "show inactive"
                        } else {
                            "hide inactive"
                        },
                    ),
                ]),
            ]
        } else {
            vec![hint_line(&[("C-\\", "sessions"), ("click", "switch")])]
        };
        f.render_widget(
            Paragraph::new(footer_lines).wrap(ratatui::widgets::Wrap { trim: false }),
            footer,
        );

        // The list, two lines per session and a blank line between them.
        self.list_area = Rect::new(
            area.x,
            area.y + 2,
            inner_w,
            area.height.saturating_sub(2 + footer_h + 1),
        );
        // The last session needs no gap below it.
        let visible = ((self.list_area.height + 1) / ROW_HEIGHT) as usize;
        if visible == 0 {
            return;
        }
        if self.cursor < self.list_offset {
            self.list_offset = self.cursor;
        } else if self.cursor >= self.list_offset + visible {
            self.list_offset = self.cursor + 1 - visible;
        }
        self.list_offset = self
            .list_offset
            .min(self.rows.len().saturating_sub(visible));

        if self.rows.is_empty() {
            let msg = if !self.loaded {
                " Loading sessions…"
            } else if self.hide_inactive {
                " No running sessions (i shows all)"
            } else if !self.all_repos {
                " No sessions here (a shows all repos)"
            } else {
                " No sessions"
            };
            f.render_widget(
                Paragraph::new(Line::styled(msg, Style::default().fg(theme().muted))),
                self.list_area,
            );
            return;
        }

        let now = SystemTime::now();
        let tick = (self.started.elapsed().as_millis() / 150) as usize;
        for (i, row) in self
            .rows
            .iter()
            .enumerate()
            .skip(self.list_offset)
            .take(visible)
        {
            let y = self.list_area.y + (i - self.list_offset) as u16 * ROW_HEIGHT;
            let rect = Rect::new(self.list_area.x, y, inner_w, 2);
            let is_cursor = i == self.cursor;
            let is_current = self.current_running().is_some_and(|r| r.is(&row.key));
            let running = self
                .running
                .iter()
                .find(|r| r.is(&row.key) && r.term.is_running());

            let bg = match (is_cursor, focused) {
                (true, true) => theme().cursor_bg,
                (true, false) => theme().cursor_bg_unfocused,
                _ => Color::Reset,
            };
            let (icon, icon_color) = agent_icon(row.key.0);
            let bar = if is_current {
                Span::styled("▌", Style::default().fg(theme().accent))
            } else {
                Span::raw(" ")
            };

            // Line 1: bar, icon, title, run state.
            let marker = match running {
                Some(r) if r.term.is_busy() => Span::styled(
                    SPINNER[tick % SPINNER.len()],
                    Style::default().fg(theme().warn),
                ),
                Some(_) => Span::styled("●", Style::default().fg(theme().accent)),
                None => Span::raw(" "),
            };
            let title_w = (inner_w as usize).saturating_sub(6);
            let title_style = if is_current || is_cursor {
                Style::default().add_modifier(Modifier::BOLD)
            } else {
                Style::default()
            };
            let line1 = Line::from(vec![
                bar.clone(),
                Span::styled(format!("{icon} "), Style::default().fg(icon_color)),
                Span::styled(pad(&truncate(&row.title, title_w), title_w), title_style),
                Span::raw(" "),
                marker,
            ]);

            // Line 2: project folder, agent, age.
            let project = row
                .cwd
                .file_name()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default();
            let meta = format!("{} · {}", row.key.0.name(), age(now, row.updated));
            let proj_w = (inner_w as usize).saturating_sub(4 + meta.width() + 3);
            let line2 = Line::from(vec![
                bar,
                Span::raw("  "),
                Span::styled(
                    truncate(&project, proj_w),
                    Style::default().fg(theme().folder),
                ),
                Span::styled(format!(" · {meta}"), Style::default().fg(theme().muted)),
            ]);

            f.render_widget(
                Paragraph::new(vec![line1, line2]).style(Style::default().bg(bg)),
                rect,
            );
        }
    }

    fn draw_pane(&mut self, f: &mut Frame) {
        let area = self.pane;
        if area.width == 0 || area.height < 2 {
            return;
        }
        let header = Rect::new(area.x, area.y, area.width, 1);
        let body = pane_body(area);

        let Some(r) = self.current_running() else {
            let lines = vec![
                Line::raw(""),
                Line::styled(
                    "  Pick a session on the left to resume it.",
                    Style::default().fg(theme().muted),
                ),
                Line::styled(
                    "  Press n for a new Claude session, N for a new Codex session.",
                    Style::default().fg(theme().muted),
                ),
                Line::styled(
                    "  Press t for a plain shell.",
                    Style::default().fg(theme().muted),
                ),
                Line::styled(
                    "  Ctrl+\\ switches between the list and the agent.",
                    Style::default().fg(theme().muted),
                ),
            ];
            f.render_widget(Paragraph::new(lines), body);
            return;
        };

        // A shell running an agent shows that agent's session.
        let row = self.rows.iter().find(|row| r.is(&row.key));
        let (agent, title, cwd) = match row {
            Some(row) => (row.key.0, row.title.clone(), &row.cwd),
            None => (r.key.0, r.fallback_title.clone(), &r.cwd),
        };
        let (icon, icon_color) = agent_icon(agent);
        let state = if let Some(code) = r.term.exit_code {
            Span::styled(
                format!(" exited ({code}) · Enter to resume "),
                Style::default().fg(Color::Black).bg(Color::Yellow),
            )
        } else if r.term.scrollback() > 0 {
            Span::styled(
                format!(" scrolled ↑{} ", r.term.scrollback()),
                Style::default().fg(Color::Black).bg(Color::Cyan),
            )
        } else {
            Span::raw("")
        };
        let cwd = tilde(cwd);
        let left_w = (area.width as usize).saturating_sub(state.width() + 1);
        let header_text = truncate(
            &format!(" {icon} {} · {title} · {cwd}", agent.name()),
            left_w,
        );
        let focused = self.focus == Focus::Terminal;
        let header_style = if focused {
            Style::default().bg(theme().header_bg)
        } else {
            Style::default()
                .bg(theme().header_bg_unfocused)
                .fg(theme().muted)
        };
        let line = Line::from(vec![
            Span::styled(
                pad(&header_text, left_w),
                Style::default().fg(if focused { icon_color } else { theme().muted }),
            ),
            Span::raw(" "),
            state,
        ]);
        f.render_widget(Paragraph::new(line).style(header_style), header);

        let cursor = r.term.render(body, f.buffer_mut());
        if focused && let Some((x, y)) = cursor {
            f.set_cursor_position((x, y));
        }
    }
}

/// The part of the pane that holds the agent's screen (below the header).
fn pane_body(pane: Rect) -> Rect {
    Rect::new(
        pane.x,
        pane.y + 1,
        pane.width,
        pane.height.saturating_sub(1),
    )
}

/// The user's login shell, or `/bin/sh`.
fn shell_program() -> String {
    std::env::var("SHELL")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "/bin/sh".into())
}

/// The shell's name, e.g. "fish", used as its title.
fn shell_name() -> String {
    let program = shell_program();
    Path::new(&program)
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or(program)
}

pub fn build_command(agent: Agent, args: &[String], cwd: &Path) -> CommandBuilder {
    let (program, extra_var) = match agent {
        Agent::Claude => ("claude".to_string(), Some("AGENTZ_CLAUDE_ARGS")),
        Agent::Codex => ("codex".to_string(), Some("AGENTZ_CODEX_ARGS")),
        Agent::Shell => (shell_program(), None),
    };
    let mut cmd = CommandBuilder::new(program);
    // Extra flags go first so they also apply to `codex resume`.
    if let Some(extra) = extra_var.and_then(|v| std::env::var(v).ok()) {
        let extra: Vec<&str> = extra.split_whitespace().collect();
        if agent == Agent::Codex && args.first().map(String::as_str) == Some("resume") {
            cmd.arg("resume");
            cmd.args(&extra);
            cmd.args(&args[1..]);
        } else {
            cmd.args(&extra);
            cmd.args(args);
        }
    } else {
        cmd.args(args);
    }
    cmd.cwd(cwd);
    cmd.env("TERM", "xterm-256color");
    cmd.env("COLORTERM", "truecolor");
    // The agent talks to our emulator, not the outer terminal, so hide the
    // outer terminal's identity. Also hide that we may run inside Claude Code.
    for var in [
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "LC_TERMINAL",
        "LC_TERMINAL_VERSION",
        "ITERM_SESSION_ID",
        "KITTY_WINDOW_ID",
        "WEZTERM_PANE",
        "GHOSTTY_RESOURCES_DIR",
        "TMUX",
        "CLAUDECODE",
        "CLAUDE_PID",
        "CLAUDE_EFFORT",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
    ] {
        cmd.env_remove(var);
    }
    cmd
}

fn agent_icon(agent: Agent) -> (&'static str, Color) {
    match agent {
        Agent::Claude => ("✻", theme().claude),
        Agent::Codex => ("◆", theme().codex),
        Agent::Shell => ("❯", theme().shell),
    }
}

fn hint_line(items: &[(&str, &str)]) -> Line<'static> {
    let mut spans = vec![Span::raw(" ")];
    for (k, label) in items {
        spans.push(Span::styled(
            k.to_string(),
            Style::default().fg(theme().accent),
        ));
        spans.push(Span::styled(
            format!(" {label}  "),
            Style::default().fg(theme().muted),
        ));
    }
    Line::from(spans)
}

fn age(now: SystemTime, t: SystemTime) -> String {
    let s = now.duration_since(t).unwrap_or_default().as_secs();
    match s {
        0..60 => "now".into(),
        60..3600 => format!("{}m ago", s / 60),
        3600..86400 => format!("{}h ago", s / 3600),
        86400..2_592_000 => format!("{}d ago", s / 86400),
        _ => format!("{}mo ago", s / 2_592_000),
    }
}

fn tilde(p: &Path) -> String {
    if let Some(home) = dirs::home_dir()
        && let Ok(rest) = p.strip_prefix(&home)
    {
        return format!("~/{}", rest.display());
    }
    p.display().to_string()
}

/// Cuts `s` to at most `max` display columns, adding "…" if cut.
fn truncate(s: &str, max: usize) -> String {
    if s.width() <= max {
        return s.to_string();
    }
    let mut out = String::new();
    let mut w = 0;
    for c in s.chars() {
        let cw = c.width().unwrap_or(0);
        if w + cw + 1 > max {
            break;
        }
        out.push(c);
        w += cw;
    }
    out.push('…');
    out
}

fn pad(s: &str, width: usize) -> String {
    let w = s.width();
    if w >= width {
        s.to_string()
    } else {
        format!("{s}{}", " ".repeat(width - w))
    }
}
