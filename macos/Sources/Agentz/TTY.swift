// Finds the program Ghostty started on a terminal, and whether anything
// still runs on it. Ghostty starts programs through `login`, so this is
// about how Ghostty works, not about the agents.

import Darwin

/// Processes from `sysctl(KERN_PROC_...)`. Unlike `proc_pidinfo`, this
/// also works for processes of other users, like the setuid `login`.
private func kinfoProcs(_ mib: [Int32]) -> [kinfo_proc] {
    var mib = mib
    var size = 0
    guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
    // Leave room for processes started in between.
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
    size = procs.count * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
    return Array(procs.prefix(size / MemoryLayout<kinfo_proc>.stride))
}

private func command(_ p: kinfo_proc) -> String {
    var comm = p.kp_proc.p_comm
    return withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

/// The program we started on the terminal `ttyPath`. Ghostty runs it as
/// `login -> bash -c "exec -l ..."`, and `exec` keeps the pid, so it is the
/// child of a `login` that is our child, on that terminal.
func mainProcess(onTTY ttyPath: String, under parent: Int32 = getpid()) -> Int32? {
    var st = stat()
    guard stat(ttyPath, &st) == 0 else { return nil }
    let procs = kinfoProcs([CTL_KERN, KERN_PROC, KERN_PROC_TTY, st.st_rdev])
    let own = kinfoProcs([CTL_KERN, KERN_PROC, KERN_PROC_PID, parent]).first.map(command)
    let logins = Set(procs.filter { $0.kp_eproc.e_ppid == parent && command($0) == "login" }.map(\.kp_proc.p_pid))
    for p in procs {
        let ppid = p.kp_eproc.e_ppid
        if logins.contains(ppid) { return p.kp_proc.p_pid }
        // No login in between. A child still named like us has not started
        // its program yet.
        if ppid == parent, command(p) != "login", command(p) != own { return p.kp_proc.p_pid }
    }
    return nil
}

/// True while any process has the terminal `ttyPath` open as its own.
func ttyHasProcesses(_ ttyPath: String) -> Bool {
    var st = stat()
    guard stat(ttyPath, &st) == 0 else { return false }
    return !kinfoProcs([CTL_KERN, KERN_PROC, KERN_PROC_TTY, st.st_rdev]).isEmpty
}
