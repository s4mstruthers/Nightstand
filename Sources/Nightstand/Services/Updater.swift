import AppKit
import SwiftUI

/// A published version of Nightstand, as GitHub describes it.
struct AppRelease: Equatable, Sendable {
    var version: String
    var notes: String
    var page: URL
    /// The disk image to install from; nil when the release has none.
    var download: URL?
}

/// Reads the project's releases on GitHub.
enum UpdateFeed {
    static let latest = URL(string: "https://api.github.com/repos/s4mstruthers/Nightstand/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/s4mstruthers/Nightstand/releases/latest")!

    struct Unreadable: Error {}

    static func parse(_ data: Data) throws -> AppRelease {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { throw Unreadable() }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let download = assets.lazy
            .compactMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
            // Only ever download from GitHub itself, over HTTPS.
            .first { $0.pathExtension.lowercased() == "dmg" && $0.scheme == "https" && $0.host == "github.com" }
        return AppRelease(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                          notes: json["body"] as? String ?? "",
                          page: (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage,
                          download: download)
    }

    static func fetchLatest() async throws -> AppRelease {
        var request = URLRequest(url: latest, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Nightstand", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Unreadable() }
        return try parse(data)
    }

    /// Compares dotted version numbers: 0.10.0 is newer than 0.9.2, and 1.0 equals 1.0.0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            let core = version.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Release notes are written in Markdown; this keeps headings, bullets and emphasis.
    static func formatted(_ notes: String) -> AttributedString {
        var result = AttributedString()
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        for line in notes.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            if line.hasPrefix("**Full Changelog**") { continue }
            var text = line
            var heading = false
            if let range = text.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                text.removeSubrange(range)
                heading = true
            } else if let range = text.range(of: #"^\s*[-*]\s+"#, options: .regularExpression) {
                text.replaceSubrange(range, with: "•  ")
            }
            var styled = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
            if heading { styled.font = .headline }
            result += styled + AttributedString("\n")
        }
        while result.characters.last?.isNewline == true { result.characters.removeLast() }
        return result
    }
}

/// Replaces an installed copy of the app with the one inside a downloaded disk image.
enum UpdateInstaller {
    enum Failure: LocalizedError {
        case notInImage, wrongApp, damaged

        var errorDescription: String? {
            switch self {
            case .notInImage: "The download doesn't contain Nightstand."
            case .wrongApp: "The download isn't the expected version of Nightstand."
            case .damaged: "The download is damaged."
            }
        }
    }

    /// False when the app can't be replaced where it is: opened straight from the disk image, run from a
    /// read-only or quarantined location, or in a folder this user can't change.
    static func canReplace(_ bundle: URL) -> Bool {
        let path = bundle.path
        guard bundle.pathExtension == "app", !path.contains("/AppTranslocation/"),
              !path.hasPrefix("/Volumes/") else { return false }
        return FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: path)
    }

    static func install(image: URL, version: String, bundleID: String, over bundle: URL) throws {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appending(path: "nightstand-update-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mount) }
        try Shell.run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen",
                                           "-mountpoint", mount.path])
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let source = mount.appending(path: bundle.lastPathComponent)
        guard fm.fileExists(atPath: source.appending(path: "Contents/Info.plist").path) else {
            throw Failure.notInImage
        }
        // Copy next to the installed app first, so the swap is a rename on the same volume.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle,
                                 create: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appending(path: bundle.lastPathComponent)
        try Shell.run("/usr/bin/ditto", [source.path, staged.path])
        _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

        // Check the copy that will actually be installed.
        let info = NSDictionary(contentsOf: staged.appending(path: "Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID,
              info?["CFBundleShortVersionString"] as? String == version else { throw Failure.wrongApp }
        do {
            try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        } catch {
            throw Failure.damaged
        }
        _ = try fm.replaceItemAt(bundle, withItemAt: staged)
    }

    /// Opens the app again once this process has quit.
    static func relaunch(_ bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"while kill -0 "$0" 2>/dev/null; do sleep 0.2; done; open "$1""#,
                             String(ProcessInfo.processInfo.processIdentifier), bundle.path]
        try? process.run()
    }
}

/// Checks GitHub for a newer release and installs it in place.
@MainActor @Observable
final class Updater {
    enum Phase: Equatable {
        case idle, checking, downloading(Double), installing, failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var release: AppRelease?
    var showSheet = false
    var automatic = UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "checkForUpdates") }
    }

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    private let bundle = Bundle.main.bundleURL
    private let activity: ActivityCenter

    init(activity: ActivityCenter) {
        self.activity = activity
    }

    /// Development builds run outside an app bundle have nothing to update.
    private var isInstalledApp: Bool { bundle.pathExtension == "app" }
    var canInstallInPlace: Bool { release?.download != nil && UpdateInstaller.canReplace(bundle) }
    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: true
        case .idle, .failed: false
        }
    }

    /// Checks at most once a day, and stays quiet unless there is something new.
    func checkOnLaunch() {
        guard automatic, isInstalledApp else { return }
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard !isBusy else {
            if userInitiated, release != nil { showSheet = true }
            return
        }
        phase = .checking
        do {
            let latest = try await UpdateFeed.fetchLatest()
            phase = .idle
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
            guard UpdateFeed.isNewer(latest.version, than: currentVersion) else {
                if userInitiated { activity.flash("Nightstand is up to date", detail: "Version \(currentVersion)") }
                return
            }
            if !userInitiated, UserDefaults.standard.string(forKey: "skippedVersion") == latest.version { return }
            offer(latest)
        } catch {
            phase = .idle
            if userInitiated {
                activity.flash("Couldn't check for updates", detail: "Check your internet connection and try again.")
            }
        }
    }

    func offer(_ latest: AppRelease) {
        release = latest
        showSheet = true
    }

    func skip() {
        UserDefaults.standard.set(release?.version, forKey: "skippedVersion")
        showSheet = false
    }

    func openReleasePage() {
        NSWorkspace.shared.open(release?.page ?? UpdateFeed.releasesPage)
        showSheet = false
    }

    func install() async {
        guard !isBusy, let release, let url = release.download,
              let bundleID = Bundle.main.bundleIdentifier else { return }
        phase = .downloading(0)
        do {
            let image = try await Self.download(url) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.phase { self?.phase = .downloading(fraction) }
                }
            }
            defer { try? FileManager.default.removeItem(at: image) }
            phase = .installing
            let bundle = bundle
            try await Task.detached {
                try UpdateInstaller.install(image: image, version: release.version, bundleID: bundleID, over: bundle)
            }.value
            UpdateInstaller.relaunch(bundle)
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private final class ProgressWatch: @unchecked Sendable {
        var value: NSKeyValueObservation?
    }

    private nonisolated static func download(_ url: URL,
                                             progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "Nightstand-update-\(UUID().uuidString).dmg")
        let observation = ProgressWatch()
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                observation.value = nil
                do {
                    if let error { throw error }
                    guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw URLError(.badServerResponse)
                    }
                    try FileManager.default.moveItem(at: file, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation.value = task.progress.observe(\.fractionCompleted) { value, _ in
                progress(value.fractionCompleted)
            }
            task.resume()
        }
    }
}
