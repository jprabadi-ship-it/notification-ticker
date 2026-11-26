import AppKit
import Security

/// 版番号（"v0.2.14" や "0.2.14"）を数の並びとして比べる。
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") { trimmed.removeFirst() }
        let parts = trimmed.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// GitHub の最新リリースのうち、使う部分だけ。
struct LatestRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    var version: AppVersion? { AppVersion(tagName) }
    var dmg: Asset? { assets.first { $0.name.lowercased().hasSuffix(".dmg") } }
}

/// 起動時に GitHub の最新リリースを確かめ、新しい版があれば聞いてから入れ替える。
///
/// 入れ替えは2段に分ける。まず動いたまま DMG を落として中のアプリを取り出し、署名を
/// 確かめる（ここで失敗しても今のアプリはそのまま）。準備ができたら終了し、外の小さな
/// シェルが終了を待ってから上書きし、起動し直す。古い版は /Applications ではなく
/// キャッシュのフォルダーに控えとして移す。
final class AppUpdater {
    static let releaseAPI = URL(string: "https://api.github.com/repos/jprabadi-ship-it/notification-ticker/releases/latest")!
    /// 配布物の署名者。開発者 ID のチーム ID と bundle id が一致しなければ入れない。
    static let teamIdentifier = "3HCG7Y94FX"
    static let skippedVersionKey = "updateSkippedVersion"
    /// 動作確認用。ここに版番号を入れると、今の版をその番号とみなす。
    static let pretendVersionKey = "updatePretendCurrentVersion"

    private let defaults: UserDefaults
    private let session: URLSession
    private var isBusy = false

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
    }

    var currentVersion: AppVersion? {
        if let pretend = defaults.string(forKey: Self.pretendVersionKey), let version = AppVersion(pretend) {
            return version
        }
        let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return AppVersion(text)
    }

    /// `userInitiated` が true（メニューから）なら、最新のときもそう知らせ、とばした版も聞き直す。
    func checkForUpdates(userInitiated: Bool) {
        guard !isBusy else { return }
        isBusy = true
        var request = URLRequest(url: Self.releaseAPI, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { [weak self] data, response, error in
            let release = data.flatMap { try? JSONDecoder().decode(LatestRelease.self, from: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                guard let release, let latest = release.version, let current = self.currentVersion else {
                    tickerLog.error("update: check failed \(error?.localizedDescription ?? "no release", privacy: .public)")
                    if userInitiated { self.inform("新しい版を確かめられませんでした。", detail: "ネットワークの状態をお確かめください。") }
                    return
                }
                guard current < latest, let dmg = release.dmg else {
                    if userInitiated { self.inform("最新の版です。", detail: "いまの版は \(current) です。") }
                    return
                }
                if !userInitiated, self.defaults.string(forKey: Self.skippedVersionKey) == latest.description { return }
                self.ask(current: current, latest: latest, dmg: dmg.browserDownloadURL)
            }
        }.resume()
    }

    private func ask(current: AppVersion, latest: AppVersion, dmg: URL) {
        let alert = NSAlert()
        alert.messageText = "Notification Ticker の新しい版 \(latest) があります"
        alert.informativeText = "いまの版は \(current) です。ダウンロードしてインストールしますか？\n準備ができたらアプリを一度終了し、入れ替えてから起動し直します。"
        alert.addButton(withTitle: "インストール")
        alert.addButton(withTitle: "あとで")
        alert.addButton(withTitle: "この版はとばす")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            prepare(latest: latest, dmg: dmg)
        case .alertThirdButtonReturn:
            defaults.set(latest.description, forKey: Self.skippedVersionKey)
        default:
            break
        }
    }

    /// ダウンロードから署名の確認まで。終わったら入れ替えに進む。
    private func prepare(latest: AppVersion, dmg: URL) {
        isBusy = true
        tickerLog.notice("update: downloading \(latest.description, privacy: .public)")
        session.downloadTask(with: dmg) { [weak self] location, _, error in
            guard let self else { return }
            let result: Result<URL, UpdateError>
            if let location {
                result = Self.extractApp(fromDMGAt: location, expecting: latest)
            } else {
                result = .failure(.download(error?.localizedDescription ?? "不明なエラー"))
            }
            DispatchQueue.main.async {
                self.isBusy = false
                switch result {
                case .success(let stagedApp):
                    self.install(stagedApp: stagedApp)
                case .failure(let failure):
                    tickerLog.error("update: prepare failed \(failure.message, privacy: .public)")
                    self.inform("新しい版を準備できませんでした。", detail: failure.message + "\nいまの版はそのまま使えます。")
                }
            }
        }.resume()
    }

    enum UpdateError: Error {
        case download(String)
        case mount(String)
        case invalid(String)

        var message: String {
            switch self {
            case .download(let text): return "ダウンロードに失敗しました（\(text)）。"
            case .mount(let text): return "ダウンロードしたファイルを開けませんでした（\(text)）。"
            case .invalid(let text): return "ダウンロードしたアプリを確認できませんでした（\(text)）。"
            }
        }
    }

    static var workDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jp.local.NotificationTicker/Update", isDirectory: true)
    }

    /// DMG を読み取り専用でつなぎ、中のアプリを作業フォルダーへ写して、署名と版を確かめる。
    static func extractApp(fromDMGAt dmgFile: URL, expecting latest: AppVersion) -> Result<URL, UpdateError> {
        let fileManager = FileManager.default
        let work = workDirectory
        try? fileManager.removeItem(at: work)
        do {
            try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            return .failure(.download(error.localizedDescription))
        }
        let dmgCopy = work.appendingPathComponent("NotificationTicker.dmg")
        let mountPoint = work.appendingPathComponent("mount", isDirectory: true)
        let staged = work.appendingPathComponent("NotificationTicker.app", isDirectory: true)
        do {
            try fileManager.moveItem(at: dmgFile, to: dmgCopy)
            try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        } catch {
            return .failure(.download(error.localizedDescription))
        }

        let attach = run("/usr/bin/hdiutil", ["attach", dmgCopy.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path])
        guard attach.status == 0 else { return .failure(.mount(attach.output)) }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

        let source = mountPoint.appendingPathComponent("NotificationTicker.app", isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else {
            return .failure(.invalid("DMG の中に NotificationTicker.app がありません"))
        }
        let copy = run("/usr/bin/ditto", [source.path, staged.path])
        guard copy.status == 0 else { return .failure(.invalid(copy.output)) }

        if let problem = verify(app: staged, expecting: latest) {
            try? fileManager.removeItem(at: staged)
            return .failure(.invalid(problem))
        }
        return .success(staged)
    }

    /// 問題がなければ nil。あれば理由。
    static func verify(app: URL, expecting latest: AppVersion) -> String? {
        let info = Bundle(url: app)?.infoDictionary ?? [:]
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            return "アプリの識別子が違います"
        }
        guard let text = info["CFBundleShortVersionString"] as? String, let version = AppVersion(text), version == latest else {
            return "版番号がリリースと合いません"
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            return "署名を読めません"
        }
        let requirementText = "anchor apple generic and identifier \"\(Bundle.main.bundleIdentifier ?? "")\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess else {
            return "署名の条件を作れません"
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else { return "署名が正しくありません（\(status)）" }
        return nil
    }

    /// 終了を待って上書きし、起動し直す小さなシェルを残してから終了する。
    private func install(stagedApp: URL) {
        let destination = Bundle.main.bundleURL
        let backup = Self.workDirectory.appendingPathComponent("previous.app", isDirectory: true)
        // 引数で渡し、文字列に埋め込まない。上書きに失敗したら元に戻して起動し直す。
        let script = """
        pid="$1"; staged="$2"; dest="$3"; backup="$4"
        for i in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        rm -rf "$backup"
        if mv "$dest" "$backup" && mv "$staged" "$dest"; then
          /usr/bin/open "$dest"
        else
          [ -d "$dest" ] || mv "$backup" "$dest"
          /usr/bin/open "$dest"
        fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), stagedApp.path, destination.path, backup.path]
        do {
            try process.run()
        } catch {
            inform("新しい版を入れられませんでした。", detail: error.localizedDescription)
            return
        }
        tickerLog.notice("update: installing, quitting now")
        NSApp.terminate(nil)
    }

    private func inform(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, String(output.prefix(300)))
    }
}
