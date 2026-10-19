import AppKit
import SwiftUI

/// How big the review sheet is for a window, and when it puts details and the day view side by side.
enum ReviewSheetLayout {
    /// The sheet is two columns from this width up, and stacked below it.
    static let sideBySideWidth: CGFloat = 760
    static let minimum = CGSize(width: 560, height: 440)
    static let maximum = CGSize(width: 980, height: 720)
    /// Room left around the sheet: a little at the sides, and the title bar the sheet hangs from.
    static let margin = CGSize(width: 40, height: 56)
    /// Used until the window has been measured.
    static let fallbackWindow = CGSize(width: 1000, height: 700)
    /// Height of the day view when the sheet is stacked.
    static let compactDayHeight: CGFloat = 140

    static func size(in window: CGSize) -> CGSize {
        CGSize(
            width: min(max(window.width - margin.width, minimum.width), maximum.width),
            height: min(max(window.height - margin.height, minimum.height), maximum.height))
    }

    static func isSideBySide(width: CGFloat) -> Bool { width >= sideBySideWidth }

    /// The right column's share of the body: about two fifths, kept readable at both ends.
    static func dayColumnWidth(body width: CGFloat) -> CGFloat { min(max(width * 0.42, 300), 400) }
}

/// Reports the size of the window the view is in, and keeps it current as the window is resized.
struct WindowSizeReader: NSViewRepresentable {
    let onChange: (CGSize) -> Void

    func makeNSView(context: Context) -> NSView { Probe(onChange: onChange) }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.onChange = onChange }

    private final class Probe: NSView {
        var onChange: (CGSize) -> Void
        init(onChange: @escaping (CGSize) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(report), name: NSWindow.didResizeNotification, object: window)
            report()
        }

        @objc private func report() {
            guard let size = window?.contentView?.bounds.size, size.width > 0 else { return }
            DispatchQueue.main.async { [weak self] in self?.onChange(size) }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
