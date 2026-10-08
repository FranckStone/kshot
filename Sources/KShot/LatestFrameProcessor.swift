import Foundation

/// 串行处理当前帧，等待期间只保留最新输入；控制操作不会排在无限增长的帧队列后面。
final class LatestFrameProcessor<Input: Sendable>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let handle: @Sendable (Input) -> Void
    private let merge: @Sendable (Input, Input) -> Input
    private let lock = NSLock()
    private var pending: Input?
    private var scheduled = false
    private var stopped = false

    init(queue: DispatchQueue, merge: @escaping @Sendable (Input, Input) -> Input = { _, new in new },
         handle: @escaping @Sendable (Input) -> Void) {
        self.queue = queue
        self.merge = merge
        self.handle = handle
    }

    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func submit(_ input: Input) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        pending = pending.map { merge($0, input) } ?? input
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { queue.async { self.drainOne() } }
    }

    func stop() {
        lock.lock()
        stopped = true
        pending = nil
        lock.unlock()
    }

    func enqueue(_ body: @escaping @Sendable () -> Void) { queue.async(execute: body) }

    func perform<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private func drainOne() {
        lock.lock()
        guard !stopped, let input = pending else {
            scheduled = false
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()
        autoreleasepool { handle(input) }
        // 每次处理后重新排队，让模式切换和结束合成等控制操作有机会先执行。
        queue.async { self.drainOne() }
    }
}
