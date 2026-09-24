//! One agent process running in its own PTY, with a vt100 emulator that
//! keeps its screen. The process keeps running whether or not it is shown.

use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseEventKind};
use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use vt100::{MouseProtocolEncoding, MouseProtocolMode};

use crate::AppEvent;

const SCROLLBACK: usize = 10_000;

/// Handles the terminal queries vt100 does not answer itself. Agents built
/// on crossterm (Codex) block at startup until they get a cursor position.
#[derive(Default)]
pub struct Callbacks {
    replies: Vec<u8>,
    /// DEC mode 2026: the app is in the middle of drawing a frame.
    pub synchronized: bool,
}

impl vt100::Callbacks for Callbacks {
    fn unhandled_csi(
        &mut self,
        screen: &mut vt100::Screen,
        i1: Option<u8>,
        _i2: Option<u8>,
        params: &[&[u16]],
        c: char,
    ) {
        let first = params.first().and_then(|p| p.first()).copied().unwrap_or(0);
        match (i1, c) {
            (None, 'n') if first == 5 => self.replies.extend_from_slice(b"\x1b[0n"),
            (None, 'n') if first == 6 => {
                let (row, col) = screen.cursor_position();
                self.replies
                    .extend_from_slice(format!("\x1b[{};{}R", row + 1, col + 1).as_bytes());
            }
            // Primary device attributes: a VT220-ish terminal.
            (None, 'c') if first == 0 => self.replies.extend_from_slice(b"\x1b[?62;22c"),
            (Some(b'>'), 'c') if first == 0 => self.replies.extend_from_slice(b"\x1b[>1;10;0c"),
            (Some(b'?'), 'h') if first == 2026 => self.synchronized = true,
            (Some(b'?'), 'l') if first == 2026 => self.synchronized = false,
            _ => {}
        }
    }
}

pub struct Term {
    pub id: u64,
    /// The child's process id.
    pub pid: Option<u32>,
    parser: Arc<Mutex<vt100::Parser<Callbacks>>>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn Child + Send + Sync>,
    last_output_ms: Arc<AtomicU64>,
    pub exit_code: Option<u32>,
}

impl Term {
    pub fn spawn(
        id: u64,
        cmd: CommandBuilder,
        rows: u16,
        cols: u16,
        events: Sender<AppEvent>,
        redraw: Arc<AtomicBool>,
    ) -> Result<Self> {
        let rows = rows.max(2);
        let cols = cols.max(10);
        let pair = native_pty_system()
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("open pty")?;
        let child = pair.slave.spawn_command(cmd).context("spawn agent")?;
        // Drop our copy of the slave so reads hit EOF when the child exits.
        drop(pair.slave);

        let mut reader = pair.master.try_clone_reader()?;
        let writer: Arc<Mutex<Box<dyn Write + Send>>> =
            Arc::new(Mutex::new(pair.master.take_writer()?));
        let parser = Arc::new(Mutex::new(vt100::Parser::new_with_callbacks(
            rows,
            cols,
            SCROLLBACK,
            Callbacks::default(),
        )));
        let last_output_ms = Arc::new(AtomicU64::new(0));

        {
            let parser = parser.clone();
            let writer = writer.clone();
            let last_output_ms = last_output_ms.clone();
            std::thread::spawn(move || {
                let mut buf = vec![0u8; 64 * 1024];
                loop {
                    let n = match reader.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => n,
                    };
                    let replies = {
                        let mut p = parser.lock().unwrap();
                        p.process(&buf[..n]);
                        std::mem::take(&mut p.callbacks_mut().replies)
                    };
                    if !replies.is_empty() {
                        let mut w = writer.lock().unwrap();
                        let _ = w.write_all(&replies);
                        let _ = w.flush();
                    }
                    last_output_ms.store(now_ms(), Ordering::Relaxed);
                    if !redraw.swap(true, Ordering::AcqRel) {
                        let _ = events.send(AppEvent::Redraw);
                    }
                }
                let _ = events.send(AppEvent::Exited(id));
            });
        }

        Ok(Term {
            id,
            pid: child.process_id(),
            parser,
            writer,
            master: pair.master,
            child,
            last_output_ms,
            exit_code: None,
        })
    }

    pub fn is_running(&self) -> bool {
        self.exit_code.is_none()
    }

    /// Called after the reader saw EOF; reaps the child.
    pub fn mark_exited(&mut self) {
        let status = self.child.wait().ok();
        self.exit_code = Some(status.map(|s| s.exit_code()).unwrap_or(1));
    }

    pub fn kill(&mut self) {
        if self.is_running() {
            let _ = self.child.kill();
        }
    }

    /// True if the agent printed something recently, i.e. it is working.
    pub fn is_busy(&self) -> bool {
        let last = self.last_output_ms.load(Ordering::Relaxed);
        self.is_running() && now_ms().saturating_sub(last) < 1500
    }

    pub fn synchronized(&self) -> bool {
        self.parser.lock().unwrap().callbacks().synchronized
    }

    pub fn resize(&self, rows: u16, cols: u16) {
        let rows = rows.max(2);
        let cols = cols.max(10);
        let mut p = self.parser.lock().unwrap();
        if p.screen().size() == (rows, cols) {
            return;
        }
        p.screen_mut().set_size(rows, cols);
        drop(p);
        let _ = self.master.resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        });
    }

    pub fn write(&self, bytes: &[u8]) {
        if bytes.is_empty() || !self.is_running() {
            return;
        }
        let mut w = self.writer.lock().unwrap();
        let _ = w.write_all(bytes);
        let _ = w.flush();
    }

    pub fn send_key(&self, key: KeyEvent) {
        let app_cursor = {
            let mut p = self.parser.lock().unwrap();
            p.screen_mut().set_scrollback(0);
            p.screen().application_cursor()
        };
        self.write(&encode_key(key, app_cursor));
    }

    pub fn paste(&self, text: &str) {
        let bracketed = {
            let mut p = self.parser.lock().unwrap();
            p.screen_mut().set_scrollback(0);
            p.screen().bracketed_paste()
        };
        if bracketed {
            let mut bytes = b"\x1b[200~".to_vec();
            bytes.extend_from_slice(text.as_bytes());
            bytes.extend_from_slice(b"\x1b[201~");
            self.write(&bytes);
        } else {
            self.write(text.replace("\r\n", "\r").replace('\n', "\r").as_bytes());
        }
    }

    /// Handles a mouse event at (col, row) relative to the terminal area.
    /// Forwards it if the app asked for mouse reports; otherwise the wheel
    /// scrolls our scrollback (or sends arrows on the alternate screen).
    pub fn mouse(&self, ev: MouseEvent, col: u16, row: u16) {
        let mut p = self.parser.lock().unwrap();
        let screen = p.screen();
        let mode = screen.mouse_protocol_mode();
        let enc = screen.mouse_protocol_encoding();
        let alternate = screen.alternate_screen();
        let app_cursor = screen.application_cursor();
        let cur = screen.scrollback();
        if mode != MouseProtocolMode::None {
            drop(p);
            if let Some(bytes) = encode_mouse(ev, col, row, mode, enc) {
                self.write(&bytes);
            }
            return;
        }
        let up = match ev.kind {
            MouseEventKind::ScrollUp => true,
            MouseEventKind::ScrollDown => false,
            _ => return,
        };
        if alternate {
            drop(p);
            let arrow = match (up, app_cursor) {
                (true, true) => "\x1bOA",
                (true, false) => "\x1b[A",
                (false, true) => "\x1bOB",
                (false, false) => "\x1b[B",
            };
            self.write(arrow.repeat(3).as_bytes());
        } else {
            let next = if up { cur + 3 } else { cur.saturating_sub(3) };
            p.screen_mut().set_scrollback(next);
        }
    }

    /// The visible screen as plain text.
    #[cfg(test)]
    pub fn screen_text(&self) -> String {
        self.parser.lock().unwrap().screen().contents()
    }

    pub fn scrollback(&self) -> usize {
        self.parser.lock().unwrap().screen().scrollback()
    }

    /// Draws the emulator screen into `area`. Returns the cursor position
    /// in absolute coordinates if it should be shown.
    pub fn render(&self, area: Rect, buf: &mut Buffer) -> Option<(u16, u16)> {
        let p = self.parser.lock().unwrap();
        let screen = p.screen();
        for row in 0..area.height {
            for col in 0..area.width {
                let Some(cell) = screen.cell(row, col) else {
                    continue;
                };
                if cell.is_wide_continuation() {
                    continue;
                }
                let mut style = Style::default()
                    .fg(color(cell.fgcolor()))
                    .bg(color(cell.bgcolor()));
                let mut mods = Modifier::empty();
                if cell.bold() {
                    mods |= Modifier::BOLD;
                }
                if cell.dim() {
                    mods |= Modifier::DIM;
                }
                if cell.italic() {
                    mods |= Modifier::ITALIC;
                }
                if cell.underline() {
                    mods |= Modifier::UNDERLINED;
                }
                if cell.inverse() {
                    mods |= Modifier::REVERSED;
                }
                style = style.add_modifier(mods);
                let sym = if cell.has_contents() {
                    cell.contents()
                } else {
                    " "
                };
                if let Some(c) = buf.cell_mut((area.x + col, area.y + row)) {
                    c.set_symbol(sym).set_style(style);
                }
            }
        }
        if screen.hide_cursor() || screen.scrollback() > 0 {
            return None;
        }
        let (row, col) = screen.cursor_position();
        (row < area.height && col < area.width).then_some((area.x + col, area.y + row))
    }
}

impl Drop for Term {
    fn drop(&mut self) {
        self.kill();
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis() as u64
}

fn color(c: vt100::Color) -> Color {
    match c {
        vt100::Color::Default => Color::Reset,
        vt100::Color::Idx(i) => Color::Indexed(i),
        vt100::Color::Rgb(r, g, b) => Color::Rgb(r, g, b),
    }
}

/// xterm modifier parameter: 1 + shift + 2*alt + 4*ctrl.
fn mod_param(m: KeyModifiers) -> u8 {
    1 + m.contains(KeyModifiers::SHIFT) as u8
        + 2 * m.contains(KeyModifiers::ALT) as u8
        + 4 * m.contains(KeyModifiers::CONTROL) as u8
}

/// Turns a key press into the bytes a legacy xterm would send.
pub fn encode_key(key: KeyEvent, app_cursor: bool) -> Vec<u8> {
    let m = key.modifiers;
    let alt = m.contains(KeyModifiers::ALT);
    let ctrl = m.contains(KeyModifiers::CONTROL);
    let mut out = Vec::new();
    let esc_if_alt = |out: &mut Vec<u8>| {
        if alt {
            out.push(0x1b);
        }
    };

    // CSI sequences for cursor-like keys: `\x1b[A` or `\x1b[1;5A`.
    let letter = |out: &mut Vec<u8>, ch: char| {
        if m.intersects(KeyModifiers::SHIFT | KeyModifiers::ALT | KeyModifiers::CONTROL) {
            out.extend_from_slice(format!("\x1b[1;{}{}", mod_param(m), ch).as_bytes());
        } else if app_cursor {
            out.extend_from_slice(format!("\x1bO{ch}").as_bytes());
        } else {
            out.extend_from_slice(format!("\x1b[{ch}").as_bytes());
        }
    };
    // `\x1b[5~` or `\x1b[5;5~`.
    let tilde = |out: &mut Vec<u8>, n: u8| {
        if m.intersects(KeyModifiers::SHIFT | KeyModifiers::ALT | KeyModifiers::CONTROL) {
            out.extend_from_slice(format!("\x1b[{n};{}~", mod_param(m)).as_bytes());
        } else {
            out.extend_from_slice(format!("\x1b[{n}~").as_bytes());
        }
    };

    match key.code {
        KeyCode::Char(c) => {
            esc_if_alt(&mut out);
            if ctrl {
                let b = match c {
                    'a'..='z' => Some(c as u8 - b'a' + 1),
                    'A'..='Z' => Some(c as u8 - b'A' + 1),
                    '@' | ' ' | '2' => Some(0),
                    '[' | '3' => Some(0x1b),
                    '\\' | '4' => Some(0x1c),
                    ']' | '5' => Some(0x1d),
                    '^' | '6' => Some(0x1e),
                    '_' | '-' | '7' => Some(0x1f),
                    '?' | '8' => Some(0x7f),
                    _ => None,
                };
                if let Some(b) = b {
                    out.push(b);
                    return out;
                }
            }
            let mut tmp = [0u8; 4];
            out.extend_from_slice(c.encode_utf8(&mut tmp).as_bytes());
        }
        // Shift+Enter / Alt+Enter insert a newline in both Claude and Codex.
        KeyCode::Enter if m.intersects(KeyModifiers::SHIFT | KeyModifiers::ALT) => {
            out.extend_from_slice(b"\x1b\r")
        }
        KeyCode::Enter => out.push(b'\r'),
        KeyCode::Tab => {
            esc_if_alt(&mut out);
            if m.contains(KeyModifiers::SHIFT) {
                out.extend_from_slice(b"\x1b[Z");
            } else {
                out.push(b'\t');
            }
        }
        KeyCode::BackTab => out.extend_from_slice(b"\x1b[Z"),
        KeyCode::Backspace => {
            esc_if_alt(&mut out);
            out.push(if ctrl { 0x08 } else { 0x7f });
        }
        KeyCode::Esc => {
            esc_if_alt(&mut out);
            out.push(0x1b);
        }
        KeyCode::Up => letter(&mut out, 'A'),
        KeyCode::Down => letter(&mut out, 'B'),
        KeyCode::Right => letter(&mut out, 'C'),
        KeyCode::Left => letter(&mut out, 'D'),
        KeyCode::Home => letter(&mut out, 'H'),
        KeyCode::End => letter(&mut out, 'F'),
        KeyCode::Insert => tilde(&mut out, 2),
        KeyCode::Delete => tilde(&mut out, 3),
        KeyCode::PageUp => tilde(&mut out, 5),
        KeyCode::PageDown => tilde(&mut out, 6),
        KeyCode::F(n @ 1..=4) => {
            let ch = (b'P' + n - 1) as char;
            if m.is_empty() {
                out.extend_from_slice(format!("\x1bO{ch}").as_bytes());
            } else {
                out.extend_from_slice(format!("\x1b[1;{}{ch}", mod_param(m)).as_bytes());
            }
        }
        KeyCode::F(n @ 5..=12) => {
            let code = [15, 17, 18, 19, 20, 21, 23, 24][(n - 5) as usize];
            tilde(&mut out, code);
        }
        _ => {}
    }
    out
}

fn encode_mouse(
    ev: MouseEvent,
    col: u16,
    row: u16,
    mode: MouseProtocolMode,
    enc: MouseProtocolEncoding,
) -> Option<Vec<u8>> {
    let button_code = |b: MouseButton| match b {
        MouseButton::Left => 0u16,
        MouseButton::Middle => 1,
        MouseButton::Right => 2,
    };
    let (mut code, release) = match ev.kind {
        MouseEventKind::Down(b) => (button_code(b), false),
        MouseEventKind::Up(b) => {
            if mode == MouseProtocolMode::Press {
                return None;
            }
            (button_code(b), true)
        }
        MouseEventKind::Drag(b) => {
            if !matches!(
                mode,
                MouseProtocolMode::ButtonMotion | MouseProtocolMode::AnyMotion
            ) {
                return None;
            }
            (button_code(b) + 32, false)
        }
        MouseEventKind::Moved => {
            if mode != MouseProtocolMode::AnyMotion {
                return None;
            }
            (3 + 32, false)
        }
        MouseEventKind::ScrollUp => (64, false),
        MouseEventKind::ScrollDown => (65, false),
        MouseEventKind::ScrollLeft => (66, false),
        MouseEventKind::ScrollRight => (67, false),
    };
    if ev.modifiers.contains(KeyModifiers::SHIFT) {
        code += 4;
    }
    if ev.modifiers.contains(KeyModifiers::ALT) {
        code += 8;
    }
    if ev.modifiers.contains(KeyModifiers::CONTROL) {
        code += 16;
    }
    let (x, y) = (col + 1, row + 1);
    match enc {
        MouseProtocolEncoding::Sgr => {
            let end = if release { 'm' } else { 'M' };
            Some(format!("\x1b[<{code};{x};{y}{end}").into_bytes())
        }
        _ => {
            // Legacy X10 encoding: release is button 3, coordinates capped.
            let code = if release { 3 + (code & !3) } else { code };
            let clamp = |v: u16| (v.min(223) + 32) as u8;
            Some(vec![
                0x1b,
                b'[',
                b'M',
                (code + 32).min(255) as u8,
                clamp(x),
                clamp(y),
            ])
        }
    }
}
