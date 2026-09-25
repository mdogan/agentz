//! Tells when an agent is working and when the user should hear that it is
//! done, from what the agent signals to its terminal:
//!
//! - Claude reports progress (OSC 9;4) while it works, because it sees
//!   `TERM_PROGRAM=ghostty`.
//! - Codex shows a spinner in the window title while it works, and sends a
//!   notification (OSC 9 or 777) when it is done and not looked at.
//!
//! A program that signals none of these is never busy.

use std::path::PathBuf;

/// Something the program told the terminal, other than drawing.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum TerminalSignal {
    /// OSC 0/2: the window title.
    Title(String),
    /// OSC 9;4: progress shown (true) or removed (false).
    Progress(bool),
    /// OSC 9 or OSC 777: a desktop notification.
    Notify { title: String, body: String },
    /// OSC 7: the working directory, as a path or a `file://` URL.
    Pwd(String),
}

/// Tell the user the agent wants attention, with the agent's own message
/// if it sent one.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Notice {
    pub message: Option<String>,
}

/// What `Turns::update` found.
#[derive(Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct TurnUpdate {
    pub notice: Option<Notice>,
    /// The new working directory the program reported.
    pub cwd: Option<PathBuf>,
    /// `is_busy()` after the update.
    pub busy: bool,
}

#[derive(Debug, Default)]
pub struct Turns {
    /// Whether the program says it is working, from progress reports or a
    /// spinner in its title. None until it tells us.
    reported_busy: Option<bool>,
    /// Once a program sent a progress report, we ignore its title.
    has_progress: bool,
    was_busy: bool,
    /// The user typed into the terminal at least once.
    typed: bool,
    /// True once the user heard about the current turn.
    notified: bool,
    pending: Vec<TerminalSignal>,
}

impl Turns {
    pub fn receive(&mut self, signal: TerminalSignal) {
        self.pending.push(signal);
    }

    /// The user typed. It starts a new turn: the agent may notify again
    /// when it is done.
    pub fn user_input(&mut self) {
        self.typed = true;
        self.notified = false;
    }

    /// Forgets what the program said about being busy, e.g. when the agent
    /// in a shell exits and the shell is left.
    pub fn forget_reported_busy(&mut self) {
        self.reported_busy = None;
        self.has_progress = false;
    }

    /// True if the program says it is working, with progress reports or a
    /// title spinner.
    pub fn is_busy(&self) -> bool {
        self.reported_busy == Some(true)
    }

    /// Reads the signals received since the last call and tells whether the
    /// user should hear about it. `running` is false once the process exited.
    pub fn update(&mut self, running: bool) -> TurnUpdate {
        let mut update = TurnUpdate::default();
        let mut agent_notice = None;
        for signal in std::mem::take(&mut self.pending) {
            match signal {
                TerminalSignal::Progress(busy) => {
                    self.has_progress = true;
                    self.reported_busy = Some(busy);
                }
                TerminalSignal::Title(title) if !self.has_progress => {
                    if let Some(busy) = title_busy(&title, self.reported_busy.is_some()) {
                        self.reported_busy = Some(busy);
                    }
                }
                TerminalSignal::Notify { title, body } => {
                    let text = if body.is_empty() { title } else { body };
                    agent_notice = Some(text.trim().to_string());
                }
                TerminalSignal::Pwd(pwd) => {
                    if let Some(path) = pwd_path(&pwd) {
                        update.cwd = Some(path);
                    }
                }
                TerminalSignal::Title(_) => {}
            }
        }

        let busy = running && self.is_busy();
        // Work that stopped because the agent in a shell exited
        // (`forget_reported_busy`) is not a finished turn.
        let finished = self.was_busy && !busy && self.reported_busy.is_some();
        self.was_busy = busy;

        // One notice per turn, and none before the user asked anything.
        if running && self.typed && !self.notified {
            if let Some(text) = agent_notice {
                let message = (!text.is_empty()).then_some(text);
                update.notice = Some(Notice { message });
            } else if finished {
                update.notice = Some(Notice { message: None });
            }
            self.notified = update.notice.is_some();
        }
        update.busy = self.is_busy();
        update
    }
}

/// Whether a window title says the program is working. Claude shows a
/// half-filled circle while working and `✳` when idle; Codex shows a
/// braille spinner while working and nothing when idle. `known` is true
/// once the program's titles told us something, so a plain title then
/// means idle.
fn title_busy(title: &str, known: bool) -> Option<bool> {
    let first = title.chars().next();
    match first {
        Some('\u{2801}'..='\u{28ff}' | '◐' | '◓' | '◑' | '◒') => Some(true),
        Some('✳') => Some(false),
        _ => known.then_some(false),
    }
}

/// The path in an OSC 7 working directory like `file://host/Users/me/a%20b`.
fn pwd_path(pwd: &str) -> Option<PathBuf> {
    let path = match pwd.split_once("://") {
        Some((_, rest)) => &rest[rest.find('/')?..],
        None => pwd,
    };
    if !path.starts_with('/') {
        return None;
    }
    let mut bytes = Vec::with_capacity(path.len());
    let mut it = path.bytes();
    while let Some(b) = it.next() {
        let hex = |b: Option<u8>| (b? as char).to_digit(16);
        if b == b'%' {
            let mut peek = it.clone();
            if let (Some(h), Some(l)) = (hex(peek.next()), hex(peek.next())) {
                bytes.push((h * 16 + l) as u8);
                it = peek;
                continue;
            }
        }
        bytes.push(b);
    }
    Some(PathBuf::from(String::from_utf8(bytes).ok()?))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn notice(message: Option<&str>) -> Option<Notice> {
        Some(Notice {
            message: message.map(String::from),
        })
    }

    #[test]
    fn forwards_agent_notification_once() {
        let mut t = Turns::default();
        t.user_input();
        t.receive(TerminalSignal::Progress(true));
        t.receive(TerminalSignal::Notify {
            title: "Codex".into(),
            body: " Done: OK ".into(),
        });
        assert_eq!(t.update(true).notice, notice(Some("Done: OK")));
        // The progress end right after is the same turn.
        t.receive(TerminalSignal::Progress(false));
        assert_eq!(t.update(true).notice, None);
        assert!(!t.is_busy());
    }

    #[test]
    fn notice_when_progress_ends() {
        let mut t = Turns::default();
        t.user_input();
        t.receive(TerminalSignal::Progress(true));
        assert_eq!(t.update(true).notice, None);
        assert!(t.is_busy());
        t.receive(TerminalSignal::Progress(false));
        assert_eq!(t.update(true).notice, notice(None));
        // Typing starts a new turn, which can notify again.
        t.user_input();
        t.receive(TerminalSignal::Progress(true));
        t.update(true);
        t.receive(TerminalSignal::Progress(false));
        assert_eq!(t.update(true).notice, notice(None));
    }

    #[test]
    fn no_notice_before_the_user_typed() {
        let mut t = Turns::default();
        t.receive(TerminalSignal::Progress(true));
        t.update(true);
        t.receive(TerminalSignal::Progress(false));
        t.receive(TerminalSignal::Pwd("file://h/done%20x".into()));
        t.receive(TerminalSignal::Pwd("relative".into()));
        let update = t.update(true);
        assert_eq!(update.notice, None);
        assert_eq!(update.cwd, Some(PathBuf::from("/done x")));
    }

    #[test]
    fn no_notice_after_exit() {
        let mut t = Turns::default();
        t.user_input();
        t.receive(TerminalSignal::Progress(true));
        t.update(true);
        t.receive(TerminalSignal::Progress(false));
        assert_eq!(t.update(false).notice, None);
    }

    #[test]
    fn title_spinner_means_busy_until_progress_is_reported() {
        let mut t = Turns::default();
        t.receive(TerminalSignal::Title("⠋ codex".into()));
        t.update(true);
        assert!(t.is_busy());
        t.receive(TerminalSignal::Title("codex".into()));
        t.update(true);
        assert!(!t.is_busy());
        t.receive(TerminalSignal::Progress(true));
        t.receive(TerminalSignal::Title("plain".into()));
        t.update(true);
        assert!(t.is_busy());
        // The agent exited and left its shell: titles count again.
        t.forget_reported_busy();
        t.receive(TerminalSignal::Title("fish".into()));
        t.update(true);
        assert!(!t.is_busy());
    }

    #[test]
    fn reads_busy_from_titles() {
        assert_eq!(title_busy("◐ Fix the bug", false), Some(true));
        assert_eq!(title_busy("✳ Fix the bug", false), Some(false));
        assert_eq!(title_busy("⠋ my-repo", false), Some(true));
        assert_eq!(title_busy("⠸ ⠸ | my-repo", true), Some(true));
        // Codex's idle title is plain, which only counts once we know it.
        assert_eq!(title_busy("Fix the bug | my-repo", true), Some(false));
        assert_eq!(title_busy("fish /Users/me", false), None);
        assert_eq!(title_busy("", false), None);
    }

    #[test]
    fn parses_pwd() {
        let p = |s| pwd_path(s).map(|p| p.display().to_string());
        assert_eq!(
            p("file://host/Users/me/a%20b").as_deref(),
            Some("/Users/me/a b")
        );
        assert_eq!(p("file:///tmp").as_deref(), Some("/tmp"));
        assert_eq!(p("kitty-shell-cwd://host/tmp/x").as_deref(), Some("/tmp/x"));
        assert_eq!(p("/plain/path").as_deref(), Some("/plain/path"));
        assert_eq!(p("100%/x%zz").as_deref(), None);
    }
}
