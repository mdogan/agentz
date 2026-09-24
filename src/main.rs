mod app;
mod procs;
mod sessions;
mod term;

use std::io::stdout;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use crossterm::event::{
    self, DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture,
    Event, KeyboardEnhancementFlags, PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
};
use crossterm::execute;
use crossterm::terminal::supports_keyboard_enhancement;

use crate::app::App;
use crate::sessions::{Scanner, Session, SessionKey};

pub enum AppEvent {
    Input(Event),
    /// Some agent printed output.
    Redraw,
    /// The agent in the terminal with this id exited.
    Exited(u64),
    /// All sessions, and for each of our shells (by pid) the session of the
    /// agent running inside it.
    Sessions(Vec<Session>, Vec<(u32, SessionKey)>),
}

const SCAN_INTERVAL: Duration = Duration::from_secs(3);
const TICK: Duration = Duration::from_millis(150);
/// How long we wait for an agent to finish a synchronized frame.
const SYNC_WAIT: Duration = Duration::from_millis(50);

fn main() -> Result<()> {
    if std::env::args().nth(1).as_deref() == Some("--list") {
        for s in Scanner::default().scan() {
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
    let kitty = matches!(supports_keyboard_enhancement(), Ok(true));
    execute!(stdout(), EnableMouseCapture, EnableBracketedPaste)?;
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
    let _ = execute!(stdout(), DisableBracketedPaste, DisableMouseCapture);
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
            let mut scanner = Scanner::default();
            loop {
                let pids = shell_pids.lock().unwrap().clone();
                let links = procs::agents_in_shells(&pids);
                if tx.send(AppEvent::Sessions(scanner.scan(), links)).is_err() {
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
        redraw.store(false, Ordering::Release);

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
