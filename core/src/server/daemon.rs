//! `agentz server`: the process that owns the terminals of the agents and
//! shells, so they can keep running when the app quits. The app starts it
//! the first time it starts one. It exits by itself once no program runs and no app has
//! been connected for a while.
//!
//! One thread accepts connections. Each connection has a thread that reads
//! what the app sends and one that writes to it. Each program has a thread,
//! its pump, that alone touches its terminal: it reads the output, writes
//! the input, sets the size, and notices when the program ends. The other
//! threads hand it work through `State` and wake it through a pipe.

use std::collections::VecDeque;
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::net::Shutdown;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use anyhow::{Context, Result, bail};

use super::proto::{self, Exit, Kind, Reply, Request, Spawn};
use super::screen::{KEEP, Screen};
use super::{ServerSession, SessionMeta, TermSize, no_sigpipe, socket_path};
use crate::lock;

/// How long the server waits with nothing to do before it exits.
const IDLE_EXIT: Duration = Duration::from_secs(10);
/// How long a program gets to end after a hang-up, before it is killed.
const HANGUP_GRACE: Duration = Duration::from_secs(3);
/// How long to wait for the last output of a program that ended, when
/// something it started still holds the terminal.
const EXIT_DRAIN: Duration = Duration::from_millis(300);
/// How long a size lasts when the server changes it only to make the
/// program redraw.
const NUDGE: Duration = Duration::from_millis(150);
/// Frames waiting for an app. One that falls this far behind is let go.
const CLIENT_QUEUE: usize = 4096;
const REPLAY_CHUNK: usize = 256 << 10;
/// `select` can't watch higher file descriptors.
const MAX_FD: RawFd = libc::FD_SETSIZE as RawFd;

/// Runs the server in `dir` until it has nothing to do. Returns right away
/// if another server runs there.
pub fn run(dir: &Path) -> Result<()> {
    let Some(listening) = listen(dir)? else {
        eprintln!("agentz server: another server runs in {}", dir.display());
        return Ok(());
    };
    {
        let server = listening.server.clone();
        let path = socket_path(dir);
        thread::spawn(move || server.exit_when_idle(&path));
    }
    serve_connections(listening);
    Ok(())
}

/// Runs a server on a thread, for tests. It does not exit when idle.
#[cfg(test)]
pub fn run_on_thread(dir: &Path) -> Result<()> {
    let listening = listen(dir)?.context("a server already runs there")?;
    thread::spawn(move || serve_connections(listening));
    Ok(())
}

struct Listening {
    listener: UnixListener,
    server: Arc<Server>,
    /// Held while the server runs.
    _lock: File,
}

fn listen(dir: &Path) -> Result<Option<Listening>> {
    fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    let Some(lock) = lock_dir(dir)? else {
        return Ok(None);
    };
    unsafe {
        // Writes to a closed connection fail instead of killing the server,
        // and the app quitting does not hang it up.
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        libc::signal(libc::SIGHUP, libc::SIG_IGN);
    }
    let path = socket_path(dir);
    // Left by a server that crashed: the lock says none runs now.
    let _ = fs::remove_file(&path);
    let listener =
        UnixListener::bind(&path).with_context(|| format!("listening on {}", path.display()))?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    eprintln!(
        "agentz server {}: listening on {}",
        std::process::id(),
        path.display()
    );
    let server = Arc::new(Server {
        sessions: Mutex::new(Vec::new()),
        connections: AtomicUsize::new(0),
        idle_since: Mutex::new(Instant::now()),
        next_client: AtomicU64::new(1),
    });
    Ok(Some(Listening {
        listener,
        server,
        _lock: lock,
    }))
}

fn serve_connections(listening: Listening) {
    let Listening {
        listener,
        server,
        _lock,
    } = listening;
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(stream) => stream,
            Err(e) => {
                eprintln!("agentz server: accept: {e}");
                thread::sleep(Duration::from_millis(100));
                continue;
            }
        };
        server.connections.fetch_add(1, Ordering::SeqCst);
        let server = server.clone();
        thread::spawn(move || {
            if let Err(e) = handle(&server, stream) {
                eprintln!("agentz server: {e:#}");
            }
            *lock(&server.idle_since) = Instant::now();
            server.connections.fetch_sub(1, Ordering::SeqCst);
        });
    }
}

/// Holds `server.lock` while this server runs. None if another server holds
/// it.
fn lock_dir(dir: &Path) -> Result<Option<File>> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(dir.join("server.lock"))?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        return Ok(Some(file));
    }
    let err = io::Error::last_os_error();
    if err.kind() == io::ErrorKind::WouldBlock {
        return Ok(None);
    }
    Err(err).context("locking the server folder")
}

struct Server {
    /// Running programs, oldest first.
    sessions: Mutex<Vec<Arc<Session>>>,
    connections: AtomicUsize,
    /// When the last connection closed or the last program ended.
    idle_since: Mutex<Instant>,
    next_client: AtomicU64,
}

impl Server {
    fn exit_when_idle(&self, socket: &Path) {
        loop {
            thread::sleep(Duration::from_secs(1));
            let idle =
                lock(&self.sessions).is_empty() && self.connections.load(Ordering::SeqCst) == 0;
            if idle && lock(&self.idle_since).elapsed() >= IDLE_EXIT {
                let _ = fs::remove_file(socket);
                eprintln!(
                    "agentz server {}: nothing runs, exiting",
                    std::process::id()
                );
                std::process::exit(0);
            }
        }
    }

    fn list(&self) -> Vec<ServerSession> {
        lock(&self.sessions).iter().map(|s| s.info()).collect()
    }

    fn find(&self, id: &str) -> Option<Arc<Session>> {
        lock(&self.sessions).iter().find(|s| s.id == id).cloned()
    }

    fn spawn(self: &Arc<Self>, spawn: Spawn) -> Result<Arc<Session>> {
        let (master, pid) = start_program(&spawn)?;
        let session = Arc::new(Session::new(pid, spawn)?);
        eprintln!(
            "agentz server: started {} (pid {pid}) in {}",
            session.id,
            session.cwd.display()
        );
        lock(&self.sessions).push(session.clone());
        let server = self.clone();
        let pumped = session.clone();
        thread::Builder::new()
            .name(format!("pump {pid}"))
            .spawn(move || {
                let code = pumped.pump(master);
                eprintln!("agentz server: {} ended with {code}", pumped.id);
                lock(&server.sessions).retain(|s| !Arc::ptr_eq(s, &pumped));
                *lock(&server.idle_since) = Instant::now();
            })
            .context("starting a thread")?;
        Ok(session)
    }
}

/// Starts `spawn` on a new terminal. Returns the terminal's master side and
/// the program's pid.
fn start_program(spawn: &Spawn) -> Result<(OwnedFd, libc::pid_t)> {
    let cstrings = |v: &[String]| -> Result<Vec<CString>> {
        v.iter()
            .map(|s| CString::new(s.as_str()).context("NUL in an argument"))
            .collect()
    };
    let argv = cstrings(&spawn.argv)?;
    let env = cstrings(&spawn.env)?;
    if argv.is_empty() {
        bail!("nothing to run");
    }
    let cwd = CString::new(spawn.cwd.as_os_str().as_bytes()).context("NUL in the folder")?;
    let mut argv_ptrs: Vec<*const libc::c_char> = argv.iter().map(|a| a.as_ptr()).collect();
    argv_ptrs.push(std::ptr::null());
    let mut env_ptrs: Vec<*const libc::c_char> = env.iter().map(|a| a.as_ptr()).collect();
    env_ptrs.push(std::ptr::null());

    let mut size = winsize(spawn.size);
    let (mut master, mut slave) = (-1, -1);
    let r = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut size,
        )
    };
    if r != 0 {
        return Err(io::Error::last_os_error()).context("opening a terminal");
    }
    let (master, slave) = unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
    if master.as_raw_fd() >= MAX_FD {
        bail!("too many open terminals");
    }
    set_cloexec(master.as_raw_fd());
    set_cloexec(slave.as_raw_fd());
    unsafe {
        // UTF-8 input, so the terminal erases whole characters, as Ghostty
        // sets it up.
        let mut t: libc::termios = std::mem::zeroed();
        if libc::tcgetattr(slave.as_raw_fd(), &mut t) == 0 {
            t.c_iflag |= libc::IUTF8;
            libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &t);
        }
    }
    let max_fd = unsafe { libc::getdtablesize() }.clamp(3, 1 << 16);

    let pid = unsafe { libc::fork() };
    if pid < 0 {
        return Err(io::Error::last_os_error()).context("fork");
    }
    if pid == 0 {
        // The child. Other threads of the server may hold locks, so only
        // async-signal-safe calls until exec.
        unsafe {
            // A new session with this terminal as its controlling terminal,
            // and as stdin, stdout and stderr.
            if libc::login_tty(slave.as_raw_fd()) != 0 {
                libc::_exit(126);
            }
            for sig in [
                libc::SIGPIPE,
                libc::SIGHUP,
                libc::SIGINT,
                libc::SIGQUIT,
                libc::SIGTERM,
                libc::SIGCHLD,
                libc::SIGWINCH,
            ] {
                libc::signal(sig, libc::SIG_DFL);
            }
            let mut none: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut none);
            libc::sigprocmask(libc::SIG_SETMASK, &none, std::ptr::null_mut());
            // Nothing of the server's: other terminals, connections.
            for fd in 3..max_fd {
                libc::close(fd);
            }
            if libc::chdir(cwd.as_ptr()) != 0 {
                child_error(b"agentz: can't open the folder\r\n");
                libc::_exit(126);
            }
            libc::execve(argv_ptrs[0], argv_ptrs.as_ptr(), env_ptrs.as_ptr());
            child_error(b"agentz: can't start the program\r\n");
            libc::_exit(127);
        }
    }
    drop(slave);
    set_nonblocking(master.as_raw_fd());
    Ok((master, pid))
}

unsafe fn child_error(message: &[u8]) {
    unsafe { libc::write(2, message.as_ptr().cast(), message.len()) };
}

fn set_cloexec(fd: RawFd) {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
    }
}

fn set_nonblocking(fd: RawFd) {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }
}

fn winsize(size: TermSize) -> libc::winsize {
    libc::winsize {
        ws_row: size.rows,
        ws_col: size.cols,
        ws_xpixel: u16::try_from(size.width_px).unwrap_or(u16::MAX),
        ws_ypixel: u16::try_from(size.height_px).unwrap_or(u16::MAX),
    }
}

/// One program and its terminal.
struct Session {
    id: String,
    pid: libc::pid_t,
    cwd: std::path::PathBuf,
    started: SystemTime,
    /// Read and write ends of the pipe that wakes the pump.
    wake: (OwnedFd, OwnedFd),
    state: Mutex<State>,
}

struct State {
    meta: SessionMeta,
    screen: Screen,
    size: TermSize,
    clients: Vec<Client>,
    /// Typed by the apps, not yet written to the terminal.
    input: Vec<u8>,
    /// Sizes to set, and when.
    resizes: VecDeque<(Instant, TermSize)>,
    /// An app asked to hang up on the program.
    hang_up: bool,
    /// The exit code, once the program ended.
    exit: Option<i32>,
}

/// An app attached to a program: where its frames go.
struct Client {
    id: u64,
    frames: SyncSender<Arc<Vec<u8>>>,
}

impl Session {
    fn new(pid: libc::pid_t, spawn: Spawn) -> Result<Session> {
        let mut fds = [0; 2];
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error()).context("pipe");
        }
        let wake = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
        for fd in fds {
            set_cloexec(fd);
            set_nonblocking(fd);
        }
        if fds[0] >= MAX_FD {
            bail!("too many open files");
        }
        Ok(Session {
            id: uuid::Uuid::new_v4().to_string(),
            pid,
            cwd: spawn.cwd,
            started: SystemTime::now(),
            wake,
            state: Mutex::new(State {
                meta: spawn.meta,
                screen: Screen::new(KEEP),
                size: spawn.size,
                clients: Vec::new(),
                input: Vec::new(),
                resizes: VecDeque::new(),
                hang_up: false,
                exit: None,
            }),
        })
    }

    fn info(&self) -> ServerSession {
        self.info_with(&lock(&self.state))
    }

    fn info_with(&self, state: &State) -> ServerSession {
        ServerSession {
            id: self.id.clone(),
            pid: self.pid,
            cwd: self.cwd.clone(),
            started: self.started,
            meta: state.meta.clone(),
        }
    }

    fn wake(&self) {
        unsafe { libc::write(self.wake.1.as_raw_fd(), [1u8].as_ptr().cast(), 1) };
    }

    /// Runs the terminal until the program ends. Returns its exit code.
    fn pump(&self, master: OwnedFd) -> i32 {
        let mut master = Some(master);
        let mut buf = vec![0u8; 64 << 10];
        let mut status: Option<i32> = None;
        let mut ended_at: Option<Instant> = None;
        let mut hung_up_at: Option<Instant> = None;
        let mut killed = false;
        loop {
            let now = Instant::now();
            let (resize, want_write, hang_up, next_resize) = {
                let mut st = lock(&self.state);
                let mut resize = None;
                while st.resizes.front().is_some_and(|(at, _)| *at <= now) {
                    resize = st.resizes.pop_front().map(|(_, size)| size);
                }
                if let Some(size) = resize {
                    st.size = size;
                }
                (
                    resize,
                    !st.input.is_empty(),
                    st.hang_up,
                    st.resizes.front().map(|(at, _)| *at),
                )
            };
            if let (Some(size), Some(fd)) = (resize, &master) {
                // The program gets SIGWINCH.
                let ws = winsize(size);
                unsafe {
                    libc::ioctl(
                        fd.as_raw_fd(),
                        libc::TIOCSWINSZ,
                        &ws as *const libc::winsize,
                    )
                };
            }
            if hang_up && hung_up_at.is_none() && status.is_none() {
                // Like closing a terminal window: the program and what it
                // runs in the foreground get SIGHUP.
                master = None;
                unsafe { libc::kill(self.pid, libc::SIGHUP) };
                hung_up_at = Some(now);
            }
            if let Some(at) = hung_up_at
                && !killed
                && status.is_none()
                && at.elapsed() > HANGUP_GRACE
            {
                unsafe {
                    libc::kill(-self.pid, libc::SIGKILL);
                    libc::kill(self.pid, libc::SIGKILL);
                }
                killed = true;
            }
            if status.is_none() {
                let mut raw = 0;
                if unsafe { libc::waitpid(self.pid, &mut raw, libc::WNOHANG) } == self.pid {
                    status = Some(exit_code(raw));
                    ended_at = Some(now);
                }
            }
            if let Some(at) = ended_at
                && (master.is_none() || at.elapsed() > EXIT_DRAIN)
            {
                break;
            }

            // Output and work from the apps wake the pump. The timeout is for
            // noticing the end of a program that left something holding its
            // terminal, so it is short only once the terminal is gone.
            let mut timeout = if ended_at.is_some() {
                Duration::from_millis(20)
            } else if master.is_none() {
                Duration::from_millis(100)
            } else {
                Duration::from_secs(1)
            };
            if let Some(next) = next_resize {
                timeout = timeout.min(next.saturating_duration_since(now));
            }
            let fd = master.as_ref().map(|m| m.as_raw_fd());
            let ready = wait(
                fd,
                fd.filter(|_| want_write),
                self.wake.0.as_raw_fd(),
                timeout,
            );
            if ready.woken {
                let mut sink = [0u8; 64];
                while unsafe {
                    libc::read(
                        self.wake.0.as_raw_fd(),
                        sink.as_mut_ptr().cast(),
                        sink.len(),
                    )
                } > 0
                {}
            }
            if ready.readable
                && let Some(fd) = fd
            {
                let n = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
                if n > 0 {
                    self.output(&buf[..n as usize]);
                } else if n == 0
                    || !matches!(
                        io::Error::last_os_error().kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                    )
                {
                    // EIO: nothing holds the terminal any more.
                    master = None;
                }
            }
            // Not `fd`: the read may have closed the terminal, and another
            // thread may have its number now.
            if ready.writable
                && let Some(fd) = master.as_ref().map(|m| m.as_raw_fd())
            {
                let mut st = lock(&self.state);
                let n = unsafe { libc::write(fd, st.input.as_ptr().cast(), st.input.len()) };
                if n > 0 {
                    st.input.drain(..n as usize);
                } else if n < 0
                    && !matches!(
                        io::Error::last_os_error().kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                    )
                {
                    st.input.clear();
                }
            }
        }
        let code = status.unwrap_or(-1);
        let frame = Arc::new(proto::json_frame(Kind::Exit, &Exit { code }));
        let mut st = lock(&self.state);
        st.exit = Some(code);
        for client in st.clients.drain(..) {
            let _ = client.frames.try_send(frame.clone());
        }
        // `master` closes here, which hangs up on anything the program left
        // running on the terminal.
        code
    }

    /// Keeps the output and sends it to the attached apps.
    fn output(&self, data: &[u8]) {
        let frame = Arc::new(proto::frame(Kind::Output, data));
        let mut st = lock(&self.state);
        st.screen.push(data);
        st.clients
            .retain(|c| match c.frames.try_send(frame.clone()) {
                Ok(()) => true,
                Err(TrySendError::Full(_)) => {
                    eprintln!("agentz server: an app fell behind; letting it go");
                    false
                }
                Err(TrySendError::Disconnected(_)) => false,
            });
    }
}

fn exit_code(status: libc::c_int) -> i32 {
    if libc::WIFEXITED(status) {
        libc::WEXITSTATUS(status)
    } else if libc::WIFSIGNALED(status) {
        128 + libc::WTERMSIG(status)
    } else {
        -1
    }
}

struct Ready {
    readable: bool,
    writable: bool,
    woken: bool,
}

/// Waits until `read` has output, `write` has room, `wake` was written to,
/// or `timeout` passed. `poll` can't do this on macOS: it does not support
/// terminals.
fn wait(read: Option<RawFd>, write: Option<RawFd>, wake: RawFd, timeout: Duration) -> Ready {
    unsafe {
        let mut rset: libc::fd_set = std::mem::zeroed();
        let mut wset: libc::fd_set = std::mem::zeroed();
        libc::FD_ZERO(&mut rset);
        libc::FD_ZERO(&mut wset);
        libc::FD_SET(wake, &mut rset);
        let mut max = wake;
        if let Some(fd) = read {
            libc::FD_SET(fd, &mut rset);
            max = max.max(fd);
        }
        if let Some(fd) = write {
            libc::FD_SET(fd, &mut wset);
            max = max.max(fd);
        }
        let mut tv = libc::timeval {
            tv_sec: timeout.as_secs() as libc::time_t,
            tv_usec: timeout.subsec_micros() as libc::suseconds_t,
        };
        let n = libc::select(max + 1, &mut rset, &mut wset, std::ptr::null_mut(), &mut tv);
        if n <= 0 {
            return Ready {
                readable: false,
                writable: false,
                woken: false,
            };
        }
        Ready {
            readable: read.is_some_and(|fd| libc::FD_ISSET(fd, &rset)),
            writable: write.is_some_and(|fd| libc::FD_ISSET(fd, &wset)),
            woken: libc::FD_ISSET(wake, &rset),
        }
    }
}

/// Serves one connection: a request, then for a program its input and
/// output until one side is done.
fn handle(server: &Arc<Server>, stream: UnixStream) -> Result<()> {
    check_peer(&stream)?;
    no_sigpipe(&stream);
    let mut reader = stream.try_clone()?;
    let Some((Kind::Request, body)) = proto::read_frame(&mut reader)? else {
        return Ok(());
    };
    let request: Request = proto::parse(&body)?;
    let mut w = &stream;
    match request {
        Request::List => proto::write_json(&mut w, Kind::Reply, &Reply::Sessions(server.list()))?,
        Request::StopAll => {
            let sessions = lock(&server.sessions).clone();
            for s in &sessions {
                lock(&s.state).hang_up = true;
                s.wake();
            }
            let stopped = sessions.iter().map(|s| s.info()).collect();
            proto::write_json(&mut w, Kind::Reply, &Reply::Sessions(stopped))?;
        }
        Request::Spawn(spawn) => match server.spawn(spawn) {
            Ok(session) => serve(server, session, stream, reader, None)?,
            Err(e) => proto::write_json(&mut w, Kind::Reply, &Reply::Error(format!("{e:#}")))?,
        },
        Request::Attach { id, size } => match server.find(&id) {
            Some(session) => serve(server, session, stream, reader, Some(size))?,
            None => {
                let message = "It is no longer running.".to_string();
                proto::write_json(&mut w, Kind::Reply, &Reply::Error(message))?;
            }
        },
    }
    Ok(())
}

/// Connects an app to a program. With `attach`, the app's terminal is new:
/// it first gets the program's screen again.
fn serve(
    server: &Server,
    session: Arc<Session>,
    stream: UnixStream,
    mut reader: UnixStream,
    attach: Option<TermSize>,
) -> Result<()> {
    let (frames, queue) = sync_channel::<Arc<Vec<u8>>>(CLIENT_QUEUE);
    let writer = thread::spawn(move || {
        let mut w = &stream;
        for frame in queue {
            if w.write_all(&frame).is_err() {
                break;
            }
        }
        let _ = stream.shutdown(Shutdown::Both);
    });
    let id = server.next_client.fetch_add(1, Ordering::Relaxed);
    {
        let mut st = lock(&session.state);
        let send = |frame: Vec<u8>| {
            let _ = frames.send(Arc::new(frame));
        };
        send(proto::json_frame(
            Kind::Reply,
            &Reply::Session(session.info_with(&st)),
        ));
        if let Some(size) = attach {
            for chunk in st.screen.replay().chunks(REPLAY_CHUNK) {
                send(proto::frame(Kind::Replay, chunk));
            }
            send(proto::frame(Kind::Replayed, &[]));
            // Programs draw their whole screen again when the number of rows
            // or columns changes, which fixes what the replay could not
            // show. If it is the same, change it for a moment.
            let now = Instant::now();
            let cells = |s: TermSize| (s.cols, s.rows);
            if size.cols > 0 && size.rows > 1 {
                if cells(size) == cells(st.size) {
                    let smaller = TermSize {
                        rows: size.rows - 1,
                        ..size
                    };
                    st.resizes.push_back((now, smaller));
                    st.resizes.push_back((now + NUDGE, size));
                } else {
                    st.resizes.push_back((now, size));
                }
            }
        }
        match st.exit {
            Some(code) => send(proto::json_frame(Kind::Exit, &Exit { code })),
            None => st.clients.push(Client {
                id,
                frames: frames.clone(),
            }),
        }
    }
    // From now on the session holds the only sender: the writer stops when
    // the session lets the app go.
    drop(frames);
    session.wake();

    loop {
        let (kind, body) = match proto::read_frame(&mut reader) {
            Ok(Some(frame)) => frame,
            Ok(None) => break,
            Err(e) => {
                eprintln!("agentz server: reading from an app: {e}");
                break;
            }
        };
        let mut st = lock(&session.state);
        match kind {
            Kind::Input => st.input.extend_from_slice(&body),
            Kind::Resize => match proto::parse::<TermSize>(&body) {
                Ok(size) if size.cols > 0 && size.rows > 0 => {
                    st.resizes.push_back((Instant::now(), size))
                }
                _ => {}
            },
            Kind::Kill => st.hang_up = true,
            Kind::Update => {
                if let Ok(meta) = proto::parse(&body) {
                    st.meta = meta;
                }
            }
            _ => {}
        }
        drop(st);
        session.wake();
    }
    lock(&session.state).clients.retain(|c| c.id != id);
    let _ = writer.join();
    Ok(())
}

/// Only the user who runs the server may use it.
fn check_peer(stream: &UnixStream) -> Result<()> {
    let (mut uid, mut gid) = (0, 0);
    if unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0 {
        return Err(io::Error::last_os_error()).context("getpeereid");
    }
    if uid != unsafe { libc::geteuid() } {
        bail!("connection from another user (uid {uid})");
    }
    Ok(())
}
