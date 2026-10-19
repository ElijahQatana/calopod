import AppKit
import XCTest

@testable import CalopodMac

/// Counts the observers that are registered right now.
private final class CountingCenter: NotificationCenter, @unchecked Sendable {
    private(set) var live = Set<ObjectIdentifier>()
    private(set) var adds = 0

    override func addObserver(
        forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        let token = super.addObserver(forName: name, object: obj, queue: queue, using: block)
        live.insert(ObjectIdentifier(token as AnyObject))
        adds += 1
        return token
    }

    override func addObserver(_ observer: Any, selector: Selector, name: NSNotification.Name?, object: Any?) {
        super.addObserver(observer, selector: selector, name: name, object: object)
        live.insert(ObjectIdentifier(observer as AnyObject))
        adds += 1
    }

    override func removeObserver(_ observer: Any) {
        super.removeObserver(observer)
        live.remove(ObjectIdentifier(observer as AnyObject))
    }

    var count: Int { live.count }
}

/// Drives the window setup code against a window that is never shown, closing and reopening it
/// many times, and checks that observers do not pile up.
@MainActor
final class WindowObserverBalanceTests: XCTestCase {
    private let cycles = 50

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Lets the queued main-thread blocks (attach, apply, coalesced passes) run.
    private func drain() async { try? await Task.sleep(for: .milliseconds(30)) }

    private func post(_ names: [Notification.Name], on center: NotificationCenter, window: NSWindow) {
        names.forEach { center.post(name: $0, object: window) }
    }

    func testWindowChromeDoesNotAccumulateObserversAcrossCloseAndReopen() async {
        let center = CountingCenter()
        let window = makeWindow()
        let coordinator = WindowChrome.Coordinator(center: center)
        let view = WindowChrome.WindowObserver()
        coordinator.attach(to: view)
        window.contentView = view
        await drain()
        let single = center.count
        XCTAssertGreaterThan(single, 0, "the coordinator should be observing the window")

        for cycle in 1...cycles {
            post([NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                  NSWindow.didChangeOcclusionStateNotification], on: center, window: window)
            await drain()
            XCTAssertLessThanOrEqual(center.count, single, "cycle \(cycle) while open")

            post([NSWindow.willCloseNotification], on: center, window: window)
            // Only the watchers that bring the same window back stay registered.
            let afterClose = center.count
            XCTAssertLessThan(afterClose, single, "cycle \(cycle) after close")

            // Opening the window again: it becomes key and visible.
            post([NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification],
                 on: center, window: window)
            await drain()
            XCTAssertEqual(center.count, single, "cycle \(cycle) after reopen")
        }

        window.contentView = NSView()
        await drain()
        XCTAssertEqual(center.count, 0, "everything is removed once the view leaves the window")
    }

    func testWindowChromeAttachAfterTeardownEachCycle() async {
        let center = CountingCenter()
        let window = makeWindow()
        let coordinator = WindowChrome.Coordinator(center: center)
        var single = 0
        for cycle in 1...cycles {
            let view = WindowChrome.WindowObserver()
            coordinator.attach(to: view)
            window.contentView = view
            await drain()
            if cycle == 1 { single = center.count }
            XCTAssertEqual(center.count, single, "cycle \(cycle) attached")
            post([NSWindow.willCloseNotification], on: center, window: window)
            window.contentView = NSView()
            await drain()
            XCTAssertEqual(center.count, 0, "cycle \(cycle) torn down")
        }
        XCTAssertGreaterThan(single, 0)
    }

    func testDockPresenceObserverIsRemovedOnClose() {
        let center = CountingCenter()
        let window = makeWindow()
        var entered = 0, left = 0
        for cycle in 1...cycles {
            let tracker = DockPresenceObserver.Tracker()
            tracker.center = center
            tracker.enter = { entered += 1 }
            tracker.leave = { left += 1 }
            window.contentView = tracker
            XCTAssertEqual(center.count, 1, "cycle \(cycle) open")
            center.post(name: NSWindow.willCloseNotification, object: window)
            XCTAssertEqual(center.count, 0, "cycle \(cycle) closed")
            window.contentView = NSView()
        }
        XCTAssertEqual(entered, cycles)
        XCTAssertEqual(left, cycles)
    }

    func testDockPresenceObserverIsRemovedWhenViewLeavesWithoutClose() {
        let center = CountingCenter()
        let window = makeWindow()
        for _ in 1...cycles {
            let tracker = DockPresenceObserver.Tracker()
            tracker.center = center
            tracker.enter = {}
            tracker.leave = {}
            window.contentView = tracker
            window.contentView = NSView()
            XCTAssertEqual(center.count, 0)
        }
    }

    func testWindowSizeReaderKeepsOneObserverPerWindow() async {
        let center = CountingCenter()
        let window = makeWindow()
        for cycle in 1...cycles {
            let probe = WindowSizeReader.Probe(onChange: { _ in }, center: center)
            window.contentView = probe
            XCTAssertEqual(center.count, 1, "cycle \(cycle) open")
            center.post(name: NSWindow.didResizeNotification, object: window)
            window.contentView = NSView()
            XCTAssertEqual(center.count, 0, "cycle \(cycle) closed")
        }
    }
}
