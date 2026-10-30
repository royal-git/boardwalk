import Foundation

/// Runs the window manager: the Paneru that comes inside the app, unless another
/// Paneru (Homebrew's service, say) is already running, which then keeps the
/// windows. Paneru runs as the app's own child, so macOS asks for one
/// Accessibility permission, the app's, for both. If it stops, it's started
/// again, after a wait that grows while it keeps stopping soon after starting.
/// Its output goes to `~/Library/Logs/Boardwalk/paneru.log`. Used from the main
/// thread only.
final class PaneruDaemon {
    private let executable: URL?
    private var process: Process?
    private var running = false
    private var startedAt = Date.distantPast
    private var retryDelay: TimeInterval = 1
    private var pendingLaunch: DispatchWorkItem?
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
        let process = Process()
        process.executableURL = executable
        process.arguments = ["launch"]
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

    private func launchLater(after delay: TimeInterval) {
        pendingLaunch?.cancel()
        let launch = DispatchWorkItem { [weak self] in
            self?.pendingLaunch = nil
            self?.launch()
        }
        pendingLaunch = launch
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: launch)
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
