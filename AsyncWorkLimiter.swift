import Foundation

final class AsyncWorkLimiter {
    typealias Finish = () -> Void
    typealias Work = (@escaping Finish) -> Void

    private let maxConcurrent: Int
    private let lock = NSLock()
    private var activeCount = 0
    private var pending: [Work] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func schedule(_ work: @escaping Work) {
        let workToRun: Work?
        lock.lock()
        if activeCount < maxConcurrent {
            activeCount += 1
            workToRun = work
        } else {
            pending.append(work)
            workToRun = nil
        }
        lock.unlock()

        if let workToRun {
            run(workToRun)
        }
    }

    private func run(_ work: @escaping Work) {
        work { [weak self] in
            self?.completeOne()
        }
    }

    private func completeOne() {
        let next: Work?
        lock.lock()
        if pending.isEmpty {
            activeCount -= 1
            next = nil
        } else {
            next = pending.removeFirst()
        }
        lock.unlock()

        if let next {
            run(next)
        }
    }
}
