import AppKit
import SwiftUI

/// Floating sidebar. Full width with labels, or a narrow icon rail.
struct Sidebar: View {
    static let width: CGFloat = 240
    static let railWidth: CGFloat = 76
    static let inset: CGFloat = 10

    let navigation: AppNavigation
    let state: SidebarState
    let service: ServiceModel
    let inboxCount: Int

    private var rail: Bool { state.isCollapsed }

    var body: some View {
        VStack(alignment: rail ? .center : .leading, spacing: 12) {
            topRow
            brand
            nav
            Spacer(minLength: 0)
            status
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(width: rail ? Self.railWidth : Self.width)
        .frame(maxHeight: .infinity)
        .modifier(GlassPanel())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    // MARK: Pieces

    private var topRow: some View {
        HStack {
            // Room for the window controls, which sit over this row.
            Spacer(minLength: 0)
            if !rail { SidebarToggle(state: state) }
        }
        .frame(height: 32)
    }

    private var brand: some View {
        HStack(spacing: 9) {
            SquidBadge(size: rail ? 40 : 38)
            if !rail {
                Text("Calopod").font(Theme.Fonts.heading)
                    .foregroundStyle(Theme.sidebarLabel)
            }
        }
        .padding(.horizontal, rail ? 0 : 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calopod")
    }

    /// Scrolls instead of clipping when the window is too short for the full list.
    @ViewBuilder
    private var nav: some View {
        if rail {
            navItems
        } else {
            ViewThatFits(in: .vertical) {
                navItems
                ScrollView(.vertical, showsIndicators: false) { navItems }
            }
        }
    }

    private var navItems: some View {
        VStack(alignment: rail ? .center : .leading, spacing: rail ? 3 : 4) {
            ForEach(Screen.main) { row($0) }
            if rail {
                Divider().frame(width: 28).padding(.vertical, 6)
            } else {
                Text("Setup")
                    .font(Theme.Fonts.tinySemibold)
                    .foregroundStyle(Theme.sidebarSecondary)
                    .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
            }
            ForEach(Screen.setup) { row($0) }
        }
    }

    /// A capsule in the full sidebar, a rounded square sized to the icon in the rail.
    private var rowShape: AnyShape {
        rail ? AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous)) : AnyShape(Capsule())
    }

    private func row(_ screen: Screen) -> some View {
        let selected = navigation.selection == screen
        let count = screen == .inbox ? inboxCount : 0
        return Button { navigation.selection = screen } label: {
            HStack(spacing: 10) {
                Image(systemName: screen.symbol)
                    .font(rail ? Theme.Fonts.railIcon : Theme.Fonts.icon)
                    .frame(width: rail ? 28 : 24)
                    .foregroundStyle(selected ? Theme.onAccent : Theme.sidebarSecondary)
                    .overlay(alignment: .topTrailing) {
                        if rail && count > 0 { dot(selected: selected).offset(x: 5, y: -3) }
                    }
                if !rail {
                    Text(screen.title)
                    Spacer(minLength: 0)
                    if count > 0 { countBadge(count, selected: selected) }
                }
            }
            .font(Theme.Fonts.bodySemibold)
            .foregroundStyle(selected ? Theme.onAccent : Theme.sidebarLabel)
            .padding(.horizontal, rail ? 0 : 14)
            .frame(width: rail ? 44 : nil, height: 44)
            .frame(maxWidth: rail ? nil : .infinity, alignment: .leading)
            .background(rowShape.fill(selected ? Theme.accent : .clear))
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .help(screen.title)
        .accessibilityLabel(count > 0 ? "\(screen.title), \(count) need attention" : screen.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func countBadge(_ count: Int, selected: Bool) -> some View {
        Text("\(count)")
            .font(Theme.Fonts.tinySemibold.monospacedDigit())
            .foregroundStyle(selected ? Theme.onAccent : Theme.accent)
            .padding(.horizontal, 9).padding(.vertical, 2)
            .background(Capsule().fill(selected ? Theme.onAccent.opacity(0.2) : Theme.accent.opacity(0.14)))
    }

    private func dot(selected: Bool) -> some View {
        Circle().fill(selected ? Theme.onAccent : Theme.bad).frame(width: 9, height: 9)
            .overlay(Circle().stroke(selected ? Theme.accent : Theme.pane, lineWidth: 2))
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(service.syncHealth.color).frame(width: rail ? 10 : 8, height: rail ? 10 : 8)
            if !rail { Text(service.syncHealth.label).font(Theme.Fonts.bodyMedium).foregroundStyle(Theme.sidebarSecondary) }
            if !rail { Spacer(minLength: 0) }
        }
        .padding(.horizontal, rail ? 0 : 10)
        .padding(.vertical, 6)
        .help(service.syncHealth.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sync status: \(service.syncHealth.label)")
    }
}

/// Round button that collapses or expands the sidebar.
struct SidebarToggle: View {
    let state: SidebarState

    var body: some View {
        Button { state.toggle() } label: {
            Label(state.isCollapsed ? "Show sidebar" : "Hide sidebar", systemImage: "sidebar.left")
        }
        .buttonStyle(.circleToolbar)
        .help(state.isCollapsed ? "Show sidebar" : "Hide sidebar")
    }
}

/// The app mark on an accent tile, like the app icon.
private struct SquidBadge: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Theme.accent)
            .frame(width: size, height: size)
            .overlay {
                Image(nsImage: SquidMark.menuBarImage(height: size * 0.625))
                    .renderingMode(.template)
                    .foregroundStyle(Theme.onAccent)
            }
    }
}

/// A flat tinted panel over the window blur. The window has the only live blur, so
/// scrolling the page next to it does not re-blur the sidebar.
private struct GlassPanel: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content
            .background {
                if AppSettings.shared.isSolid(reduceTransparency: reduceTransparency) {
                    shape.fill(Theme.pane)
                } else if activeState == .inactive {
                    shape.fill(Theme.sidebarInactive)
                } else {
                    shape.fill(
                        LinearGradient(
                            colors: [Theme.sidebarSheen, Theme.sidebarFill],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .panelChrome(shape)
    }
}

/// Lets the window draw under its title bar and moves the window controls
/// into the floating sidebar.
struct WindowChrome: NSViewRepresentable {
    private static let barHeight: CGFloat = 52

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowObserver()
        view.onWindow = { [weak coordinator = context.coordinator] in coordinator?.request() }
        view.onRemoved = { [weak coordinator = context.coordinator] in coordinator?.stopObserving() }
        context.coordinator.view = view
        return view
    }

    // The buttons sit in the same spot in both sidebar states, so there is nothing to redo here.
    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class WindowObserver: NSView {
        var onWindow: (() -> Void)?
        var onRemoved: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                DispatchQueue.main.async { [weak self] in self?.onWindow?() }
            } else {
                onRemoved?()
            }
        }
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        private var observers: [NSObjectProtocol] = []
        /// Set when the window closes. A closed window is left alone, and nothing is observed again.
        private var closed = false
        private var clearedFocus = false
        private var metrics: TrafficLightPlacement.Metrics?
        private lazy var pass = ApplyCoalescer { [weak self] in self?.apply() }

        /// Frame changes made by apply() itself land here too, so asking never runs it inline.
        func request() { pass.request() }

        private func apply() {
            guard !closed, let window = view?.window else { return }
            // Let the blurred desktop show through the window.
            if window.isOpaque { window.isOpaque = false }
            if window.backgroundColor != .clear { window.backgroundColor = .clear }
            guard let close = window.standardWindowButton(.closeButton),
                let titlebar = close.superview,
                let container = titlebar.superview
            else { return }
            if observers.isEmpty {
                observe(window, watching: [container, titlebar] + [.miniaturizeButton, .zoomButton, .closeButton]
                    .compactMap { window.standardWindowButton($0) })
                // Keep the search field from grabbing focus at launch.
                if !clearedFocus {
                    clearedFocus = true
                    window.makeFirstResponder(nil)
                }
            }
            // Measure the AppKit spacing once. Later passes can see buttons AppKit has just reset,
            // so reading it again would give a different position at different sizes.
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            if metrics == nil, buttons.count == 3 {
                metrics = TrafficLightPlacement.Metrics(
                    step: buttons[1].frame.minX - close.frame.minX,
                    size: close.frame.size)
            }
            let metrics = metrics ?? .init(step: 34, size: close.frame.size)

            // The title bar container lives in the window's frame view. Use that view's own height,
            // not window.frame, which can differ from it while a live resize is in flight.
            let parentHeight = container.superview?.bounds.height ?? window.frame.height
            let parentWidth = container.superview?.bounds.width ?? window.frame.width
            let height = WindowChrome.barHeight
            let barFrame = NSRect(x: 0, y: parentHeight - height, width: parentWidth, height: height)
            if !container.frame.isClose(to: barFrame) { container.frame = barFrame }
            if !titlebar.frame.isClose(to: container.bounds) { titlebar.frame = container.bounds }

            let origins = TrafficLightPlacement.origins(barHeight: height, metrics: metrics)
            for (button, origin) in zip(buttons, origins) {
                if !NSRect(origin: button.frame.origin, size: .zero).isClose(to: NSRect(origin: origin, size: .zero)) {
                    button.setFrameOrigin(origin)
                }
            }
        }

        private func observe(_ window: NSWindow, watching views: [NSView]) {
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                NSWindow.didBecomeKeyNotification,
            ]
            var tokens = names.map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.request() }
                }
            }
            // AppKit lays the title bar out again on its own. Watching the frames of the bar and
            // buttons catches that without running on every window update.
            for view in views {
                view.postsFrameChangedNotifications = true
                tokens.append(center.addObserver(
                    forName: NSView.frameDidChangeNotification, object: view, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.request() }
                })
            }
            // Without this the observers stay registered after the window is closed, and each reopened
            // window would add another set.
            tokens.append(center.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.closed = true
                    self?.stopObserving()
                }
            })
            observers = tokens
        }

        /// Drops the window observers. Called when the window closes, when the view leaves its
        /// window and when the representable is torn down. A new window starts observing again.
        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }
}

/// Where the window buttons go inside the title bar container. The container's origin is the
/// bottom left of the bar, so the result depends only on the bar height and the button metrics,
/// never on the window size.
@MainActor
enum TrafficLightPlacement {
    struct Metrics: Equatable {
        var step: CGFloat
        var size: CGSize
    }

    static func origins(barHeight: CGFloat, metrics: Metrics) -> [NSPoint] {
        let span = metrics.step * 2 + metrics.size.width
        let left = Sidebar.inset + (Sidebar.railWidth - span) / 2
        let top = Sidebar.inset + 10 + 16
        return (0..<3).map {
            NSPoint(x: left + metrics.step * CGFloat($0), y: barHeight - top - metrics.size.height / 2)
        }
    }
}

/// Runs an action once on the next main turn however many requests arrive, and ignores
/// requests made while it runs, so work that triggers its own notifications cannot loop.
@MainActor
final class ApplyCoalescer {
    private let action: () -> Void
    private var pending = false
    private var running = false

    init(_ action: @escaping () -> Void) { self.action = action }

    func request() {
        guard !pending, !running else { return }
        pending = true
        DispatchQueue.main.async { [self] in
            pending = false
            running = true
            defer { running = false }
            action()
        }
    }
}

extension NSRect {
    /// Equal within half a point, so rounding by AppKit does not count as a change.
    func isClose(to other: NSRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
