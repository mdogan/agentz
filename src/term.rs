//! One agent process running in its own PTY, with a Ghostty emulator
//! (libghostty-vt) that keeps its screen. The process keeps running whether
//! or not it is shown.
//!
//! libghostty-vt types can't leave the thread that made them. So the PTY
//! reader thread only passes the raw bytes on, and the main thread feeds
//! them to the emulator in `pump`.

use std::cell::{Cell, RefCell};
use std::io::{Read, Write};
use std::path::PathBuf;
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
use libghostty_vt::terminal::{
    ColorScheme, DesktopNotification, Mode, ProgressReport, ProgressState, ScrollViewport,
    SizeReportSize,
};
use libghostty_vt::{RenderState, Terminal, key, mouse};
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

/// Something the program told the terminal through an escape sequence,
/// other than drawing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Signal {
    /// BEL.
    Bell,
    /// OSC 9 or OSC 777: show a desktop notification.
    Notify { title: String, body: String },
    /// OSC 9;4: show or hide a progress indicator.
    Progress(ProgressState),
    /// OSC 7 and friends: the working directory changed.
    PwdChanged,
    /// OSC 0/2: the window title changed.
    TitleChanged,
}

/// The emulator and the objects it needs to read its screen and encode
/// keys and mouse events. Everything here lives on the main thread.
struct Emu {
    term: Terminal<'static, 'static>,
    render: RenderState<'static>,
    rows: RowIterator<'static>,
    cells: CellIterator<'static>,
    keys: key::Encoder<'static>,
    key_event: key::Event<'static>,
    mouse: mouse::Encoder<'static>,
    mouse_event: mouse::Event<'static>,
    /// Answers to queries (cursor position, colors, ...) that go back to
    /// the agent.
    replies: Rc<RefCell<Vec<u8>>>,
    signals: Rc<RefCell<Vec<Signal>>>,
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
        let signals = Rc::new(RefCell::new(Vec::new()));
        let push = |signals: &Rc<RefCell<Vec<Signal>>>| {
            let signals = signals.clone();
            move |s: Signal| signals.borrow_mut().push(s)
        };
        let send = push(&signals);
        term.on_bell(move |_| send(Signal::Bell)).map_err(ghostty)?;
        let send = push(&signals);
        term.on_desktop_notification(move |_, n: DesktopNotification<'_>| {
            send(Signal::Notify {
                title: n.title().to_string(),
                body: n.body().to_string(),
            })
        })
        .map_err(ghostty)?;
        let send = push(&signals);
        term.on_progress_report(move |_, p: ProgressReport<'_>| {
            if let Ok(state) = p.state() {
                send(Signal::Progress(state));
            }
        })
        .map_err(ghostty)?;
        let send = push(&signals);
        term.on_pwd_changed(move |_| send(Signal::PwdChanged))
            .map_err(ghostty)?;
        let send = push(&signals);
        term.on_title_changed(move |_| send(Signal::TitleChanged))
            .map_err(ghostty)?;
        Ok(Emu {
            term,
            render: RenderState::new().map_err(ghostty)?,
            rows: RowIterator::new().map_err(ghostty)?,
            cells: CellIterator::new().map_err(ghostty)?,
            keys: key::Encoder::new().map_err(ghostty)?,
            key_event: key::Event::new().map_err(ghostty)?,
            mouse: mouse::Encoder::new().map_err(ghostty)?,
            mouse_event: mouse::Event::new().map_err(ghostty)?,
            replies,
            signals,
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

    /// True if the agent asked for mouse reports (DEC modes 9, 1000,
    /// 1002, 1003).
    fn wants_mouse(&self) -> bool {
        [
            Mode::X10_MOUSE,
            Mode::NORMAL_MOUSE,
            Mode::BUTTON_MOUSE,
            Mode::ANY_MOUSE,
        ]
        .into_iter()
        .any(|m| self.mode(m))
    }

    /// Turns a mouse event at (col, row) into the report the agent asked
    /// for, in the format it turned on (X10, SGR, ...). Empty if its mouse
    /// mode doesn't report this event, e.g. motion in mode 1000.
    fn encode_mouse(&mut self, ev: MouseEvent, col: u16, row: u16) -> Vec<u8> {
        use mouse::{Action, Button};
        let button = |b: MouseButton| match b {
            MouseButton::Left => Button::Left,
            MouseButton::Middle => Button::Middle,
            MouseButton::Right => Button::Right,
        };
        let (action, button) = match ev.kind {
            MouseEventKind::Down(b) => (Action::Press, Some(button(b))),
            MouseEventKind::Up(b) => (Action::Release, Some(button(b))),
            MouseEventKind::Drag(b) => (Action::Motion, Some(button(b))),
            MouseEventKind::Moved => (Action::Motion, None),
            MouseEventKind::ScrollUp => (Action::Press, Some(Button::Four)),
            MouseEventKind::ScrollDown => (Action::Press, Some(Button::Five)),
            MouseEventKind::ScrollLeft => (Action::Press, Some(Button::Six)),
            MouseEventKind::ScrollRight => (Action::Press, Some(Button::Seven)),
        };
        // Ghostty wants pixels, but we only know cells. With 1x1 pixel
        // cells the pixel position is the cell position.
        let size = mouse::EncoderSize {
            screen_width: self.term.cols().unwrap_or(0).into(),
            screen_height: self.term.rows().unwrap_or(0).into(),
            cell_width: 1,
            cell_height: 1,
            padding_top: 0,
            padding_bottom: 0,
            padding_right: 0,
            padding_left: 0,
        };
        self.mouse_event
            .set_action(action)
            .set_button(button)
            .set_mods(ghostty_mods(ev.modifiers))
            .set_position(mouse::Position {
                x: col.into(),
                y: row.into(),
            });
        let mut out = Vec::new();
        let _ = self
            .mouse
            .set_options_from_terminal(&self.term)
            .set_size(size)
            .set_any_button_pressed(matches!(ev.kind, MouseEventKind::Drag(_)))
            .encode_to_vec(&self.mouse_event, &mut out);
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

/// What `Term::update` found.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Update {
    /// Tell the user the agent wants attention, with the agent's own
    /// message if it sent one (OSC 9/777).
    pub notice: Option<Option<String>>,
    /// The new working directory the program reported (OSC 7).
    pub cwd: Option<PathBuf>,
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
    /// Whether the program says it is working, from progress reports
    /// (OSC 9;4) or a spinner in its title. None until it tells us.
    reported_busy: Option<bool>,
    /// Once a program sent a progress report, we ignore its title.
    has_progress: bool,
    was_busy: bool,
    /// When the current stretch of work started.
    busy_since_ms: u64,
    /// True once the user heard about the current turn.
    notified: Cell<bool>,
    /// The focus state we last reported to the program.
    focus_sent: Cell<Option<bool>>,
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
            reported_busy: None,
            has_progress: false,
            was_busy: false,
            busy_since_ms: 0,
            notified: Cell::new(false),
            focus_sent: Cell::new(None),
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

    /// The window title the program last set (OSC 0/2).
    pub fn title(&self) -> Option<String> {
        let emu = self.emu.borrow();
        let title = emu.term.title().ok()?;
        (!title.is_empty()).then(|| title.to_string())
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

    /// True if the program is working. We trust what it tells us (progress
    /// reports or a title spinner). If it never told us, it is working
    /// while it prints.
    pub fn is_busy(&self) -> bool {
        self.is_running()
            && self.reported_busy.unwrap_or_else(|| {
                let last = self.last_output_ms.load(Ordering::Relaxed);
                now_ms().saturating_sub(last) < 1500
            })
    }

    /// True if the program started another one in the foreground, like a
    /// shell running a command: then the terminal belongs to another
    /// process group.
    pub fn has_foreground_job(&self) -> bool {
        #[cfg(unix)]
        if let (true, Some(pid), Some(group)) = (
            self.is_running(),
            self.pid,
            self.master.process_group_leader(),
        ) {
            return group as u32 != pid;
        }
        false
    }

    /// Forgets what the program said about being busy, e.g. when the agent
    /// in a shell exits and the shell is left.
    pub fn forget_reported_busy(&mut self) {
        self.reported_busy = None;
        self.has_progress = false;
    }

    /// Call after `pump`, on every tick. Reads what the program signaled
    /// and tells whether the user should hear about it.
    pub fn update(&mut self) -> Update {
        let mut update = Update::default();
        let mut agent_notice = None;
        let signals = self.emu.borrow().signals.take();
        for signal in signals {
            match signal {
                Signal::Progress(state) => {
                    self.has_progress = true;
                    self.reported_busy = Some(matches!(
                        state,
                        ProgressState::Set | ProgressState::Indeterminate
                    ));
                }
                Signal::TitleChanged if !self.has_progress => {
                    let title = self.title().unwrap_or_default();
                    if let Some(busy) = title_busy(&title, self.reported_busy.is_some()) {
                        self.reported_busy = Some(busy);
                    }
                }
                Signal::Notify { title, body } => {
                    let text = if body.is_empty() { title } else { body };
                    agent_notice = Some(text.trim().to_string());
                }
                Signal::PwdChanged => {
                    let pwd = self.emu.borrow().term.pwd().map(pwd_path);
                    update.cwd = pwd.ok().flatten();
                }
                _ => {}
            }
        }

        let busy = self.is_busy();
        let finished = match (self.was_busy, busy) {
            (false, true) => {
                self.busy_since_ms = now_ms();
                false
            }
            (true, false) => {
                let (start, input) = (self.busy_since_ms, self.last_input_ms.get());
                if self.reported_busy.is_some() {
                    input > 0
                } else {
                    let output = self.last_output_ms.load(Ordering::Relaxed);
                    is_real_work(start, input, output)
                }
            }
            _ => false,
        };
        self.was_busy = busy;

        // One notice per turn, and none before the user asked anything.
        if self.is_running() && self.last_input_ms.get() > 0 && !self.notified.get() {
            if let Some(text) = agent_notice {
                update.notice = Some((!text.is_empty()).then_some(text));
            } else if finished {
                update.notice = Some(None);
            }
            self.notified.set(update.notice.is_some());
        }
        update
    }

    /// Tells the program whether the user is looking at it (DEC mode
    /// 1004), if it asked to know. Codex only sends its notifications
    /// while it is not looked at.
    pub fn set_focused(&self, focused: bool) {
        if self.focus_sent.get() == Some(focused)
            || !self.is_running()
            || !self.emu.borrow().mode(Mode::FOCUS_EVENT)
        {
            return;
        }
        self.focus_sent.set(Some(focused));
        self.write_raw(if focused { b"\x1b[I" } else { b"\x1b[O" });
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

    /// Sends input from the user. It starts a new turn: the agent may
    /// notify again when it is done.
    pub fn write(&self, bytes: &[u8]) {
        if bytes.is_empty() || !self.is_running() {
            return;
        }
        self.last_input_ms.set(now_ms());
        self.notified.set(false);
        self.write_raw(bytes);
    }

    fn write_raw(&self, bytes: &[u8]) {
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
        if emu.wants_mouse() {
            let bytes = emu.encode_mouse(ev, col, row);
            drop(emu);
            if !bytes.is_empty() {
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

    fn mouse(modes: &[u8], kind: MouseEventKind, m: KeyModifiers) -> Vec<u8> {
        let mut emu = Emu::new(24, 80).unwrap();
        emu.term.vt_write(modes);
        let ev = MouseEvent {
            kind,
            column: 4,
            row: 2,
            modifiers: m,
        };
        emu.encode_mouse(ev, ev.column, ev.row)
    }

    #[test]
    fn encodes_mouse() {
        let none = KeyModifiers::NONE;
        let left = MouseButton::Left;
        let sgr = b"\x1b[?1000h\x1b[?1006h";
        assert_eq!(
            mouse(sgr, MouseEventKind::Down(left), none),
            b"\x1b[<0;5;3M"
        );
        assert_eq!(mouse(sgr, MouseEventKind::Up(left), none), b"\x1b[<0;5;3m");
        assert_eq!(
            mouse(sgr, MouseEventKind::ScrollUp, KeyModifiers::CONTROL),
            b"\x1b[<80;5;3M"
        );
        // Mode 1000 doesn't report motion, 1002 reports drags.
        assert_eq!(mouse(sgr, MouseEventKind::Drag(left), none), b"");
        let drag = b"\x1b[?1002h\x1b[?1006h";
        assert_eq!(
            mouse(drag, MouseEventKind::Drag(left), none),
            b"\x1b[<32;5;3M"
        );
        // Legacy format: release is button 3, everything is +32.
        let x10 = b"\x1b[?1000h";
        assert_eq!(mouse(x10, MouseEventKind::Down(left), none), b"\x1b[M %#");
        assert_eq!(mouse(x10, MouseEventKind::Up(left), none), b"\x1b[M#%#");
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

    /// Runs `script` in `sh` and calls `update` until `until` says stop.
    fn run_script(script: &str, input: bool, until: impl Fn(&Update) -> bool) -> (Term, Update) {
        let mut cmd = CommandBuilder::new("sh");
        cmd.args(["-c", script]);
        let (tx, _) = channel();
        let mut term = Term::spawn(0, cmd, 24, 80, tx, Arc::new(AtomicBool::new(false))).unwrap();
        if input {
            // The user asked something; `sh` ignores it.
            term.write(b"\x1b");
        }
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(5) {
            term.pump();
            let update = term.update();
            if until(&update) {
                return (term, update);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        panic!("script did not signal in time");
    }

    #[test]
    fn progress_end_is_a_notice() {
        let script = r"printf '\033]9;4;3\007'; sleep 0.2; printf '\033]9;4;0\007'; sleep 5";
        let (term, update) = run_script(script, true, |u| u.notice.is_some());
        assert_eq!(update.notice, Some(None));
        assert!(!term.is_busy());
    }

    #[test]
    fn sees_a_shell_running_a_command() {
        let mut cmd = CommandBuilder::new("sh");
        cmd.arg("-i");
        let (tx, _) = channel();
        let term = Term::spawn(0, cmd, 24, 80, tx, Arc::new(AtomicBool::new(false))).unwrap();
        let wait_for = |want: bool| {
            let start = Instant::now();
            while term.has_foreground_job() != want {
                assert!(start.elapsed() < Duration::from_secs(5), "expected {want}");
                term.pump();
                std::thread::sleep(Duration::from_millis(20));
            }
        };
        wait_for(false);
        term.write(b"sleep 0.5\n");
        wait_for(true);
        wait_for(false);
    }

    #[test]
    fn forwards_agent_notification_once() {
        let script = r"printf '\033]9;4;3\007\033]777;notify;Codex;Done: OK\033\\'; sleep 0.2; printf '\033]9;4;0\007'; sleep 5";
        let (mut term, update) = run_script(script, true, |u| u.notice.is_some());
        assert_eq!(update.notice, Some(Some("Done: OK".into())));
        // The progress end right after is the same turn.
        std::thread::sleep(Duration::from_millis(400));
        term.pump();
        assert_eq!(term.update().notice, None);
        assert!(!term.is_busy());
    }

    #[test]
    fn no_notice_before_the_user_typed() {
        let script = r"printf '\033]9;4;3\007'; sleep 0.2; printf '\033]9;4;0\007'; sleep 1; printf '\033]7;file://h/done\007'; sleep 5";
        let (_, update) = run_script(script, false, |u| u.cwd.is_some() || u.notice.is_some());
        assert_eq!(update.notice, None);
        assert_eq!(update.cwd, Some(PathBuf::from("/done")));
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
