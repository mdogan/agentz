//! The app's side of the server: starting it, asking it things, and a
//! connection to one program.

use std::ffi::CString;
use std::fs;
use std::io::{self, Write};
use std::net::Shutdown;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

use super::proto::{self, Exit, Kind, Reply, Request};
use super::{ServerSession, SessionMeta, TermSize, no_sigpipe, socket_path};
use crate::lock;

/// `POSIX_SPAWN_SETSID` from `<spawn.h>`, which `libc` does not have.
const POSIX_SPAWN_SETSID: libc::c_int = 0x0400;
/// A log longer than this is moved to `server.log.old` when a server starts.
const LOG_LIMIT: u64 = 1 << 20;
/// How long to wait for the server to answer a request.
const REPLY_TIMEOUT: Duration = Duration::from_secs(5);

/// What a program's connection reports. Called on the connection's own
/// thread.
pub trait Events: Send + Sync {
    /// Output, first the replay of the screen when attaching, then live.
    fn output(&self, data: Vec<u8>);
    /// The replay is done; what follows is live.
    fn replayed(&self);
    /// The program ended with `code`. None if the connection broke: the
    /// server is gone, and the program with it.
    fn exited(&self, code: Option<i32>);
}

/// A connection to one program in the server.
pub struct Connection {
    stream: Mutex<UnixStream>,
    session: Mutex<ServerSession>,
}

impl Connection {
    /// Sends `request` (`Spawn` or `Attach`) and, once the server accepts it,
    /// reports the program's output to `events`. With `program`, starts the
    /// server if it does not run.
    pub fn open(
        dir: &Path,
        program: Option<&Path>,
        request: &Request,
        events: Arc<dyn Events>,
    ) -> Result<Connection> {
        let (stream, reply) = ask(dir, program, request)?;
        let session = match reply {
            Reply::Session(session) => session,
            Reply::Error(message) => bail!("{message}"),
            other => bail!("unexpected reply from the agentz server: {other:?}"),
        };
        let mut reader = stream.try_clone()?;
        thread::Builder::new()
            .name(format!("agentz {}", session.id))
            .spawn(move || {
                let code = loop {
                    match proto::read_frame(&mut reader) {
                        Ok(Some((Kind::Output | Kind::Replay, data))) => events.output(data),
                        Ok(Some((Kind::Replayed, _))) => events.replayed(),
                        Ok(Some((Kind::Exit, body))) => {
                            break proto::parse::<Exit>(&body).ok().map(|e| e.code);
                        }
                        Ok(Some(_)) => {}
                        Ok(None) | Err(_) => break None,
                    }
                };
                events.exited(code);
            })
            .context("starting a thread")?;
        Ok(Connection {
            stream: Mutex::new(stream),
            session: Mutex::new(session),
        })
    }

    pub fn session(&self) -> ServerSession {
        lock(&self.session).clone()
    }

    pub fn write(&self, data: &[u8]) {
        for chunk in data.chunks(64 << 10) {
            self.send(&proto::frame(Kind::Input, chunk));
        }
    }

    pub fn resize(&self, size: TermSize) {
        self.send(&proto::json_frame(Kind::Resize, &size));
    }

    /// Hangs up on the program, as closing its terminal would.
    pub fn kill(&self) {
        self.send(&proto::frame(Kind::Kill, &[]));
    }

    /// Tells the server what the app now knows about the session, e.g. the
    /// id Codex chose.
    pub fn update(&self, meta: SessionMeta) {
        lock(&self.session).meta = meta.clone();
        self.send(&proto::json_frame(Kind::Update, &meta));
    }

    /// Closes the connection. The program keeps running.
    pub fn detach(&self) {
        let _ = lock(&self.stream).shutdown(Shutdown::Both);
    }

    fn send(&self, frame: &[u8]) {
        // An error means the server is gone; the reader reports that.
        let _ = (&*lock(&self.stream)).write_all(frame);
    }
}

/// The running programs. Empty if no server runs.
pub fn list(dir: &Path) -> Result<Vec<ServerSession>> {
    if !socket_path(dir).exists() {
        return Ok(Vec::new());
    }
    match ask(dir, None, &Request::List) {
        Ok((_, Reply::Sessions(sessions))) => Ok(sessions),
        Ok((_, other)) => bail!("unexpected reply from the agentz server: {other:?}"),
        Err(e) if not_running(&e) => Ok(Vec::new()),
        Err(e) => Err(e),
    }
}

/// Hangs up on every program. Returns the ones it hung up on.
pub fn stop_all(dir: &Path) -> Result<Vec<ServerSession>> {
    if !socket_path(dir).exists() {
        return Ok(Vec::new());
    }
    match ask(dir, None, &Request::StopAll) {
        Ok((_, Reply::Sessions(sessions))) => Ok(sessions),
        Ok((_, other)) => bail!("unexpected reply from the agentz server: {other:?}"),
        Err(e) if not_running(&e) => Ok(Vec::new()),
        Err(e) => Err(e),
    }
}

#[derive(Debug)]
struct NotRunning;

impl std::fmt::Display for NotRunning {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the agentz server is not running")
    }
}

impl std::error::Error for NotRunning {}

fn not_running(e: &anyhow::Error) -> bool {
    e.downcast_ref::<NotRunning>().is_some()
}

/// Sends `request` and reads the reply. A server that is just exiting
/// closes the connection without one; then this starts another (with
/// `program`) and asks again.
fn ask(dir: &Path, program: Option<&Path>, request: &Request) -> Result<(UnixStream, Reply)> {
    for _ in 0..3 {
        let stream = connect(dir, program)?;
        // A server that hangs must not hang the app, which asks at launch.
        stream.set_read_timeout(Some(REPLY_TIMEOUT))?;
        stream.set_write_timeout(Some(REPLY_TIMEOUT))?;
        proto::write_json(&mut &stream, Kind::Request, request)
            .context("writing to the agentz server")?;
        let mut reader = &stream;
        match proto::read_frame(&mut reader).context("reading from the agentz server")? {
            Some((Kind::Reply, body)) => {
                let reply = proto::parse(&body)?;
                // Fails once the server closed its side, as after a list;
                // then nothing is read any more anyway.
                let _ = stream.set_read_timeout(None);
                let _ = stream.set_write_timeout(None);
                return Ok((stream, reply));
            }
            Some((kind, _)) => bail!("unexpected {kind:?} from the agentz server"),
            None => thread::sleep(Duration::from_millis(50)),
        }
    }
    bail!(
        "the agentz server keeps closing the connection; see {}",
        dir.join("server.log").display()
    )
}

/// Connects to the server. With `program`, starts it first if it does not
/// run.
fn connect(dir: &Path, program: Option<&Path>) -> Result<UnixStream> {
    let path = socket_path(dir);
    let gone = |e: &io::Error| {
        matches!(
            e.kind(),
            io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
        )
    };
    match UnixStream::connect(&path) {
        Ok(stream) => return Ok(prepared(stream)),
        Err(e) if gone(&e) => {}
        Err(e) => return Err(e).with_context(|| format!("connecting to {}", path.display())),
    }
    let Some(program) = program else {
        return Err(NotRunning.into());
    };
    start(dir, program)?;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        thread::sleep(Duration::from_millis(20));
        match UnixStream::connect(&path) {
            Ok(stream) => return Ok(prepared(stream)),
            Err(e) if gone(&e) && Instant::now() < deadline => {}
            Err(e) => {
                return Err(e).with_context(|| {
                    format!(
                        "the agentz server did not start; see {}",
                        dir.join("server.log").display()
                    )
                });
            }
        }
    }
}

fn prepared(stream: UnixStream) -> UnixStream {
    no_sigpipe(&stream);
    stream
}

/// Starts `program server` in its own session, so it outlives the app, with
/// nothing of the app's open but its log.
fn start(dir: &Path, program: &Path) -> Result<()> {
    fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    let log = dir.join("server.log");
    if fs::metadata(&log).is_ok_and(|m| m.len() > LOG_LIMIT) {
        let _ = fs::rename(&log, dir.join("server.log.old"));
    }
    let program = CString::new(program.as_os_str().as_bytes())?;
    let log = CString::new(log.as_os_str().as_bytes())?;
    let null = c"/dev/null";
    let arg = c"server";
    let argv = [program.as_ptr(), arg.as_ptr(), std::ptr::null()];
    // The app's environment, with this folder, so the server uses it too.
    let mut env: Vec<CString> = std::env::vars_os()
        .filter(|(k, _)| k != "AGENTZ_SERVER_DIR")
        .filter_map(|(k, v)| {
            let mut kv = k.as_bytes().to_vec();
            kv.push(b'=');
            kv.extend_from_slice(v.as_bytes());
            CString::new(kv).ok()
        })
        .collect();
    let mut dir_var = b"AGENTZ_SERVER_DIR=".to_vec();
    dir_var.extend_from_slice(dir.as_os_str().as_bytes());
    env.push(CString::new(dir_var)?);
    let mut envp: Vec<*const libc::c_char> = env.iter().map(|e| e.as_ptr()).collect();
    envp.push(std::ptr::null());

    let mut pid = 0;
    let r = unsafe {
        let mut attr: libc::posix_spawnattr_t = std::ptr::null_mut();
        let mut actions: libc::posix_spawn_file_actions_t = std::ptr::null_mut();
        libc::posix_spawnattr_init(&mut attr);
        libc::posix_spawn_file_actions_init(&mut actions);
        // Everything but stdin, stdout and stderr closes on exec.
        let flags = POSIX_SPAWN_SETSID
            | libc::POSIX_SPAWN_CLOEXEC_DEFAULT
            | libc::POSIX_SPAWN_SETSIGDEF
            | libc::POSIX_SPAWN_SETSIGMASK;
        libc::posix_spawnattr_setflags(&mut attr, flags as libc::c_short);
        let mut all: libc::sigset_t = std::mem::zeroed();
        libc::sigfillset(&mut all);
        libc::posix_spawnattr_setsigdefault(&mut attr, &all);
        let mut none: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut none);
        libc::posix_spawnattr_setsigmask(&mut attr, &none);
        libc::posix_spawn_file_actions_addopen(&mut actions, 0, null.as_ptr(), libc::O_RDONLY, 0);
        libc::posix_spawn_file_actions_addopen(
            &mut actions,
            1,
            log.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_APPEND,
            0o600,
        );
        libc::posix_spawn_file_actions_adddup2(&mut actions, 1, 2);
        let r = libc::posix_spawn(
            &mut pid,
            program.as_ptr(),
            &actions,
            &attr,
            argv.as_ptr() as *const *mut libc::c_char,
            envp.as_ptr() as *const *mut libc::c_char,
        );
        libc::posix_spawn_file_actions_destroy(&mut actions);
        libc::posix_spawnattr_destroy(&mut attr);
        r
    };
    if r != 0 {
        return Err(io::Error::from_raw_os_error(r)).context("starting the agentz server");
    }
    // Reaped when it exits, so it does not stay behind as a zombie of the
    // app.
    thread::spawn(move || unsafe {
        let mut status = 0;
        libc::waitpid(pid, &mut status, 0);
    });
    Ok(())
}
