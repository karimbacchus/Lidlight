import Foundation

/// Time source and single wake-up timer for `EngineCore`. Checks substitute a virtual clock.
package protocol EngineClock: AnyObject {
    /// Monotonic seconds.
    var now: TimeInterval { get }
    /// Called when an armed wake-up is due.
    var onWake: (() -> Void)? { get set }
    /// Arms the one wake-up (replacing any earlier one); nil cancels it.
    func arm(at time: TimeInterval?)
}

/// Real clock: a strict, zero-leeway `DispatchSourceTimer` on the engine's private serial queue.
final class DispatchEngineClock: EngineClock {
    private let timer: DispatchSourceTimer
    var onWake: (() -> Void)?

    init(queue: DispatchQueue) {
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .distantFuture, repeating: .never, leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in self?.onWake?() }
        timer.resume()
    }

    deinit {
        timer.cancel()
    }

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func arm(at time: TimeInterval?) {
        guard let time else {
            timer.schedule(deadline: .distantFuture, repeating: .never, leeway: .nanoseconds(0))
            return
        }
        let delay = max(0, time - now)
        timer.schedule(deadline: .now() + .nanoseconds(Int(delay * 1e9)), repeating: .never, leeway: .nanoseconds(0))
    }
}
