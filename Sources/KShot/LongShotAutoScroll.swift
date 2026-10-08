import Foundation

/// 每次滚动都等捕获流确认；没有新帧不能当作已经到底。
struct LongShotAutoScroll {
    enum Action: Equatable { case wait, scroll, pauseStationary, pauseStalled }
    enum Observation { case moved, unchanged, unmatched }

    private var startedAt = 0.0
    private var latestFrameAt: TimeInterval?
    private var pendingAt: TimeInterval?
    private var stationarySince: TimeInterval?
    private var stationaryAttempts = 0

    mutating func begin(at time: TimeInterval) {
        self = LongShotAutoScroll()
        startedAt = time
    }

    mutating func observe(_ observation: Observation, capturedAt: TimeInterval) {
        guard capturedAt >= startedAt, capturedAt > (latestFrameAt ?? -.infinity) else { return }
        latestFrameAt = capturedAt
        if observation != .unchanged {
            stationarySince = nil
            stationaryAttempts = 0
        }
        // 按捕获时间过滤旧帧，不能用主线程收到结果的时间判断。
        guard let pendingAt, capturedAt - pendingAt >= 0.06 else { return }
        self.pendingAt = nil
        if observation == .unchanged {
            if stationarySince == nil { stationarySince = pendingAt }
            stationaryAttempts += 1
        }
    }

    mutating func next(at time: TimeInterval) -> Action {
        if time - (latestFrameAt ?? startedAt) >= 3 { return .pauseStalled }
        // 有帧但始终没看到滚动后的结果，也暂停，避免连续发送事件越滚越远。
        if let pendingAt {
            return time - pendingAt >= 3 ? .pauseStalled : .wait
        }
        guard latestFrameAt != nil else { return .wait }
        if stationaryAttempts >= 3, let stationarySince, time - stationarySince >= 1.2 {
            return .pauseStationary
        }
        pendingAt = time
        return .scroll
    }
}
