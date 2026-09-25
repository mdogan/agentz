import AgentzCore
import AppKit

let usage = """
usage: agentz [folder]                  open the app for a folder (default: here)
       agentz statusline                Claude's status line command (reads stdin)
       agentz statusline install        report limits from every manual `claude` launch
       agentz statusline uninstall      restore the earlier status line
       agentz --list                    list this project's sessions
"""

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "statusline":
    if args.count > 1 {
        do {
            print(try configureStatusLine(args[1], Bundle.main.executablePath ?? CommandLine.arguments[0]))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("agentz: \(error)\n".utf8))
            exit(1)
        }
    }
    exit(runStatusLine())

case "--list":
    for s in SessionScanner().sessions(FileManager.default.currentDirectoryPath) where s.inProject {
        print("\(s.agent.name)\t\(s.id)\t\(s.cwd)\t\(s.title)")
    }
    exit(0)

case "-h", "--help":
    print(usage)
    exit(0)

default:
    break
}

// Started from a terminal: hand the folder to the app and return, like
// `code .`. The app may be running already; then it switches folders.
let bundle = Bundle.main.bundleURL
if isatty(STDIN_FILENO) != 0, bundle.pathExtension == "app", !args.contains("--project") {
    let target = args.first ?? FileManager.default.currentDirectoryPath
    let dir = URL(fileURLWithPath: target).standardizedFileURL.path
    guard isDirectory(dir) else {
        FileHandle.standardError.write(Data("agentz: not a folder: \(target)\n\(usage)\n".utf8))
        exit(2)
    }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-a", bundle.path, dir]
    try? open.run()
    open.waitUntilExit()
    exit(open.terminationStatus)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
