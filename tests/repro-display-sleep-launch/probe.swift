// YabaiProbe: a one-window app for reproducing yabai window-tracking bugs.
// It reads commands from $PROBE_CMD (default /tmp/yabai-probe.cmd), one per line, so a test can make it
// do what a real app might do to its window (hide, order out, close and reopen, post AX notifications).
import AppKit

let cmdPath = ProcessInfo.processInfo.environment["PROBE_CMD"] ?? "/tmp/yabai-probe.cmd"

final class Probe: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "YabaiProbe"
        window.contentView = NSTextField(labelWithString: "probe")
        window.makeKeyAndOrderFront(nil)
        log("window \(window.windowNumber) created")
    }

    func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        FileHandle.standardError.write("\(f.string(from: Date())) probe: \(s)\n".data(using: .utf8)!)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let delay = Double(ProcessInfo.processInfo.environment["PROBE_WINDOW_DELAY"] ?? "0") ?? 0
        if delay > 0 {
            log("delaying window by \(delay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.makeWindow() }
        } else {
            makeWindow()
        }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in self.poll() }
    }

    func poll() {
        guard let cmd = try? String(contentsOfFile: cmdPath, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: cmdPath)
        for c in cmd.split(whereSeparator: \.isNewline).map({ String($0).trimmingCharacters(in: .whitespaces) }) where !c.isEmpty {
            run(c)
        }
    }

    func run(_ c: String) {
        log("cmd \(c) (window \(window?.windowNumber ?? -1))")
        switch c {
        case "destroyed":   // AX says the window is gone, but it stays on screen
            NSAccessibility.post(element: window!, notification: .uiElementDestroyed)
        case "created":     // AX says a window appeared
            NSAccessibility.post(element: window!, notification: .windowCreated)
        case "orderout":    window.orderOut(nil)
        case "orderfront":  window.makeKeyAndOrderFront(nil)
        case "close":       window.close()
        case "reopen":      window.makeKeyAndOrderFront(nil)
        case "contentview": window.contentView = NSTextField(labelWithString: "probe \(Date())")
        case "newwindow":   let old = window; makeWindow(); old?.close()
        case "hide":        NSApp.hide(nil)
        case "unhide":      NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true)
        case "activate":    NSApp.activate(ignoringOtherApps: true)
        case "quit":        NSApp.terminate(nil)
        default:            log("unknown command")
        }
    }
}

let app = NSApplication.shared
let delegate = Probe()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
