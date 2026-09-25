import Darwin
import Foundation

public enum Paths {
    public static var home: String { NSHomeDirectory() }

    static func env(_ name: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else { return nil }
        return v
    }
}

public func isDirectory(_ path: String) -> Bool {
    var st = stat()
    return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
}

/// The path with symlinks resolved, like Rust's `canonicalize`. Unlike
/// `URL.resolvingSymlinksInPath`, this keeps `/private/tmp` as it is.
public func realPath(_ path: String) -> String? {
    guard let p = realpath(path, nil) else { return nil }
    defer { free(p) }
    return String(cString: p)
}

/// True if `path` is `root` or inside it, comparing whole components.
public func pathStarts(_ path: String, with root: String) -> Bool {
    let root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
    if path == root { return true }
    return path.hasPrefix(root == "/" ? "/" : root + "/")
}

/// The last path component, e.g. `agentz` for `/a/b/agentz`.
public func baseName(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

/// A backslash before each character the shell would treat specially, as
/// Ghostty does for dropped files.
public func shellEscape(_ path: String) -> String {
    let special = Set(#"\ ()[]{}<>"'`!#$&;|*?"# + "\t")
    var out = ""
    for c in path {
        if special.contains(c) { out.append("\\") }
        out.append(c)
    }
    return out
}

/// Recent folders with `dir` first, without repeats, at most `limit`.
public func addingRecent(_ dir: String, to recents: [String], limit: Int = 10) -> [String] {
    Array(([dir] + recents.filter { $0 != dir }).prefix(limit))
}
