import Foundation

/// Schedules one UI action and returns an idempotent cancellation operation.
struct DelayedActionScheduler {
    typealias Action = @MainActor () -> Void
    typealias Cancellation = @MainActor () -> Void

    let schedule: @MainActor (TimeInterval, @escaping Action) -> Cancellation

    // Keep the options panel's existing default run-loop mode behavior.
    static let mainRunLoop = Self { delay, action in
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        return { timer.invalidate() }
    }

    static let mainQueue = Self { delay, action in
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }
}
