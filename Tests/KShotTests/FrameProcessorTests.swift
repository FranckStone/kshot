import Foundation
import XCTest
@testable import KShot

final class FrameProcessorTests: XCTestCase {
    /// 只在处理器的串行队列中访问。
    private final class Values: @unchecked Sendable { var items: [Int] = [] }
    func testSlowWorkerProcessesOnlyLatestWaitingFrameAndAllowsControlOperations() async {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let latest = expectation(description: "latest frame")
        let control = expectation(description: "control operation")
        let queue = DispatchQueue(label: "test.latest-frame")
        let handled = Values()
        let processor = LatestFrameProcessor<Int>(queue: queue) { value in
            if value == 0 { started.signal(); release.wait() }
            handled.items.append(value)
            if value == 100 { latest.fulfill() }
        }
        processor.submit(0)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        for value in 1...100 { processor.submit(value) }
        processor.enqueue { control.fulfill() }
        release.signal()
        await fulfillment(of: [control, latest], timeout: 2)
        let values = await processor.perform { handled.items }
        XCTAssertEqual(values, [0, 100])
        processor.stop()
    }

    func testStopDoesNotWaitForSlowWorkerAndDiscardsPendingFrames() async {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "test.stop-frame")
        let handled = Values()
        let processor = LatestFrameProcessor<Int>(queue: queue) { value in
            if value == 0 { started.signal(); release.wait() }
            handled.items.append(value)
        }
        processor.submit(0)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        processor.submit(1)
        let start = ProcessInfo.processInfo.systemUptime
        processor.stop()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.2)
        processor.submit(2)
        release.signal()
        let values = await processor.perform { handled.items }
        XCTAssertEqual(values, [0])
    }

    func testAwaitingWorkerLeavesMainActorResponsive() async {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let processor = LatestFrameProcessor<Int>(queue: DispatchQueue(label: "test.async-finish")) { _ in
            started.signal(); release.wait()
        }
        processor.submit(1)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        processor.stop()
        let completion = Task { await processor.perform { 42 } }
        let heartbeat = await MainActor.run { true }
        XCTAssertTrue(heartbeat)
        release.signal()
        let value = await completion.value
        XCTAssertEqual(value, 42)
    }
}
