// What runs on a program's terminal, from the kernel. The agentz server
// holds the terminals, not the app, so the app asks about the processes on
// them instead of the terminals themselves.

import Darwin

/// Processes from `sysctl(KERN_PROC_...)`. Unlike `proc_pidinfo`, this
/// also works for processes of other users, like a setuid `sudo`.
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

/// The foreground process group of the terminal `pid` runs on. Nil if it
/// has none, or `pid` is gone.
func terminalForegroundGroup(of pid: Int32) -> Int32? {
    let group = kinfoProcs([CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]).first?.kp_eproc.e_tpgid ?? -1
    return group > 0 ? group : nil
}

/// True if another process runs on the terminal of `pid`: the jobs of a
/// shell, in the foreground or not, and what they started, unless they
/// left the terminal.
func terminalHasOthers(_ pid: Int32) -> Bool {
    guard let own = kinfoProcs([CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]).first,
          own.kp_eproc.e_tdev != -1
    else { return false }
    return kinfoProcs([CTL_KERN, KERN_PROC, KERN_PROC_TTY, own.kp_eproc.e_tdev]).contains { $0.kp_proc.p_pid != pid }
}
