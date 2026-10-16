import AppKit
import XCTest

@testable import CalopodMac

@MainActor
final class ApplyCoalescerTests: XCTestCase {
    func testBurstRunsOnceAndNestedRequestsDoNotRecurse() async {
        var runs = 0
        var coalescer: ApplyCoalescer!
        coalescer = ApplyCoalescer {
            runs += 1
            // A frame write inside the action posts a notification that asks again.
            coalescer.request()
        }
        for _ in 0..<5 { coalescer.request() }
        XCTAssertEqual(runs, 0)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runs, 1)
        coalescer.request()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runs, 2)
    }

    func testRectTolerance() {
        let a = NSRect(x: 0, y: 0, width: 100, height: 52)
        XCTAssertTrue(a.isClose(to: NSRect(x: 0.3, y: 0, width: 100.4, height: 52)))
        XCTAssertFalse(a.isClose(to: NSRect(x: 0, y: 2, width: 100, height: 52)))
    }
}
