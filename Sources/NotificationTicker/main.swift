import AppKit

/// 同じバンドルIDのアプリが既に動いていれば、自分は起動せずに終了する。
/// /Applications 版と dist 版を別々に開いた場合や、直接バイナリを起動した場合に
/// ティッカーが二重に流れるのを防ぐ。先に動いている方を前面に出してから終わる。
func exitIfAlreadyRunning() {
    guard let bundleID = Bundle.main.bundleIdentifier else { return }
    let myPID = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != myPID }
    guard let existing = others.first else { return }
    existing.activate()
    exit(0)
}

exitIfAlreadyRunning()

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
