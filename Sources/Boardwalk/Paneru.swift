import BoardwalkCore
import CoreGraphics
import Foundation

/// Follows Paneru, the scrolling window manager, when it's running (see
/// `PaneruDaemon`, which runs the one that comes with the app):
/// each desktop's strip of windows, for the dock to show in the same order, and
/// moves windows along it when they're dragged in the dock, or floats them over it. Talks to Paneru
/// through its command line tool. Without it, nothing here does anything
/// and the dock keeps its usual order. Used from the main thread only.
final class Paneru {
    /// The Paneru inside the app, next to its own executable; nil when run
    /// without a bundle (`swift run`).
    static var bundledExecutable: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "paneru")
    }

    /// Where Homebrew (Apple silicon, then Intel), Cargo and Nix install the
    /// tool, for when the app doesn't bring its own.
    private static let candidates = [
        "/opt/homebrew/bin/paneru",
        "/usr/local/bin/paneru",
        "~/.cargo/bin/paneru",
        "~/.nix-profile/bin/paneru",
        "/run/current-system/sw/bin/paneru",
    ]

    private let onChange: ([Int: Strip]) -> Void
    private let queue = DispatchQueue(label: "Boardwalk.paneru")
    private var subscription: Process?
    private var strips: [Int: Strip] = [:]
    /// When Paneru last reported windows moving.
    private var lastSlide = Date.distantPast
    private var pendingRead: DispatchWorkItem?

    /// `onChange` gets each desktop's strip, by desktop id, whenever it changes;
    /// empty while Paneru isn't running.
    init(onChange: @escaping ([Int: Strip]) -> Void) {
        self.onChange = onChange
    }

    var isRunning: Bool { subscription != nil }

    /// Listens for Paneru's events, checking again every few seconds while it isn't running.
    func start() {
        guard subscription == nil else { return }
        guard let executable = Self.executable else {
            retryLater()
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["subscribe", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let lines = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let events = lines.append(data).map(PaneruState.event(from:))
            DispatchQueue.main.async { self?.handle(events) }
        }
        // Paneru quitting ends the subscription.
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.subscription = nil
                self.publish([:])
                self.retryLater()
            }
        }
        do {
            try process.run()
        } catch {
            retryLater()
            return
        }
        subscription = process
        readLayout()
    }

    func stop() {
        subscription?.terminationHandler = nil
        subscription?.terminate()
        subscription = nil
    }

    /// Moves the column holding `windowID` to place `index` of `desktop`'s strip,
    /// leaving focus where it is. `done` gets whether Paneru put it there.
    func move(window windowID: Int, toColumn index: Int, onDesktop desktop: Int, done: @escaping (Bool) -> Void) {
        change({ Self.move(windowID, toColumn: index, onDesktop: desktop) }, done: done)
    }

    /// Floats a window of `desktop`'s over its strip, where Paneru pops it fully
    /// on screen, or tiles it back in. `done` gets whether Paneru did it.
    func setFloating(window windowID: Int, _ floating: Bool, onDesktop desktop: Int, done: @escaping (Bool) -> Void) {
        change({ Self.setFloating(windowID, floating, onDesktop: desktop) }, done: done)
    }

    // MARK: Private

    private static var executable: URL? {
        bundledExecutable ?? candidates.lazy
            .map { ($0 as NSString).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func retryLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
    }

    /// While windows slide, Paneru reports where they are every frame. That's
    /// enough to move the dock's frame along, without asking Paneru for anything
    /// while it animates. Other changes, and whatever a slide changed besides
    /// (like a new stack), come from reading the whole layout afterwards.
    private func handle(_ events: [PaneruEvent]) {
        var strips = self.strips
        for event in events {
            switch event {
            case let .onScreen(desktop, frames):
                strips[desktop]?.updateInView(onScreen: frames, display: CGDisplayBounds(CGMainDisplayID()))
                lastSlide = Date()
                readLayoutSoon()
            case .titleChanged:
                break
            case .other:
                readLayoutSoon()
            }
        }
        publish(strips)
    }

    /// Reads the layout in a moment, or once windows have stopped sliding.
    private func readLayoutSoon() {
        guard pendingRead == nil else { return }
        let read = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRead = nil
            if Date().timeIntervalSince(self.lastSlide) < 0.25 {
                self.readLayoutSoon()
            } else {
                self.readLayout()
            }
        }
        pendingRead = read
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: read)
    }

    private func readLayout() {
        queue.async { [weak self] in
            let strips = Self.layout()
            DispatchQueue.main.async {
                guard let self, let strips, self.isRunning else { return }
                self.publish(strips)
            }
        }
    }

    /// Runs `work` on `queue`, then shows the layout it ends with, or reads it
    /// again if it failed.
    private func change(_ work: @escaping () -> [Int: Strip]?, done: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            let strips = work()
            DispatchQueue.main.async {
                guard let self else { return }
                if let strips, self.isRunning {
                    self.publish(strips)
                } else {
                    self.readLayout()
                }
                done(strips != nil)
            }
        }
    }

    private func publish(_ strips: [Int: Strip]) {
        guard strips != self.strips else { return }
        self.strips = strips
        onChange(strips)
    }

    /// Does the moving, on `queue`. Returns the layout once the window is there,
    /// or nil if Paneru didn't take the command (an older version doesn't know
    /// it) or the window didn't get there in time.
    private static func move(_ windowID: Int, toColumn index: Int, onDesktop desktop: Int) -> [Int: Strip]? {
        guard run(["send-cmd", "window", "place", String(windowID), String(index + 1)]) != nil else { return nil }
        var strips: [Int: Strip]?
        let placed = wait(until: {
            strips = layout()
            return strips?[desktop]?.column(of: windowID) == index
        })
        return placed ? strips : nil
    }

    /// Does the floating or tiling, on `queue`. Paneru's command switches between
    /// the two, so it's only sent when the window isn't that way already. Returns
    /// the layout once it is, or nil if the window isn't on `desktop` or Paneru
    /// didn't take the command in time.
    private static func setFloating(_ windowID: Int, _ floating: Bool, onDesktop desktop: Int) -> [Int: Strip]? {
        guard let now = layout()?[desktop]?.isFloating(windowID) else { return nil }
        if now != floating {
            guard run(["send-cmd", "window", "manage", String(windowID)]) != nil else { return nil }
        }
        var strips: [Int: Strip]?
        let changed = wait(until: {
            strips = layout()
            return strips?[desktop]?.isFloating(windowID) == floating
        })
        return changed ? strips : nil
    }

    private static func layout() -> [Int: Strip]? {
        run(["query", "state", "--json"]).flatMap {
            try? PaneruState.strips(from: $0, display: CGDisplayBounds(CGMainDisplayID()))
        }
    }

    /// Checks `condition` every few milliseconds until it holds, for up to a second.
    private static func wait(until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return false
    }

    /// Runs the tool and returns what it printed, or nil if it failed. Gives up
    /// after two seconds, so a stuck Paneru can't hold up the dock.
    static func run(_ arguments: [String]) -> Data? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}

/// Splits what a tool prints into lines, keeping a line that's only partly
/// arrived for the next read. Used from one queue at a time.
private final class LineBuffer {
    private var pending = Data()

    func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(Data(pending[pending.startIndex..<end]))
            pending = pending[pending.index(after: end)...]
        }
        return lines
    }
}
