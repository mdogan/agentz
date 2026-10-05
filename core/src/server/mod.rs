//! The agentz server: a background process that runs the agents and shells
//! on its own terminals, so they can keep running when the app quits, like
//! tmux or herdr. The app shows them in Ghostty surfaces it feeds itself
//! (Ghostty's host-managed backend): the server sends a program's output,
//! and the app sends back what the user types and the terminal's size. When
//! the app starts again, it attaches to the programs that still run.
//!
//! - `daemon`: the server, run as `agentz server`.
//! - `client`: the app's side, which also starts the server.
//! - `screen`: what the server keeps of the output, to draw a screen again.
//! - `proto`: what goes over the socket.

use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::sessions::Agent;

mod client;
mod daemon;
mod proto;
mod screen;

pub use client::{Connection, Events, list, stop_all};
pub use daemon::run;
pub use proto::{Request, Spawn};

/// The size of a terminal, in cells and pixels.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct TermSize {
    pub cols: u16,
    pub rows: u16,
    pub width_px: u32,
    pub height_px: u32,
}

/// What the app knows about a program, kept by the server for the next
/// app that attaches.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct SessionMeta {
    pub agent: Agent,
    /// The agent's session id. None for a new Codex session until the app
    /// learns which id Codex chose.
    pub session_id: Option<String>,
    /// What the app called it, for while it has no transcript.
    pub title: String,
}

/// A program running in the server.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ServerSession {
    /// The server's id for it.
    pub id: String,
    pub pid: i32,
    pub cwd: PathBuf,
    pub started: SystemTime,
    pub meta: SessionMeta,
}

/// Where the server keeps its socket, lock and log: `AGENTZ_SERVER_DIR`, or
/// agentz's data folder.
pub fn dir() -> Result<PathBuf> {
    if let Some(dir) = std::env::var_os("AGENTZ_SERVER_DIR").filter(|d| !d.is_empty()) {
        return Ok(PathBuf::from(dir));
    }
    Ok(dirs::data_local_dir()
        .context("could not find a data folder for the agentz server")?
        .join("agentz"))
}

fn socket_path(dir: &Path) -> PathBuf {
    dir.join(format!("server-{}.sock", proto::PROTOCOL))
}

/// Writing to a closed connection returns an error instead of killing the
/// process with SIGPIPE.
fn no_sigpipe(stream: &UnixStream) {
    let on: libc::c_int = 1;
    unsafe {
        libc::setsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_NOSIGPIPE,
            (&on as *const libc::c_int).cast(),
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        );
    }
}

#[cfg(test)]
mod tests;
