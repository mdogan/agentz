//! What the app and the server say to each other over the socket.
//!
//! Every message is a frame: a 4-byte big-endian length (of the rest), a
//! kind byte, and the payload. A connection starts with a `Request` from the
//! app and a `Reply`. A connection to one program (`Spawn` or `Attach`) then
//! stays open: the app sends input, sizes and `Kill`, the server sends the
//! output and, at the end, `Exit`. Control messages are JSON; input and
//! output are raw bytes.

use std::io::{self, Read, Write};
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use super::{ServerSession, SessionMeta, TermSize};

/// Part of the socket's name. Change it with any change here that an older
/// server or app would not understand: each version then gets its own
/// server.
pub const PROTOCOL: u32 = 1;

/// Larger frames are an error. Output is sent in much smaller pieces.
const MAX_FRAME: usize = 16 << 20;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Kind {
    Request = 1,
    Reply = 2,
    /// App to server: typed text and terminal replies.
    Input = 3,
    /// App to server: the terminal's new size, JSON `TermSize`.
    Resize = 4,
    /// App to server: hang up on the program.
    Kill = 5,
    /// App to server: new `SessionMeta`.
    Update = 6,
    /// Server to app: what the program wrote.
    Output = 7,
    /// Server to app: what the program wrote before the app attached, to
    /// draw its screen again.
    Replay = 8,
    /// Server to app: the replay is done.
    Replayed = 9,
    /// Server to app: the program ended, JSON `Exit`.
    Exit = 10,
}

impl Kind {
    fn from_u8(b: u8) -> Option<Kind> {
        use Kind::*;
        [
            Request, Reply, Input, Resize, Kill, Update, Output, Replay, Replayed, Exit,
        ]
        .into_iter()
        .find(|k| *k as u8 == b)
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Request {
    /// The running programs.
    List,
    Spawn(Spawn),
    /// Connects to a running program. `size` is the app's terminal size.
    Attach {
        id: String,
        size: TermSize,
    },
    /// Hangs up on every program.
    StopAll,
}

/// A program to start, and what the app knows about it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct Spawn {
    /// The program and its arguments. The program is a path; it is not
    /// looked up in `PATH`.
    pub argv: Vec<String>,
    /// Its whole environment, as `NAME=value`.
    pub env: Vec<String>,
    pub cwd: PathBuf,
    pub size: TermSize,
    pub meta: SessionMeta,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Reply {
    Sessions(Vec<ServerSession>),
    Session(ServerSession),
    Done,
    Error(String),
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Exit {
    /// The exit status, or 128 + the signal that killed it.
    pub code: i32,
}

/// One frame, ready to write.
pub fn frame(kind: Kind, payload: &[u8]) -> Vec<u8> {
    let len = u32::try_from(payload.len() + 1).expect("frame too large");
    let mut out = Vec::with_capacity(payload.len() + 5);
    out.extend_from_slice(&len.to_be_bytes());
    out.push(kind as u8);
    out.extend_from_slice(payload);
    out
}

pub fn json_frame(kind: Kind, value: &impl Serialize) -> Vec<u8> {
    frame(
        kind,
        &serde_json::to_vec(value).expect("JSON of our own types"),
    )
}

pub fn write_json(w: &mut impl Write, kind: Kind, value: &impl Serialize) -> io::Result<()> {
    w.write_all(&json_frame(kind, value))
}

/// The next frame, or None when the other side closed the connection
/// between frames.
pub fn read_frame(r: &mut impl Read) -> io::Result<Option<(Kind, Vec<u8>)>> {
    let mut head = [0u8; 4];
    match r.read_exact(&mut head) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes(head) as usize;
    if len == 0 || len > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("bad frame length {len}"),
        ));
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body)?;
    let kind = Kind::from_u8(body[0]).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unknown frame kind {}", body[0]),
        )
    })?;
    body.remove(0);
    Ok(Some((kind, body)))
}

pub fn parse<T: for<'de> Deserialize<'de>>(body: &[u8]) -> io::Result<T> {
    serde_json::from_slice(body).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_round_trip() {
        let mut buf = frame(Kind::Output, b"hello");
        buf.extend(json_frame(Kind::Exit, &Exit { code: 3 }));
        buf.extend(frame(Kind::Replayed, b""));
        let mut r = &buf[..];
        assert_eq!(
            read_frame(&mut r).unwrap(),
            Some((Kind::Output, b"hello".to_vec()))
        );
        let (kind, body) = read_frame(&mut r).unwrap().unwrap();
        assert_eq!(kind, Kind::Exit);
        assert_eq!(parse::<Exit>(&body).unwrap().code, 3);
        assert_eq!(read_frame(&mut r).unwrap(), Some((Kind::Replayed, vec![])));
        assert_eq!(read_frame(&mut r).unwrap(), None);
        assert!(read_frame(&mut &[0u8, 0, 0, 0][..]).is_err());
        assert!(read_frame(&mut &[0u8, 0, 0, 1, 99][..]).is_err());
    }
}
