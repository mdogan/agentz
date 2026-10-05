//! What the server keeps of a program's output, to show its screen again to
//! an app that attaches later: the recent output, and the terminal modes
//! from before it.
//!
//! Replaying the output into a fresh terminal draws the screen again, but
//! only if the terminal is in the modes the program set. Those modes (the
//! alternate screen, the Kitty keyboard flags, bracketed paste, mouse
//! reports) also decide how keys and pastes reach the program, so they must
//! be right even after the output that set them was dropped to save memory.
//!
//! Queries (cursor position, colors, device attributes, ...) are left out:
//! the new terminal would answer them again, and the answers would reach
//! the program as typed text.

use std::collections::BTreeMap;

/// Output kept per program. Claude and Codex redraw their whole screen on a
/// resize, which the server asks for when an app attaches, so this only has
/// to cover what a program does not redraw.
pub const KEEP: usize = 10 << 20;

/// A sequence longer than this is not a query: it goes to the output as it
/// arrives instead of waiting for its end, e.g. an image.
const LONG: usize = 4096;

const ESC: u8 = 0x1b;
const BEL: u8 = 0x07;
const CAN: u8 = 0x18;
const SUB: u8 = 0x1a;

pub struct Screen {
    /// Reads new output: knows the modes at the end of `bytes`.
    live: Parser,
    /// Reads what is dropped from `bytes`: knows the modes at its start.
    base: Parser,
    /// Recent output, without queries.
    bytes: Vec<u8>,
    limit: usize,
}

impl Screen {
    pub fn new(limit: usize) -> Self {
        Screen {
            live: Parser::default(),
            base: Parser::default(),
            bytes: Vec::new(),
            limit,
        }
    }

    pub fn push(&mut self, output: &[u8]) {
        self.live.feed(output, &mut self.bytes);
        if self.bytes.len() > self.limit {
            self.trim();
        }
    }

    /// Drops the oldest output, down to three quarters of the limit. The cut
    /// falls between sequences and characters, so what is left starts clean.
    fn trim(&mut self) {
        let want = self.bytes.len() - self.limit / 4 * 3;
        let mut sink = Vec::new();
        let mut cut = 0;
        while cut < self.bytes.len() {
            let b = self.bytes[cut];
            if cut >= want && self.base.state == State::Ground && !is_continuation(b) {
                break;
            }
            self.base.byte(b, &mut sink);
            sink.clear();
            cut += 1;
        }
        self.bytes.drain(..cut);
    }

    /// What redraws the screen in a fresh terminal: the modes from before
    /// the kept output, then the output.
    pub fn replay(&self) -> Vec<u8> {
        let mut out = self.base.modes.prelude();
        out.extend_from_slice(&self.bytes);
        // The start of a sequence whose end has not arrived yet. The rest
        // comes as live output.
        out.extend_from_slice(&self.live.seq);
        out
    }
}

fn is_continuation(b: u8) -> bool {
    b & 0xc0 == 0x80
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum State {
    #[default]
    Ground,
    Escape,
    /// `ESC` and intermediates, e.g. `ESC ( B`.
    EscInter,
    Csi,
    /// OSC (`osc`), or DCS, APC, PM or SOS: a string up to ST (or BEL for
    /// OSC).
    Str {
        osc: bool,
    },
    /// An `ESC` inside a string: ST if `\` follows.
    StrEsc {
        osc: bool,
    },
    /// A long string, passed through as it arrives.
    Pass {
        osc: bool,
    },
    PassEsc {
        osc: bool,
    },
}

/// Splits output into text and escape sequences, keeps track of the modes
/// they set, and leaves queries out.
#[derive(Default)]
struct Parser {
    state: State,
    /// The sequence being read, from its `ESC`.
    seq: Vec<u8>,
    modes: Modes,
}

impl Parser {
    /// Appends `input` to `out`, except queries. An unfinished sequence
    /// waits in `seq` for the next call.
    fn feed(&mut self, input: &[u8], out: &mut Vec<u8>) {
        for &b in input {
            self.byte(b, out);
        }
    }

    fn byte(&mut self, b: u8, out: &mut Vec<u8>) {
        match self.state {
            State::Ground => {
                if b == ESC {
                    self.begin();
                } else {
                    out.push(b);
                }
            }
            State::Escape => match b {
                ESC => {
                    // A new sequence: the old one is left as it was.
                    out.append(&mut self.seq);
                    self.begin();
                }
                CAN | SUB => self.abort(b, out),
                _ => {
                    self.seq.push(b);
                    self.state = match b {
                        b'[' => State::Csi,
                        b']' => State::Str { osc: true },
                        b'P' | b'_' | b'^' | b'X' => State::Str { osc: false },
                        0x20..=0x2f => State::EscInter,
                        0x30..=0x7e => return self.finish(out),
                        // Controls run where they are; keep them in place.
                        _ => State::Escape,
                    };
                }
            },
            State::EscInter | State::Csi => match b {
                ESC => {
                    out.append(&mut self.seq);
                    self.begin();
                }
                CAN | SUB => self.abort(b, out),
                _ => {
                    self.seq.push(b);
                    let fin = if self.state == State::Csi {
                        (0x40..=0x7e).contains(&b)
                    } else {
                        (0x30..=0x7e).contains(&b)
                    };
                    if fin {
                        self.finish(out);
                    } else if self.seq.len() > LONG {
                        // Not a sequence we know; leave it as it is.
                        out.append(&mut self.seq);
                        self.state = State::Ground;
                    }
                }
            },
            State::Str { osc } => match b {
                BEL if osc => {
                    self.seq.push(b);
                    self.finish(out);
                }
                ESC => {
                    self.seq.push(b);
                    self.state = State::StrEsc { osc };
                }
                CAN | SUB => self.abort(b, out),
                _ => {
                    self.seq.push(b);
                    if self.seq.len() > LONG {
                        out.append(&mut self.seq);
                        self.state = State::Pass { osc };
                    }
                }
            },
            State::StrEsc { .. } => {
                if b == b'\\' {
                    self.seq.push(b);
                    self.finish(out);
                } else {
                    // The ESC ended the string and starts a new sequence.
                    self.seq.pop();
                    self.finish(out);
                    self.begin();
                    self.byte(b, out);
                }
            }
            State::Pass { osc } => match b {
                ESC => self.state = State::PassEsc { osc },
                BEL if osc => {
                    out.push(b);
                    self.state = State::Ground;
                }
                CAN | SUB => {
                    out.push(b);
                    self.state = State::Ground;
                }
                _ => out.push(b),
            },
            State::PassEsc { .. } => {
                if b == b'\\' {
                    out.extend_from_slice(&[ESC, b]);
                    self.state = State::Ground;
                } else {
                    self.state = State::Ground;
                    self.begin();
                    self.byte(b, out);
                }
            }
        }
    }

    fn begin(&mut self) {
        self.seq.clear();
        self.seq.push(ESC);
        self.state = State::Escape;
    }

    /// CAN and SUB cancel a sequence. The terminal shows nothing for it.
    fn abort(&mut self, b: u8, out: &mut Vec<u8>) {
        out.append(&mut self.seq);
        out.push(b);
        self.state = State::Ground;
    }

    /// A whole sequence is in `seq`: track what it sets, and pass it on
    /// unless it is a query.
    fn finish(&mut self, out: &mut Vec<u8>) {
        if self.modes.apply(&self.seq) {
            out.extend_from_slice(&self.seq);
        }
        self.seq.clear();
        self.state = State::Ground;
    }
}

/// Private modes (`CSI ? n h`) worth carrying over: how keys, mouse and
/// pastes are sent, and how the cursor looks.
const TRACKED: &[u16] = &[
    1, 5, 7, 12, 25, 45, 66, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1015, 1016, 2004, 2027,
    2031, 2048,
];

/// Kitty keyboard flags of one screen: a value under a stack of pushed ones.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Kitty {
    base: u32,
    stack: Vec<u32>,
}

impl Kitty {
    fn current(&mut self) -> &mut u32 {
        self.stack.last_mut().unwrap_or(&mut self.base)
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Modes {
    /// Tracked private modes, as last set.
    dec: BTreeMap<u16, bool>,
    /// Insert (4) and new line (20) mode.
    ansi: BTreeMap<u16, bool>,
    alt_screen: bool,
    keypad: bool,
    /// The main screen's, then the alternate screen's.
    kitty: [Kitty; 2],
    modify_other_keys: u32,
    cursor_style: Option<u32>,
    /// DECSTBM's parameters.
    scroll_region: Option<String>,
    title: Option<String>,
    /// OSC 9;4's parameters, while progress shows.
    progress: Option<String>,
}

impl Modes {
    /// Tracks what `seq` sets. False if it is a query.
    fn apply(&mut self, seq: &[u8]) -> bool {
        match seq.get(1) {
            Some(b'[') => self.csi(&seq[2..]),
            Some(b']') => self.osc(string_body(seq)),
            Some(b'P') => !is_dcs_query(string_body(seq)),
            Some(b'_') => !is_graphics_query(string_body(seq)),
            Some(b'c') if seq.len() == 2 => {
                // RIS: a full reset.
                *self = Modes {
                    title: self.title.take(),
                    ..Modes::default()
                };
                true
            }
            Some(b'=') if seq.len() == 2 => {
                self.keypad = true;
                true
            }
            Some(b'>') if seq.len() == 2 => {
                self.keypad = false;
                true
            }
            _ => true,
        }
    }

    fn csi(&mut self, body: &[u8]) -> bool {
        let Some((&fin, rest)) = body.split_last() else {
            return true;
        };
        let (prefix, rest) = match rest.first() {
            Some(&p @ b'<'..=b'?') => (Some(p), &rest[1..]),
            _ => (None, rest),
        };
        let split = rest
            .iter()
            .position(|b| (0x20..=0x2f).contains(b))
            .unwrap_or(rest.len());
        let (raw, inter) = rest.split_at(split);
        let params = params(raw);
        let first = params.first().copied().flatten();
        let screen = usize::from(self.alt_screen);
        match (prefix, inter, fin) {
            // Device attributes, status reports, mode requests, Kitty
            // keyboard flags, version, modifier keys, graphics.
            (None | Some(b'>' | b'='), [], b'c')
            | (None | Some(b'?'), [], b'n')
            | (_, b"$", b'p')
            | (Some(b'?'), [], b'u' | b'm' | b'S')
            | (Some(b'>'), [], b'q')
            | (None, [], b'x')
            | (_, b"$", b'w') => return false,
            // Window reports. Other window operations, like saving the
            // title, are not queries.
            (None, [], b't')
                if matches!(first, Some(11 | 13 | 14 | 15 | 16 | 18 | 19 | 20 | 21)) =>
            {
                return false;
            }
            (Some(b'?'), [], b'h' | b'l') => {
                let on = fin == b'h';
                for mode in params.into_iter().flatten() {
                    let Ok(mode) = u16::try_from(mode) else {
                        continue;
                    };
                    if matches!(mode, 47 | 1047 | 1049) {
                        if on && !self.alt_screen {
                            // A fresh alternate screen has its own flags.
                            self.kitty[1] = Kitty::default();
                        }
                        self.alt_screen = on;
                    } else if TRACKED.contains(&mode) {
                        self.dec.insert(mode, on);
                    }
                }
            }
            (None, [], b'h' | b'l') => {
                for mode in params.into_iter().flatten() {
                    if let Ok(mode @ (4 | 20)) = u16::try_from(mode) {
                        self.ansi.insert(mode, fin == b'h');
                    }
                }
            }
            (Some(b'>'), [], b'u') => {
                let kitty = &mut self.kitty[screen];
                kitty.stack.push(first.unwrap_or(0));
                if kitty.stack.len() > 16 {
                    kitty.stack.remove(0);
                }
            }
            (Some(b'<'), [], b'u') => {
                let kitty = &mut self.kitty[screen];
                for _ in 0..first.unwrap_or(1).max(1) {
                    if kitty.stack.pop().is_none() {
                        kitty.base = 0;
                        break;
                    }
                }
            }
            (Some(b'='), [], b'u') => {
                let flags = first.unwrap_or(0);
                let current = self.kitty[screen].current();
                match params.get(1).copied().flatten().unwrap_or(1) {
                    1 => *current = flags,
                    2 => *current |= flags,
                    3 => *current &= !flags,
                    _ => {}
                }
            }
            (Some(b'>'), [], b'm') => match first {
                None => self.modify_other_keys = 0,
                Some(4) => self.modify_other_keys = params.get(1).copied().flatten().unwrap_or(0),
                Some(_) => {}
            },
            (Some(b'>'), [], b'n') if first == Some(4) => self.modify_other_keys = 0,
            (None, b" ", b'q') => self.cursor_style = Some(first.unwrap_or(0)),
            (None, [], b'r') => {
                self.scroll_region =
                    (!raw.is_empty()).then(|| String::from_utf8_lossy(raw).into_owned());
            }
            _ => {}
        }
        true
    }

    fn osc(&mut self, body: &[u8]) -> bool {
        let text = String::from_utf8_lossy(body);
        let (code, rest) = text.split_once(';').unwrap_or((&text, ""));
        match code {
            "0" | "2" => self.title = Some(rest.to_string()),
            "9" if rest.starts_with("4;") || rest == "4" => {
                let params = rest.strip_prefix("4").unwrap_or("").trim_start_matches(';');
                let shown = !matches!(params.split(';').next(), None | Some("" | "0"));
                self.progress = shown.then(|| params.to_string());
            }
            // Colors and the clipboard, when asked with `?`.
            "4" | "5" | "10" | "11" | "12" | "13" | "14" | "15" | "16" | "17" | "18" | "19"
            | "21" | "52"
                if rest.split(';').any(|p| p == "?" || p.ends_with("=?")) =>
            {
                return false;
            }
            _ => {}
        }
        true
    }

    /// Sets these modes in a fresh terminal.
    fn prelude(&self) -> Vec<u8> {
        let mut s = String::new();
        let kitty = |s: &mut String, k: &Kitty| {
            if k.base != 0 {
                s.push_str(&format!("\x1b[={};1u", k.base));
            }
            for flags in &k.stack {
                s.push_str(&format!("\x1b[>{flags}u"));
            }
        };
        kitty(&mut s, &self.kitty[0]);
        if self.alt_screen {
            s.push_str("\x1b[?1049h");
            kitty(&mut s, &self.kitty[1]);
        }
        for (mode, on) in &self.dec {
            s.push_str(&format!("\x1b[?{mode}{}", if *on { 'h' } else { 'l' }));
        }
        for (mode, on) in &self.ansi {
            s.push_str(&format!("\x1b[{mode}{}", if *on { 'h' } else { 'l' }));
        }
        if self.keypad {
            s.push_str("\x1b=");
        }
        if self.modify_other_keys != 0 {
            s.push_str(&format!("\x1b[>4;{}m", self.modify_other_keys));
        }
        if let Some(style) = self.cursor_style {
            s.push_str(&format!("\x1b[{style} q"));
        }
        if let Some(region) = &self.scroll_region {
            s.push_str(&format!("\x1b[{region}r"));
        }
        if let Some(title) = &self.title {
            s.push_str(&format!("\x1b]2;{title}\x07"));
        }
        if let Some(progress) = &self.progress {
            s.push_str(&format!("\x1b]9;4;{progress}\x07"));
        }
        s.into_bytes()
    }
}

/// `1;;3` as `[Some(1), None, Some(3)]`. Sub-parameters after `:` are left
/// out.
fn params(raw: &[u8]) -> Vec<Option<u32>> {
    if raw.is_empty() {
        return Vec::new();
    }
    raw.split(|&b| b == b';')
        .map(|p| {
            let p = p.split(|&b| b == b':').next().unwrap_or(p);
            std::str::from_utf8(p).ok()?.parse().ok()
        })
        .collect()
}

/// The text of an OSC, DCS or APC: after its introducer, before its end.
fn string_body(seq: &[u8]) -> &[u8] {
    let body = &seq[2..];
    body.strip_suffix(b"\x1b\\")
        .or_else(|| body.strip_suffix(&[BEL]))
        .unwrap_or(body)
}

/// DECRQSS (`DCS $ q`) and XTGETTCAP (`DCS + q`).
fn is_dcs_query(body: &[u8]) -> bool {
    let rest = body
        .iter()
        .position(|b| !(b.is_ascii_digit() || *b == b';'))
        .map_or(&[][..], |i| &body[i..]);
    rest.starts_with(b"$q") || rest.starts_with(b"+q")
}

/// A Kitty graphics query (`APC G a=q`).
fn is_graphics_query(body: &[u8]) -> bool {
    let Some(control) = body.strip_prefix(b"G") else {
        return false;
    };
    let control = control.split(|&b| b == b';').next().unwrap_or(control);
    control.split(|&b| b == b',').any(|kv| kv == b"a=q")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn filtered(input: &[u8]) -> Vec<u8> {
        let mut screen = Screen::new(KEEP);
        screen.push(input);
        screen.bytes
    }

    #[test]
    fn leaves_out_queries() {
        let input = b"a\x1b[6nb\x1b[c\x1b[>0q\x1b[?u\x1b]11;?\x1b\\c\x1b]10;?\x07\x1b[?2026$p\x1bP+q544e\x1b\\\x1b[14t\x1b[?996nd";
        assert_eq!(filtered(input), b"abcd");
    }

    #[test]
    fn keeps_what_is_not_a_query() {
        let input = b"\x1b[1;31mred\x1b[0m\x1b]0;title\x07\x1b[?2004h\x1b]8;;https://x\x1b\\link\x1b]8;;\x1b\\\x1b[22;0t\x1b[2J\x1b(B";
        assert_eq!(filtered(input), input);
    }

    #[test]
    fn sequences_split_across_reads() {
        let mut screen = Screen::new(KEEP);
        screen.push(b"x\x1b[");
        screen.push(b"6");
        assert_eq!(screen.replay(), b"x\x1b[6");
        screen.push(b"ny\x1b]2;t");
        screen.push(b"\x1b\\z");
        assert_eq!(screen.bytes, b"xy\x1b]2;t\x1b\\z");
        assert_eq!(screen.live.modes.title.as_deref(), Some("t"));
    }

    #[test]
    fn long_strings_pass_through() {
        let mut input = b"\x1b_Gf=100;".to_vec();
        input.extend(std::iter::repeat_n(b'A', LONG * 2));
        input.extend_from_slice(b"\x1b\\after");
        assert_eq!(filtered(&input), input);
        assert_eq!(filtered(b"\x1b_Ga=q,i=1;\x1b\\x"), b"x");
    }

    #[test]
    fn esc_ends_a_string_and_starts_a_sequence() {
        assert_eq!(filtered(b"\x1b]2;t\x1b[1mx"), b"\x1b]2;t\x1b[1mx");
        assert_eq!(filtered(b"\x1b]11;?\x1b[6nx"), b"x");
    }

    #[test]
    fn tracks_modes_in_order() {
        let mut p = Parser::default();
        let mut out = Vec::new();
        // As Claude starts: Kitty flags on the main screen, then the
        // alternate screen with its own.
        p.feed(
            b"\x1b[?2004h\x1b[<u\x1b[>5u\x1b[>4;2m\x1b[?1049h\x1b[<u\x1b[>5u\x1b[?1000h\x1b[?1006h\x1b[?25l\x1b[0 q",
            &mut out,
        );
        let m = &p.modes;
        assert!(m.alt_screen);
        assert_eq!(m.kitty[0].stack, vec![5]);
        assert_eq!(m.kitty[1].stack, vec![5]);
        assert_eq!(m.modify_other_keys, 2);
        assert_eq!(m.dec.get(&2004), Some(&true));
        assert_eq!(m.dec.get(&25), Some(&false));
        assert_eq!(
            String::from_utf8(m.prelude()).unwrap(),
            "\x1b[>5u\x1b[?1049h\x1b[>5u\x1b[?25l\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[>4;2m\x1b[0 q"
        );
        p.feed(b"\x1b[<u\x1b[?1049l\x1b[>4m\x1b[=3;1u", &mut out);
        let m = &p.modes;
        assert!(!m.alt_screen);
        assert_eq!(m.kitty[0].stack, vec![3]);
        assert_eq!(m.modify_other_keys, 0);
        p.feed(b"\x1bc", &mut out);
        assert_eq!(p.modes.prelude(), b"");
    }

    #[test]
    fn progress_and_title() {
        let mut p = Parser::default();
        let mut out = Vec::new();
        p.feed(b"\x1b]0;\xe2\x9c\xb3 Claude\x07\x1b]9;4;3;\x07", &mut out);
        assert_eq!(p.modes.progress.as_deref(), Some("3;"));
        assert_eq!(p.modes.title.as_deref(), Some("✳ Claude"));
        p.feed(b"\x1b]9;4;0;\x07", &mut out);
        assert_eq!(p.modes.progress, None);
        // Other OSC 9 is a notification.
        p.feed(b"\x1b]9;Done\x07", &mut out);
        assert_eq!(p.modes.progress, None);
    }

    #[test]
    fn trimming_keeps_the_modes_it_drops() {
        let mut screen = Screen::new(64);
        screen.push(b"\x1b[?1049h\x1b[>1u\x1b[?2004h");
        screen.push("é".repeat(40).as_bytes());
        screen.push(b"\x1b[1mend");
        assert!(screen.bytes.len() <= 64);
        let replay = screen.replay();
        let text = String::from_utf8(replay).expect("cut between characters");
        assert!(
            text.starts_with("\x1b[?1049h\x1b[>1u\x1b[?2004h"),
            "{text:?}"
        );
        assert!(text.ends_with("é\x1b[1mend"), "{text:?}");
    }
}
