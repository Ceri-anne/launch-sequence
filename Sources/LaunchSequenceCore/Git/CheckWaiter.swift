import Foundation

/// Polls CI checks until they finish, saying how it's going. Checks often take a
/// few minutes to register after a push, so "none yet" is waited out rather than
/// treated as an answer.
public struct CheckWaiter: Sendable {
    let console: Console
    /// How long to wait for the first check to register.
    var appearMinutes: Double
    /// How long to wait for registered checks to finish.
    var finishMinutes: Double
    var pollSeconds: Double = 15
    var progressEvery: Double = 30
    let sleep: @Sendable (Double) -> Void

    public init(console: Console, appearMinutes: Double = 5, finishMinutes: Double = 60,
                sleep: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.console = console; self.appearMinutes = appearMinutes; self.finishMinutes = finishMinutes; self.sleep = sleep
    }

    /// Returns `.passed` or `.failed` once every check has finished, `.none` if none
    /// registered within `appearMinutes`, or `.pending` if some were still running
    /// after `finishMinutes`.
    public func wait(_ what: String, fetch: () throws -> GitHub.CheckState) throws -> GitHub.CheckState {
        var elapsed: Double = 0
        var lastReport: Double = -.infinity
        var runningSince: Double?
        while true {
            let state = try fetch()
            let line: String
            switch state {
            case .passed, .failed:
                return state
            case .none:
                if elapsed >= appearMinutes * 60 { return .none }
                line = "… no checks on \(what) yet (\(Console.duration(elapsed)))"
            case .pending(let names):
                let since = runningSince ?? elapsed
                runningSince = since
                if elapsed - since >= finishMinutes * 60 { return state }
                line = "… \(what): waiting for \(names.joined(separator: ", ")) (\(Console.duration(elapsed)))"
            }
            if elapsed - lastReport >= progressEvery { console.info(line); lastReport = elapsed }
            sleep(pollSeconds)
            elapsed += pollSeconds
        }
    }
}
