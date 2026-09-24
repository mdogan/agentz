mod app;
#[cfg(test)]
mod compat_tests;
mod procs;
mod project;
mod sessions;
mod term;

use std::io::{Write, stdout};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use crossterm::event::{
    self, DisableBracketedPaste, DisableFocusChange, DisableMouseCapture, EnableBracketedPaste,
    EnableFocusChange, EnableMouseCapture, Event, KeyboardEnhancementFlags,
    PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
};
use crossterm::execute;
use crossterm::terminal::supports_keyboard_enhancement;

use crate::app::App;
use crate::project::Project;
use crate::sessions::{Agent, Scanner, Session, SessionKey};

pub enum AppEvent {
    Input(Event),
    /// Some agent printed output.
    Redraw,
    /// The agent in the terminal with this id exited.
    Exited(u64),
    /// All sessions, the project agentz was started in, and for each of our shells (by pid) the session of the
    /// agent running inside it.
    Sessions(Vec<Session>, Project, Vec<(u32, SessionKey)>),
}

const SCAN_INTERVAL: Duration = Duration::from_secs(3);
const TICK: Duration = Duration::from_millis(150);
/// How long we wait for an agent to finish a synchronized frame.
const SYNC_WAIT: Duration = Duration::from_millis(50);

fn main() -> Result<()> {
    if std::env::args().nth(1).as_deref() == Some("--list") {
        let project = Project::detect(&std::env::current_dir()?);
        let mut sessions = Scanner::default().scan();
        sessions.retain(|s| project.contains(&s.cwd));
        for s in sessions {
            println!(
                "{}\t{}\t{}\t{}",
                s.agent.name(),
                s.id,
                s.cwd.display(),
                s.title
            );
        }
        return Ok(());
    }

    let mut terminal = ratatui::init();
    term::query_outer_colors();
    let kitty = matches!(supports_keyboard_enhancement(), Ok(true));
    execute!(
        stdout(),
        EnableMouseCapture,
        EnableBracketedPaste,
        EnableFocusChange
    )?;
    if kitty {
        // Lets us tell Shift+Enter apart from Enter.
        execute!(
            stdout(),
            PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
        )?;
    }
    let hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        restore_modes(kitty);
        hook(info);
    }));

    let result = run(&mut terminal);

    restore_modes(kitty);
    ratatui::restore();
    result
}

fn restore_modes(kitty: bool) {
    if kitty {
        let _ = execute!(stdout(), PopKeyboardEnhancementFlags);
    }
    let _ = execute!(
        stdout(),
        DisableFocusChange,
        DisableBracketedPaste,
        DisableMouseCapture
    );
}

/// Shows a desktop notification through the outer terminal (OSC 777,
/// supported by Ghostty and others). Call it between frames only, so the
/// sequence does not land in the middle of one.
fn notify(agent: Agent, session: &str) {
    let agent = match agent {
        Agent::Claude => "Claude",
        Agent::Codex => "Codex",
        Agent::Shell => "Shell",
    };
    // The fields are separated by `;`, and control characters could end
    // the sequence early.
    let clean = |s: &str| -> String {
        s.chars()
            .map(|c| if c.is_control() || c == ';' { ' ' } else { c })
            .collect()
    };
    let seq = format!(
        "\x1b]777;notify;{agent} is waiting;{}\x1b\\",
        clean(session)
    );
    let mut out = stdout().lock();
    let _ = out.write_all(seq.as_bytes());
    let _ = out.flush();
}

fn run(terminal: &mut ratatui::DefaultTerminal) -> Result<()> {
    let (tx, rx) = mpsc::channel();
    let redraw = Arc::new(AtomicBool::new(false));
    let shell_pids = Arc::new(Mutex::new(Vec::new()));

    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            while let Ok(ev) = event::read() {
                if tx.send(AppEvent::Input(ev)).is_err() {
                    break;
                }
            }
        });
    }
    {
        let tx = tx.clone();
        let shell_pids = shell_pids.clone();
        std::thread::spawn(move || {
            let dir = std::env::current_dir().unwrap_or_else(|_| ".".into());
            let mut scanner = Scanner::default();
            loop {
                let sessions = scanner.scan();
                let project = Project::detect(&dir);
                let pids = shell_pids.lock().unwrap().clone();
                let links = procs::agents_in_shells(&pids);
                if tx
                    .send(AppEvent::Sessions(sessions, project, links))
                    .is_err()
                {
                    break;
                }
                std::thread::sleep(SCAN_INTERVAL);
            }
        });
    }

    let mut app = App::new(tx, redraw.clone(), shell_pids);
    let mut sync_since: Option<Instant> = None;
    terminal.draw(|f| app.draw(f))?;

    loop {
        match rx.recv_timeout(TICK) {
            Ok(ev) => app.handle(ev),
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
        // Handle everything that queued up, then draw once.
        while let Ok(ev) = rx.try_recv() {
            app.handle(ev);
        }
        if app.quit {
            break;
        }
        // Clear the flag before pumping: output that comes in after this
        // sends a new Redraw, so it is never left waiting for the next tick.
        redraw.store(false, Ordering::Release);
        app.pump();
        for (agent, title) in app.finished_unseen() {
            notify(agent, &title);
        }

        // Don't show half-drawn frames, but never wait for long.
        if app.current_synchronized() {
            let since = *sync_since.get_or_insert_with(Instant::now);
            if since.elapsed() < SYNC_WAIT {
                continue;
            }
        }
        sync_since = None;
        terminal.draw(|f| app.draw(f))?;
    }
    Ok(())
}
