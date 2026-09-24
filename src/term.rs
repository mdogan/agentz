//! One agent process running in its own PTY, with a Ghostty emulator
//! (libghostty-vt) that keeps its screen. The process keeps running whether
//! or not it is shown.
//!
//! libghostty-vt types can't leave the thread that made them. So the PTY
//! reader thread only passes the raw bytes on, and the main thread feeds
//! them to the emulator in `pump`.

use std::cell::{Cell, RefCell};
use std::io::{Read, Write};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, anyhow};
use crossterm::event::{
    KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use libghostty_vt::render::{CellIterator, RowIterator};
use libghostty_vt::screen::{CellContentTag, CellWide, Screen};
use libghostty_vt::style::{RgbColor, StyleColor, Underline};
use libghostty_vt::terminal::{ColorScheme, Mode, ScrollViewport, SizeReportSize};
use libghostty_vt::{RenderState, Terminal, key};
use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};

use crate::AppEvent;

const SCROLLBACK: usize = 10_000;

/// The outer terminal's default colors as it reported them, e.g.
/// `rgb:ffff/ffff/ffff`.
#[derive(Default)]
pub struct OuterColors {
    pub fg: Option<String>,
    pub bg: Option<String>,
}

pub static OUTER_COLORS: OnceLock<OuterColors> = OnceLock::new();

/// True if the outer terminal reported a light background.
pub fn light_background() -> bool {
    OUTER_COLORS
        .get()
        .and_then(|c| c.bg.as_deref())
        .and_then(parse_rgb)
        .is_some_and(|(r, g, b)| 0.299 * r + 0.587 * g + 0.114 * b > 0.5)
}

/// `rgb:ffff/fcfc/f0f0` as 0..1 values. Each part has 1 to 4 hex digits.
fn parse_rgb(s: &str) -> Option<(f32, f32, f32)> {
    let mut parts = s.strip_prefix("rgb:")?.split('/').map(|p| {
        let v = u32::from_str_radix(p, 16).ok()?;
        (1..=4)
            .contains(&p.len())
            .then(|| v as f32 / ((1u32 << (4 * p.len())) - 1) as f32)
    });
    let rgb = (parts.next()??, parts.next()??, parts.next()??);
    parts.next().is_none().then_some(rgb)
}

/// Asks the outer terminal for its default colors and keeps them in
/// `OUTER_COLORS`. Must run in raw mode, before anything else reads input.
/// Every terminal answers the DA1 query at the end, so its reply tells us
/// to stop waiting, even when the terminal does not know OSC 10/11.
#[cfg(unix)]
pub fn query_outer_colors() {
    use std::os::fd::AsRawFd;

    let fd = std::io::stdin().as_raw_fd();
    if unsafe { libc::isatty(fd) } != 1 {
        return;
    }
    let mut out = std::io::stdout();
    if out
        .write_all(b"\x1b]10;?\x1b\\\x1b]11;?\x1b\\\x1b[c")
        .and_then(|_| out.flush())
        .is_err()
    {
        return;
    }
    let deadline = Instant::now() + Duration::from_secs(1);
    let mut buf = Vec::new();
    while !has_da1_reply(&buf) {
        let left = deadline.saturating_duration_since(Instant::now());
        let mut pfd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        if left.is_zero() || unsafe { libc::poll(&mut pfd, 1, left.as_millis() as i32) } <= 0 {
            break;
        }
        let mut chunk = [0u8; 1024];
        let n = unsafe { libc::read(fd, chunk.as_mut_ptr().cast(), chunk.len()) };
        if n <= 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n as usize]);
    }
    let _ = OUTER_COLORS.set(OuterColors {
        fg: osc_color_reply(&buf, 10),
        bg: osc_color_reply(&buf, 11),
    });
}

#[cfg(not(unix))]
pub fn query_outer_colors() {}

/// True if `buf` holds a DA1 reply like `\x1b[?62;22c`.
fn has_da1_reply(buf: &[u8]) -> bool {
    buf.windows(3)
        .enumerate()
        .filter(|(_, w)| *w == b"\x1b[?")
        .any(|(i, _)| {
            buf[i + 3..]
                .iter()
                .find(|b| !(b.is_ascii_digit() || **b == b';'))
                == Some(&b'c')
        })
}

/// The color in a reply like `\x1b]11;rgb:ffff/ffff/ffff\x1b\\`.
fn osc_color_reply(buf: &[u8], n: u8) -> Option<String> {
    let prefix = format!("\x1b]{n};");
    let start = buf
        .windows(prefix.len())
        .position(|w| w == prefix.as_bytes())?
        + prefix.len();
    let rest = &buf[start..];
    let end = rest.iter().position(|&b| b == 0x07 || b == 0x1b)?;
    let value = std::str::from_utf8(&rest[..end]).ok()?;
    value.starts_with("rgb:").then(|| value.to_string())
}

/// `rgb:ffff/fcfc/f0f0` as an 8-bit color.
fn rgb8(s: &str) -> Option<RgbColor> {
    let (r, g, b) = parse_rgb(s)?;
    let c = |v: f32| (v * 255.0).round() as u8;
    Some(RgbColor {
        r: c(r),
        g: c(g),
        b: c(b),
    })
}

/// The emulator and the objects it needs to read its screen and encode
/// keys. Everything here lives on the main thread.
struct Emu {
    term: Terminal<'static, 'static>,
    render: RenderState<'static>,
    rows: RowIterator<'static>,
    cells: CellIterator<'static>,
    keys: key::Encoder<'static>,
    key_event: key::Event<'static>,
    /// Answers to queries (cursor position, colors, ...) that go back to
    /// the agent.
    replies: Rc<RefCell<Vec<u8>>>,
}

impl Emu {
    fn new(rows: u16, cols: u16) -> Result<Self> {
        let ghostty = |e: libghostty_vt::Error| anyhow!("libghostty: {e:?}");
        let mut term = Terminal::new(cols, rows).map_err(ghostty)?;
        let replies = Rc::new(RefCell::new(Vec::new()));
        {
            let replies = replies.clone();
            term.on_pty_write(move |_, data: &[u8]| replies.borrow_mut().extend_from_slice(data))
                .map_err(ghostty)?;
        }
        // Ghostty answers OSC 10/11 from its default colors, so programs
        // pick a theme that matches the outer terminal.
        let outer = OUTER_COLORS.get();
        term.set_scrollback_max_lines(Some(SCROLLBACK))
            .and_then(|t| {
                t.set_default_fg_color(outer.and_then(|c| c.fg.as_deref()).and_then(rgb8))
            })
            .and_then(|t| {
                t.set_default_bg_color(outer.and_then(|c| c.bg.as_deref()).and_then(rgb8))
            })
            .map_err(ghostty)?;
        // `CSI ? 996 n`: the other way to ask for light or dark.
        term.on_color_scheme(|_| {
            OUTER_COLORS.get()?.bg.as_ref()?;
            Some(if light_background() {
                ColorScheme::Light
            } else {
                ColorScheme::Dark
            })
        })
        .map_err(ghostty)?;
        // `CSI 18 t`: the size in cells. We don't know the pixel size.
        term.on_size(|t| {
            Some(SizeReportSize {
                rows: t.rows().ok()?,
                columns: t.cols().ok()?,
                cell_width: 0,
                cell_height: 0,
            })
        })
        .map_err(ghostty)?;
        term.on_xtversion(|_| Some(concat!("agentz ", env!("CARGO_PKG_VERSION"))))
            .map_err(ghostty)?;
        Ok(Emu {
            term,
            render: RenderState::new().map_err(ghostty)?,
            rows: RowIterator::new().map_err(ghostty)?,
            cells: CellIterator::new().map_err(ghostty)?,
            keys: key::Encoder::new().map_err(ghostty)?,
            key_event: key::Event::new().map_err(ghostty)?,
            replies,
        })
    }

    fn mode(&self, mode: Mode) -> bool {
        self.term.mode(mode).unwrap_or(false)
    }

    /// Rows scrolled back from the bottom. 0 means the live screen.
    fn scrollback(&self) -> usize {
        self.term
            .scrollbar()
            .map(|s| s.total.saturating_sub(s.offset + s.len) as usize)
            .unwrap_or(0)
    }

    /// Turns a key press into the bytes the agent expects, following the
    /// modes it turned on (cursor keys, Kitty keyboard protocol, ...).
    fn encode_key(&mut self, key: KeyEvent) -> Vec<u8> {
        let mut out = Vec::new();
        let kitty = self
            .term
            .kitty_keyboard_flags()
            .is_ok_and(|f| !f.is_empty());
        // Without the Kitty protocol a terminal can't send Shift+Enter.
        // Both Claude and Codex read ESC + CR as "insert a newline".
        if !kitty
            && key.code == KeyCode::Enter
            && key
                .modifiers
                .intersects(KeyModifiers::SHIFT | KeyModifiers::ALT)
        {
            out.extend_from_slice(b"\x1b\r");
            return out;
        }
        let Some((k, text, unshifted)) = ghostty_key(key.code) else {
            return out;
        };
        let mods = ghostty_mods(key.modifiers);
        // A shifted character like `A` or `!` already includes the shift.
        let consumed = if text.is_some() && mods.contains(key::Mods::SHIFT) {
            key::Mods::SHIFT
        } else {
            key::Mods::empty()
        };
        let action = match key.kind {
            KeyEventKind::Press => key::Action::Press,
            KeyEventKind::Repeat => key::Action::Repeat,
            KeyEventKind::Release => key::Action::Release,
        };
        self.key_event
            .set_action(action)
            .set_key(k)
            .set_mods(mods)
            .set_consumed_mods(consumed)
            .set_unshifted_codepoint(unshifted)
            .set_utf8(text);
        let _ = self
            .keys
            .set_options_from_terminal(&self.term)
            .set_macos_option_as_alt(key::OptionAsAlt::True)
            .encode_to_vec(&self.key_event, &mut out);
        out
    }

    /// Draws the emulator screen into `area`. Returns the cursor position
    /// in absolute coordinates if it should be shown.
    fn render(&mut self, area: Rect, buf: &mut Buffer) -> Option<(u16, u16)> {
        let scrolled = self.scrollback() > 0;
        let Emu {
            term,
            render,
            rows,
            cells,
            ..
        } = self;
        let snapshot = render.update(term).ok()?;
        let cursor = snapshot
            .cursor_visible()
            .unwrap_or(false)
            .then(|| snapshot.cursor_viewport().ok().flatten())
            .flatten();
        let mut row_iter = rows.update(&snapshot).ok()?;
        let mut text = String::new();
        let mut y = 0;
        while let Some(row) = row_iter.next() {
            if y >= area.height {
                break;
            }
            let Ok(mut cell_iter) = cells.update(row) else {
                break;
            };
            let mut x = 0;
            while let Some(cell) = cell_iter.next() {
                if x >= area.width {
                    break;
                }
                let raw = cell.raw_cell().ok();
                // The right half of a wide character is drawn by its left half.
                if raw.and_then(|c| c.wide().ok()) == Some(CellWide::SpacerTail) {
                    x += 1;
                    continue;
                }
                text.clear();
                let _ = cell.graphemes_utf8(&mut text);
                if text.is_empty() {
                    text.push(' ');
                }
                let mut style = Style::default();
                if cell.has_styling().unwrap_or(false)
                    && let Ok(s) = cell.style()
                {
                    style = style.fg(color(s.fg_color)).bg(color(s.bg_color));
                    if let StyleColor::Palette(_) | StyleColor::Rgb(_) = s.underline_color {
                        style = style.underline_color(color(s.underline_color));
                    }
                    let mut mods = Modifier::empty();
                    for (on, m) in [
                        (s.bold, Modifier::BOLD),
                        (s.faint, Modifier::DIM),
                        (s.italic, Modifier::ITALIC),
                        (s.underline != Underline::None, Modifier::UNDERLINED),
                        (s.blink, Modifier::SLOW_BLINK),
                        (s.inverse, Modifier::REVERSED),
                        (s.invisible, Modifier::HIDDEN),
                        (s.strikethrough, Modifier::CROSSED_OUT),
                    ] {
                        if on {
                            mods |= m;
                        }
                    }
                    style = style.add_modifier(mods);
                }
                // Erased cells keep only a background color, with no style.
                if let Some(c) = raw {
                    match c.content_tag() {
                        Ok(CellContentTag::BgColorPalette) => {
                            if let Ok(i) = c.bg_color_palette() {
                                style = style.bg(Color::Indexed(i.0));
                            }
                        }
                        Ok(CellContentTag::BgColorRgb) => {
                            if let Ok(rgb) = c.bg_color_rgb() {
                                style = style.bg(Color::Rgb(rgb.r, rgb.g, rgb.b));
                            }
                        }
                        _ => {}
                    }
                }
                if let Some(c) = buf.cell_mut((area.x + x, area.y + y)) {
                    c.set_symbol(&text).set_style(style);
                }
                x += 1;
            }
            y += 1;
        }
        if scrolled {
            return None;
        }
        let c = cursor?;
        (c.y < area.height && c.x < area.width).then_some((area.x + c.x, area.y + c.y))
    }
}

pub struct Term {
    pub id: u64,
    /// The child's process id.
    pub pid: Option<u32>,
    emu: RefCell<Emu>,
    /// Raw output from the reader thread, not yet given to the emulator.
    output: Receiver<Vec<u8>>,
    writer: RefCell<Box<dyn Write + Send>>,
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn Child + Send + Sync>,
    last_output_ms: Arc<AtomicU64>,
    /// When we last sent the agent input from the user. 0 means never.
    last_input_ms: Cell<u64>,
    /// When the current stretch of output started, or None while quiet.
    busy_since_ms: Option<u64>,
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
        let emu = Emu::new(rows, cols)?;
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
        let writer = pair.master.take_writer()?;
        let last_output_ms = Arc::new(AtomicU64::new(0));
        let (output_tx, output) = channel();

        {
            let last_output_ms = last_output_ms.clone();
            std::thread::spawn(move || {
                let mut buf = vec![0u8; 64 * 1024];
                loop {
                    let n = match reader.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => n,
                    };
                    if output_tx.send(buf[..n].to_vec()).is_err() {
                        break;
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
            emu: RefCell::new(emu),
            output,
            writer: RefCell::new(writer),
            master: pair.master,
            child,
            last_output_ms,
            last_input_ms: Cell::new(0),
            busy_since_ms: None,
            exit_code: None,
        })
    }

    /// Feeds the output that arrived since the last call to the emulator
    /// and sends back its answers to queries. Must be called for every
    /// terminal, shown or not: agents wait for those answers.
    pub fn pump(&self) {
        let mut emu = self.emu.borrow_mut();
        while let Ok(bytes) = self.output.try_recv() {
            emu.term.vt_write(&bytes);
        }
        let replies = std::mem::take(&mut *emu.replies.borrow_mut());
        drop(emu);
        if !replies.is_empty() {
            let mut w = self.writer.borrow_mut();
            let _ = w.write_all(&replies);
            let _ = w.flush();
        }
    }

    pub fn is_running(&self) -> bool {
        self.exit_code.is_none()
    }

    /// Called after the reader saw EOF; reaps the child.
    pub fn mark_exited(&mut self) {
        self.pump();
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

    /// Call on every tick. True once when the agent goes quiet after
    /// working on something the user asked for, e.g. it finished a task or
    /// stopped at a permission prompt.
    pub fn finished_work(&mut self) -> bool {
        match (self.is_busy(), self.busy_since_ms) {
            (true, None) => {
                self.busy_since_ms = Some(now_ms());
                false
            }
            (false, Some(start)) => {
                self.busy_since_ms = None;
                self.is_running()
                    && is_real_work(
                        start,
                        self.last_input_ms.get(),
                        self.last_output_ms.load(Ordering::Relaxed),
                    )
            }
            _ => false,
        }
    }

    /// DEC mode 2026: the app is in the middle of drawing a frame.
    pub fn synchronized(&self) -> bool {
        self.emu.borrow().mode(Mode::SYNC_OUTPUT)
    }

    pub fn resize(&self, rows: u16, cols: u16) {
        let rows = rows.max(2);
        let cols = cols.max(10);
        let mut emu = self.emu.borrow_mut();
        if (emu.term.rows().ok(), emu.term.cols().ok()) == (Some(rows), Some(cols)) {
            return;
        }
        // Ghostty re-wraps long lines to the new width, scrollback too.
        let _ = emu.term.resize(cols, rows, 0, 0);
        drop(emu);
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
        self.last_input_ms.set(now_ms());
        let mut w = self.writer.borrow_mut();
        let _ = w.write_all(bytes);
        let _ = w.flush();
    }

    pub fn send_key(&self, key: KeyEvent) {
        let bytes = {
            let mut emu = self.emu.borrow_mut();
            emu.term.scroll_viewport(ScrollViewport::Bottom);
            emu.encode_key(key)
        };
        self.write(&bytes);
    }

    pub fn paste(&self, text: &str) {
        let bracketed = {
            let mut emu = self.emu.borrow_mut();
            emu.term.scroll_viewport(ScrollViewport::Bottom);
            emu.mode(Mode::BRACKETED_PASTE)
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
        let mut emu = self.emu.borrow_mut();
        let mode = if emu.mode(Mode::ANY_MOUSE) {
            MouseMode::AnyMotion
        } else if emu.mode(Mode::BUTTON_MOUSE) {
            MouseMode::ButtonMotion
        } else if emu.mode(Mode::NORMAL_MOUSE) {
            MouseMode::PressRelease
        } else if emu.mode(Mode::X10_MOUSE) {
            MouseMode::Press
        } else {
            MouseMode::None
        };
        if mode != MouseMode::None {
            let sgr = emu.mode(Mode::SGR_MOUSE);
            drop(emu);
            if let Some(bytes) = encode_mouse(ev, col, row, mode, sgr) {
                self.write(&bytes);
            }
            return;
        }
        let up = match ev.kind {
            MouseEventKind::ScrollUp => true,
            MouseEventKind::ScrollDown => false,
            _ => return,
        };
        if emu.term.active_screen().ok() == Some(Screen::Alternate) {
            let app_cursor = emu.mode(Mode::DECCKM);
            drop(emu);
            let arrow = match (up, app_cursor) {
                (true, true) => "\x1bOA",
                (true, false) => "\x1b[A",
                (false, true) => "\x1bOB",
                (false, false) => "\x1b[B",
            };
            self.write(arrow.repeat(3).as_bytes());
        } else {
            emu.term
                .scroll_viewport(ScrollViewport::Delta(if up { -3 } else { 3 }));
        }
    }

    /// The visible screen as plain text.
    #[cfg(test)]
    pub fn screen_text(&self) -> String {
        self.pump();
        let mut emu = self.emu.borrow_mut();
        let Emu {
            term,
            render,
            rows,
            cells,
            ..
        } = &mut *emu;
        let mut lines = Vec::new();
        let Ok(snapshot) = render.update(term) else {
            return String::new();
        };
        let Ok(mut row_iter) = rows.update(&snapshot) else {
            return String::new();
        };
        let mut text = String::new();
        while let Some(row) = row_iter.next() {
            let mut line = String::new();
            if let Ok(mut cell_iter) = cells.update(row) {
                while let Some(cell) = cell_iter.next() {
                    text.clear();
                    if cell.graphemes_utf8(&mut text).is_ok() && !text.is_empty() {
                        line.push_str(&text);
                    } else if !cell
                        .raw_cell()
                        .and_then(|c| c.wide())
                        .is_ok_and(|w| w == CellWide::SpacerTail)
                    {
                        line.push(' ');
                    }
                }
            }
            lines.push(line.trim_end().to_string());
        }
        while lines.last().is_some_and(|l| l.is_empty()) {
            lines.pop();
        }
        lines.join("\n")
    }

    pub fn scrollback(&self) -> usize {
        self.emu.borrow().scrollback()
    }

    /// Draws the emulator screen into `area`. Returns the cursor position
    /// in absolute coordinates if it should be shown.
    pub fn render(&self, area: Rect, buf: &mut Buffer) -> Option<(u16, u16)> {
        self.emu.borrow_mut().render(area, buf)
    }
}

impl Drop for Term {
    fn drop(&mut self) {
        self.kill();
    }
}

/// How long an agent must keep printing after the user's last input for
/// the stretch to count as work.
const MIN_WORK_MS: u64 = 3000;

/// True if output from `start` to `last_output` was real work: it went on
/// for a while after the user's last input. This skips echoed typing and
/// short redraws. No input at all means the agent was only starting up.
fn is_real_work(start: u64, last_input: u64, last_output: u64) -> bool {
    last_input > 0 && last_output.saturating_sub(start.max(last_input)) >= MIN_WORK_MS
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis() as u64
}

/// Keeps palette colors as palette indices, so they use the outer
/// terminal's theme.
fn color(c: StyleColor) -> Color {
    match c {
        StyleColor::None => Color::Reset,
        StyleColor::Palette(i) => Color::Indexed(i.0),
        StyleColor::Rgb(c) => Color::Rgb(c.r, c.g, c.b),
    }
}

fn ghostty_mods(m: KeyModifiers) -> key::Mods {
    let mut mods = key::Mods::empty();
    for (from, to) in [
        (KeyModifiers::SHIFT, key::Mods::SHIFT),
        (KeyModifiers::ALT, key::Mods::ALT),
        (KeyModifiers::CONTROL, key::Mods::CTRL),
        (KeyModifiers::SUPER, key::Mods::SUPER),
    ] {
        if m.contains(from) {
            mods |= to;
        }
    }
    mods
}

/// The Ghostty key for a crossterm key code, with the text it types and
/// its unshifted character. Crossterm only tells us the character, so we
/// guess the physical key from a US layout.
fn ghostty_key(code: KeyCode) -> Option<(key::Key, Option<String>, char)> {
    use key::Key as K;
    let named = |k| Some((k, None, '\0'));
    match code {
        KeyCode::Char(c) => {
            let (k, unshifted) = char_key(c);
            let text = (!c.is_control()).then(|| c.to_string());
            Some((k, text, unshifted))
        }
        KeyCode::Enter => named(K::Enter),
        KeyCode::Tab | KeyCode::BackTab => named(K::Tab),
        KeyCode::Backspace => named(K::Backspace),
        KeyCode::Esc => named(K::Escape),
        KeyCode::Up => named(K::ArrowUp),
        KeyCode::Down => named(K::ArrowDown),
        KeyCode::Right => named(K::ArrowRight),
        KeyCode::Left => named(K::ArrowLeft),
        KeyCode::Home => named(K::Home),
        KeyCode::End => named(K::End),
        KeyCode::Insert => named(K::Insert),
        KeyCode::Delete => named(K::Delete),
        KeyCode::PageUp => named(K::PageUp),
        KeyCode::PageDown => named(K::PageDown),
        KeyCode::F(n @ 1..=24) => named(K::try_from(K::F1 as u32 + u32::from(n) - 1).ok()?),
        _ => None,
    }
}

/// The physical key for a character on a US layout, and the character the
/// key types without Shift.
fn char_key(c: char) -> (key::Key, char) {
    use key::Key as K;
    let offset = |base: K, n: u32| K::try_from(base as u32 + n).unwrap_or(K::Unidentified);
    let lower = c.to_ascii_lowercase();
    if lower.is_ascii_lowercase() {
        return (offset(K::A, (lower as u8 - b'a').into()), lower);
    }
    if c.is_ascii_digit() {
        return (offset(K::Digit0, (c as u8 - b'0').into()), c);
    }
    const SHIFTED_DIGITS: &str = ")!@#$%^&*(";
    if let Some(d) = SHIFTED_DIGITS.find(c) {
        return (offset(K::Digit0, d as u32), (b'0' + d as u8) as char);
    }
    let (k, unshifted) = match c {
        ' ' => (K::Space, ' '),
        '-' | '_' => (K::Minus, '-'),
        '=' | '+' => (K::Equal, '='),
        '[' | '{' => (K::BracketLeft, '['),
        ']' | '}' => (K::BracketRight, ']'),
        '\\' | '|' => (K::Backslash, '\\'),
        ';' | ':' => (K::Semicolon, ';'),
        '\'' | '"' => (K::Quote, '\''),
        ',' | '<' => (K::Comma, ','),
        '.' | '>' => (K::Period, '.'),
        '/' | '?' => (K::Slash, '/'),
        '`' | '~' => (K::Backquote, '`'),
        _ => (K::Unidentified, c),
    };
    (k, unshifted)
}

/// Which mouse events the app asked for (DEC modes 9, 1000, 1002, 1003).
#[derive(Clone, Copy, PartialEq, Eq)]
enum MouseMode {
    None,
    Press,
    PressRelease,
    ButtonMotion,
    AnyMotion,
}

fn encode_mouse(ev: MouseEvent, col: u16, row: u16, mode: MouseMode, sgr: bool) -> Option<Vec<u8>> {
    let button_code = |b: MouseButton| match b {
        MouseButton::Left => 0u16,
        MouseButton::Middle => 1,
        MouseButton::Right => 2,
    };
    let (mut code, release) = match ev.kind {
        MouseEventKind::Down(b) => (button_code(b), false),
        MouseEventKind::Up(b) => {
            if mode == MouseMode::Press {
                return None;
            }
            (button_code(b), true)
        }
        MouseEventKind::Drag(b) => {
            if !matches!(mode, MouseMode::ButtonMotion | MouseMode::AnyMotion) {
                return None;
            }
            (button_code(b) + 32, false)
        }
        MouseEventKind::Moved => {
            if mode != MouseMode::AnyMotion {
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
    if sgr {
        let end = if release { 'm' } else { 'M' };
        return Some(format!("\x1b[<{code};{x};{y}{end}").into_bytes());
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn real_work_needs_output_long_after_input() {
        // Enter at 10s, agent prints until 25s.
        assert!(is_real_work(9_000, 10_000, 25_000));
        // Echoed typing: output stops right after the last key.
        assert!(!is_real_work(5_000, 10_000, 10_050));
        // A short redraw long after the last input.
        assert!(!is_real_work(60_000, 10_000, 60_200));
        // Startup output before the user typed anything.
        assert!(!is_real_work(0, 0, 8_000));
    }

    #[test]
    fn parses_outer_terminal_replies() {
        let buf = b"\x1b]10;rgb:1a1a/1a1a/1a1a\x07\x1b]11;rgb:ffff/fcfc/f0f0\x1b\\\x1b[?62;22c";
        assert!(has_da1_reply(buf));
        assert_eq!(
            osc_color_reply(buf, 10).as_deref(),
            Some("rgb:1a1a/1a1a/1a1a")
        );
        assert_eq!(
            osc_color_reply(buf, 11).as_deref(),
            Some("rgb:ffff/fcfc/f0f0")
        );
        // A terminal that only knows DA1.
        assert!(has_da1_reply(b"\x1b[?1;2c"));
        assert_eq!(osc_color_reply(b"\x1b[?1;2c", 11), None);
        assert!(!has_da1_reply(b"\x1b]11;rgb:ffff/ffff/ffff\x1b\\"));
    }

    #[test]
    fn parses_rgb() {
        assert_eq!(parse_rgb("rgb:ffff/0000/ffff"), Some((1.0, 0.0, 1.0)));
        assert_eq!(parse_rgb("rgb:ff/80/00").map(|c| c.1 > 0.5), Some(true));
        assert_eq!(parse_rgb("rgb:f/f/f"), Some((1.0, 1.0, 1.0)));
        assert_eq!(parse_rgb("rgb:ffff/ffff"), None);
        assert_eq!(parse_rgb("rgb:fffff/0/0"), None);
        assert_eq!(parse_rgb("#ffffff"), None);
    }

    fn set_outer_colors() {
        let _ = OUTER_COLORS.set(OuterColors {
            fg: Some("rgb:1a1a/1a1a/1a1a".into()),
            bg: Some("rgb:ffff/fcfc/f0f0".into()),
        });
    }

    /// Feeds `input` to a fresh emulator and returns what it answers.
    fn replies(input: &[u8]) -> String {
        let mut emu = Emu::new(24, 80).unwrap();
        emu.term.vt_write(input);
        String::from_utf8(emu.replies.take()).unwrap()
    }

    #[test]
    fn answers_color_queries() {
        set_outer_colors();
        assert_eq!(
            replies(b"\x1b]11;?\x1b\\\x1b]10;?;?\x07"),
            "\x1b]11;rgb:ffff/fcfc/f0f0\x1b\\\
             \x1b]10;rgb:1a1a/1a1a/1a1a\x07\
             \x1b]11;rgb:ffff/fcfc/f0f0\x07"
        );
        // Light background.
        assert_eq!(replies(b"\x1b[?996n"), "\x1b[?997;2n");
    }

    #[test]
    fn answers_terminal_queries() {
        // Codex (crossterm) waits for these at startup.
        assert_eq!(replies(b"\x1b[3;5H\x1b[6n"), "\x1b[3;5R");
        assert!(replies(b"\x1b[c").starts_with("\x1b[?"));
        assert_eq!(replies(b"\x1b[?u"), "\x1b[?0u");
        assert_eq!(replies(b"\x1b[18t"), "\x1b[8;24;80t");
    }

    /// Encodes `key` after the agent printed `modes`.
    fn keys(modes: &[u8], code: KeyCode, m: KeyModifiers) -> String {
        let mut emu = Emu::new(24, 80).unwrap();
        emu.term.vt_write(modes);
        String::from_utf8(emu.encode_key(KeyEvent::new(code, m))).unwrap()
    }

    #[test]
    fn encodes_legacy_keys() {
        let none = KeyModifiers::NONE;
        let (shift, ctrl, alt) = (
            KeyModifiers::SHIFT,
            KeyModifiers::CONTROL,
            KeyModifiers::ALT,
        );
        assert_eq!(keys(b"", KeyCode::Char('a'), none), "a");
        assert_eq!(keys(b"", KeyCode::Char('A'), shift), "A");
        assert_eq!(keys(b"", KeyCode::Char('!'), shift), "!");
        assert_eq!(keys(b"", KeyCode::Char('é'), none), "é");
        assert_eq!(keys(b"", KeyCode::Char('c'), ctrl), "\x03");
        assert_eq!(keys(b"", KeyCode::Char('b'), alt), "\x1bb");
        assert_eq!(keys(b"", KeyCode::Enter, none), "\r");
        assert_eq!(keys(b"", KeyCode::Enter, shift), "\x1b\r");
        assert_eq!(keys(b"", KeyCode::Esc, none), "\x1b");
        assert_eq!(keys(b"", KeyCode::Backspace, none), "\x7f");
        assert_eq!(keys(b"", KeyCode::BackTab, shift), "\x1b[Z");
        assert_eq!(keys(b"", KeyCode::Up, none), "\x1b[A");
        assert_eq!(keys(b"\x1b[?1h", KeyCode::Up, none), "\x1bOA");
        assert_eq!(keys(b"", KeyCode::Up, ctrl), "\x1b[1;5A");
        assert_eq!(keys(b"", KeyCode::PageUp, none), "\x1b[5~");
        assert_eq!(keys(b"", KeyCode::F(1), none), "\x1bOP");
        assert_eq!(keys(b"", KeyCode::F(5), none), "\x1b[15~");
    }

    #[test]
    fn encodes_kitty_keys() {
        // What Claude Code and Codex turn on when the terminal supports it.
        let kitty = b"\x1b[>1u";
        let (shift, ctrl) = (KeyModifiers::SHIFT, KeyModifiers::CONTROL);
        assert_eq!(keys(kitty, KeyCode::Char('a'), KeyModifiers::NONE), "a");
        assert_eq!(keys(kitty, KeyCode::Enter, shift), "\x1b[13;2u");
        assert_eq!(keys(kitty, KeyCode::Char('c'), ctrl), "\x1b[99;5u");
        assert_eq!(keys(kitty, KeyCode::Esc, KeyModifiers::NONE), "\x1b[27u");
    }

    #[test]
    fn renders_cells() {
        let mut emu = Emu::new(3, 10).unwrap();
        // Palette red, 24-bit blue on bold text, a wide character, then an
        // erase with a palette background.
        emu.term
            .vt_write(b"\x1b[31mR\x1b[1;38;2;0;0;255mB\x1b[0m\xe4\xb8\xadx\r\n");
        emu.term.vt_write(b"\x1b[44m\x1b[K\x1b[0m\x1b[9mS");
        let area = Rect::new(0, 0, 10, 3);
        let mut buf = Buffer::empty(area);
        let cursor = emu.render(area, &mut buf);

        assert_eq!(buf[(0, 0)].symbol(), "R");
        assert_eq!(buf[(0, 0)].fg, Color::Indexed(1));
        assert_eq!(buf[(1, 0)].fg, Color::Rgb(0, 0, 255));
        assert!(buf[(1, 0)].modifier.contains(Modifier::BOLD));
        assert_eq!(buf[(2, 0)].symbol(), "中");
        assert_eq!(buf[(4, 0)].symbol(), "x");
        assert_eq!(buf[(0, 1)].symbol(), "S");
        assert!(buf[(0, 1)].modifier.contains(Modifier::CROSSED_OUT));
        assert_eq!(buf[(5, 1)].bg, Color::Indexed(4));
        assert_eq!(buf[(5, 2)].bg, Color::Reset);
        assert_eq!(cursor, Some((1, 1)));
    }

    #[test]
    fn reflows_on_resize() {
        let mut emu = Emu::new(5, 20).unwrap();
        emu.term.vt_write(b"0123456789abcdefghij0123456789\r\n");
        emu.term.resize(40, 5, 0, 0).unwrap();
        let mut row_text = Vec::new();
        let Emu {
            term,
            render,
            rows,
            cells,
            ..
        } = &mut emu;
        let snapshot = render.update(term).unwrap();
        let mut row_iter = rows.update(&snapshot).unwrap();
        while let Some(row) = row_iter.next() {
            let mut line = String::new();
            let mut cell_iter = cells.update(row).unwrap();
            let mut text = String::new();
            while let Some(cell) = cell_iter.next() {
                text.clear();
                cell.graphemes_utf8(&mut text).unwrap();
                line.push_str(if text.is_empty() { " " } else { &text });
            }
            row_text.push(line.trim_end().to_string());
        }
        // One line again, instead of the first 20 characters cut off.
        assert_eq!(row_text[0], "0123456789abcdefghij0123456789");
    }
}
