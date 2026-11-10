import Foundation

/// Terminal output and confirmations. Every step that publishes something asks
/// here first, unless `--yes` was passed.
public struct Console: Sendable {
    public var verbose: Bool
    public var assumeYes: Bool
    var write: @Sendable (String) -> Void
    var readLine: @Sendable () -> String?
    var isInteractive: Bool
    /// How long a step runs before a "still working" line, and how often after that.
    var heartbeatSeconds: Double = 15

    public init(verbose: Bool = false, assumeYes: Bool = false) {
        self.verbose = verbose
        self.assumeYes = assumeYes
        self.write = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }
        self.readLine = { Swift.readLine() }
        self.isInteractive = isatty(STDIN_FILENO) != 0
    }

    /// For tests: scripted answers, captured output.
    public init(answers: [String], assumeYes: Bool = false, heartbeatSeconds: Double = 15, sink: @escaping @Sendable (String) -> Void) {
        let queue = AnswerQueue(answers)
        self.verbose = false
        self.assumeYes = assumeYes
        self.heartbeatSeconds = heartbeatSeconds
        self.write = sink
        self.readLine = { queue.next() }
        self.isInteractive = true
    }

    public func stage(_ title: String) { write("\n\u{1B}[1m▶ \(title)\u{1B}[0m") }
    public func step(_ text: String) { write("  • \(text)") }
    public func ok(_ text: String) { write("  ✓ \(text)") }
    public func warn(_ text: String) { write("  ⚠️  \(text)") }
    public func info(_ text: String) { write("    \(text)") }
    public func dry(_ text: String) { write("  [dry run] would: \(text)") }
    public func debug(_ text: String) { if verbose { write("    \u{1B}[2m\(text)\u{1B}[0m") } }

    /// Asks a yes/no question; the default is no. `--yes` answers yes. Without a terminal
    /// (and without `--yes`) it refuses rather than guessing.
    public func confirm(_ question: String) throws -> Bool {
        if assumeYes { write("  ? \(question) [y/N] y (--yes)"); return true }
        guard isInteractive else {
            throw LaunchError.aborted("\"\(question)\" needs an answer, but there's no terminal. Re-run in a terminal or pass --yes.")
        }
        write("  ? \(question) [y/N] ")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return answer == "y" || answer == "yes"
    }

    /// Confirms, or stops the run.
    public func require(_ question: String) throws {
        guard try confirm(question) else { throw LaunchError.aborted("you said no to \"\(question)\"") }
    }

    /// Waits for the person to do something manual (e.g. unfold a simulator), then
    /// prints `acknowledgement` straight away so they can see the Enter was received.
    public func pause(_ instruction: String, acknowledgement: String = "Got it, carrying on…") throws {
        if assumeYes && !isInteractive {
            throw LaunchError.aborted("Manual step needed but no terminal: \(instruction)")
        }
        write("  ✋ \(instruction)\n     Then click back into this terminal and press Enter (or type q to stop).\n     A key pressed in another window, like Simulator, doesn't reach launchseq.")
        if readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "q" {
            throw LaunchError.aborted("stopped at a manual step")
        }
        ok(acknowledgement)
    }

    /// Runs `body`, printing `… still <what> (<elapsed>)` every `heartbeatSeconds` until it
    /// finishes, so a long step never looks stuck.
    public func whileWorking<T>(_ what: String, _ body: () throws -> T) rethrows -> T {
        let beat = Heartbeat(what: what, every: heartbeatSeconds, write: write)
        defer { beat.stop() }
        return try body()
    }

    public func whileWorking<T>(_ what: String, _ body: () async throws -> T) async rethrows -> T {
        let beat = Heartbeat(what: what, every: heartbeatSeconds, write: write)
        defer { beat.stop() }
        return try await body()
    }

    /// `45s`, `2m 5s`.
    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

/// Prints a "still working" line on a background timer until stopped.
final class Heartbeat: @unchecked Sendable {
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var stopped = false

    init(what: String, every interval: Double, write: @escaping @Sendable (String) -> Void) {
        let started = Date()
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.stopped else { return }
            write("    … still \(what) (\(Console.duration(Date().timeIntervalSince(started))))")
        }
        timer.resume()
    }

    /// After this returns, no more lines are written.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        timer.cancel()
    }
}

final class AnswerQueue: @unchecked Sendable {
    private var answers: [String]
    private let lock = NSLock()
    init(_ answers: [String]) { self.answers = answers }
    func next() -> String? {
        lock.lock(); defer { lock.unlock() }
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}
