import ApplicationServices
import Foundation

/// Runs the window manager: the Paneru that comes inside the app, unless another
/// Paneru (Homebrew's service, say) is already running, which then keeps the
/// windows. Paneru runs as the app's own child, so macOS asks for one
/// Accessibility permission, the app's, for both: the app asks for it under its
/// own name and starts Paneru once it has it, and tells Paneru it's bundled
/// (`PANERU_EMBEDDED`), so Paneru shows no prompt or menu bar item of its own. If it stops, it's started
/// again, after a wait that grows while it keeps stopping soon after starting.
/// Its output goes to `~/Library/Logs/Boardwalk/paneru.log`. Paneru without a
/// configuration of its own leaves no room for the dock and ignores swipes, so
/// the first time there's none, the app's starter one is written for it. Used
/// from the main thread only.
final class PaneruDaemon {
    private let executable: URL?
    private var process: Process?
    private var running = false
    private var startedAt = Date.distantPast
    private var retryDelay: TimeInterval = 1
    private var pendingLaunch: DispatchWorkItem?
    /// Whether macOS has been asked for the permission yet: once per run, then
    /// the app waits for it to be granted in System Settings.
    private var askedForPermission = false
    /// How often to look again while another Paneru keeps the windows.
    private static let checkInterval: TimeInterval = 10
    /// Runs this long and it's taken to have started fine, so a later stop is
    /// retried straight away rather than after a growing wait.
    private static let settledAfter: TimeInterval = 60

    init(executable: URL? = Paneru.bundledExecutable) {
        self.executable = executable
    }

    func start() {
        guard !running else { return }
        running = true
        launch()
    }

    /// Stops Paneru, if it's ours. It exits cleanly, leaving windows where they are.
    func stop() {
        running = false
        pendingLaunch?.cancel()
        pendingLaunch = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    private func launch() {
        guard running, process == nil, let executable else { return }
        guard isTrusted() else {
            launchLater(after: 2)
            return
        }
        DispatchQueue.global().async { [weak self] in
            // Asking it for its state is how to tell whether one is running.
            let answers = Paneru.run(["query", "state", "--json"]) != nil
            DispatchQueue.main.async {
                guard let self, self.running, self.process == nil else { return }
                if answers {
                    self.launchLater(after: Self.checkInterval)
                } else {
                    self.run(executable)
                }
            }
        }
    }

    private func run(_ executable: URL) {
        Self.writeStarterConfiguration()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["launch"]
        process.environment = ProcessInfo.processInfo.environment.merging(["PANERU_EMBEDDED": "1"]) { $1 }
        if let log = Self.log() {
            process.standardOutput = log
            process.standardError = log
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.exited() }
        }
        do {
            try process.run()
        } catch {
            exited()
            return
        }
        self.process = process
        startedAt = Date()
    }

    private func exited() {
        process = nil
        guard running else { return }
        if Date().timeIntervalSince(startedAt) > Self.settledAfter {
            retryDelay = 1
        } else {
            retryDelay = min(retryDelay * 2, 60)
        }
        launchLater(after: retryDelay)
    }

    /// Asks for the permission the first time (macOS shows its own prompt, with
    /// the app's name).
    private func isTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        guard !askedForPermission else { return false }
        askedForPermission = true
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    private func launchLater(after delay: TimeInterval) {
        pendingLaunch?.cancel()
        let launch = DispatchWorkItem { [weak self] in
            self?.pendingLaunch = nil
            self?.launch()
        }
        pendingLaunch = launch
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: launch)
    }

    /// Writes the app's starter configuration to `~/.paneru.toml` when Paneru
    /// would find none: not in `$PANERU_CONFIG`, `~/.paneru`, `~/.paneru.toml`
    /// or `~/.config/paneru/paneru.toml`.
    private static func writeStarterConfiguration() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? home.appendingPathComponent(".config", isDirectory: true)
        let existing = [
            ProcessInfo.processInfo.environment["PANERU_CONFIG"].map { URL(fileURLWithPath: $0) },
            home.appendingPathComponent(".paneru"),
            home.appendingPathComponent(".paneru.toml"),
            configHome.appendingPathComponent("paneru/paneru.toml"),
        ].compactMap { $0 }
        guard !existing.contains(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let starter = Bundle.main.url(forResource: "paneru", withExtension: "toml") else { return }
        try? FileManager.default.copyItem(at: starter, to: home.appendingPathComponent(".paneru.toml"))
    }

    /// The log, opened for appending; nil if it can't be.
    private static func log() -> FileHandle? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Boardwalk", isDirectory: true)
        let file = directory.appendingPathComponent("paneru.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }
}
