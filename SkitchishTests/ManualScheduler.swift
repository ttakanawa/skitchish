import Foundation

@testable import Skitchish

@MainActor
final class ManualScheduler {
    private final class Entry {
        let deadline: TimeInterval
        let order: Int
        var action: DelayedActionScheduler.Action?

        init(deadline: TimeInterval, order: Int, action: @escaping DelayedActionScheduler.Action) {
            self.deadline = deadline
            self.order = order
            self.action = action
        }
    }

    private var now: TimeInterval = 0
    private var nextOrder = 0
    private var entries: [Entry] = []

    var scheduler: DelayedActionScheduler {
        DelayedActionScheduler { [self] delay, action in
            precondition(delay >= 0)
            let entry = Entry(deadline: now + delay, order: nextOrder, action: action)
            nextOrder += 1
            entries.append(entry)
            return { entry.action = nil }
        }
    }

    func advance(by interval: TimeInterval) {
        precondition(interval >= 0)
        let target = now + interval
        while let entry = entries.filter({ $0.deadline <= target }).min(by: {
            $0.deadline == $1.deadline ? $0.order < $1.order : $0.deadline < $1.deadline
        }) {
            entries.removeAll { $0 === entry }
            now = entry.deadline
            let action = entry.action
            entry.action = nil
            action?()
        }
        now = target
    }
}
