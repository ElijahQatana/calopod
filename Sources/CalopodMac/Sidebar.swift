import AppKit
import SwiftUI

/// Floating sidebar. Full width with labels, or a narrow icon rail.
struct Sidebar: View {
    static let width: CGFloat = 226
    static let railWidth: CGFloat = 76
    static let inset: CGFloat = 10

    let navigation: AppNavigation
    let state: SidebarState
    let service: ServiceModel
    let inboxCount: Int

    @State private var query = ""

    private var rail: Bool { state.isCollapsed }

    var body: some View {
        VStack(alignment: rail ? .center : .leading, spacing: 12) {
            topRow
            brand
            if !rail { searchField }
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
            SquidBadge(size: rail ? 40 : 32)
            if !rail { Text("Calopod").font(Theme.title(.title3)).foregroundStyle(Theme.sidebarLabel) }
        }
        .padding(.horizontal, rail ? 0 : 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calopod")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query).textFieldStyle(.plain)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(.quaternary))
        .accessibilityLabel("Search sidebar")
    }

    private var nav: some View {
        VStack(alignment: rail ? .center : .leading, spacing: 3) {
            ForEach(visible(Screen.main)) { row($0) }
            let setup = visible(Screen.setup)
            if !setup.isEmpty {
                if rail {
                    Divider().frame(width: 28).padding(.vertical, 6)
                } else {
                    Text("Setup")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.sidebarSecondary)
                        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 3)
                }
                ForEach(setup) { row($0) }
            }
        }
    }

    private func visible(_ screens: [Screen]) -> [Screen] {
        let term = query.trimmingCharacters(in: .whitespaces)
        return term.isEmpty ? screens : screens.filter { $0.title.localizedCaseInsensitiveContains(term) }
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
                    .font(rail ? .system(size: 22) : nil)
                    .frame(width: rail ? 28 : 20)
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
            .font(.callout.weight(selected ? .semibold : .medium))
            .foregroundStyle(selected ? Theme.onAccent : Theme.sidebarLabel)
            .padding(.horizontal, rail ? 0 : 12)
            .frame(width: rail ? 44 : nil, height: rail ? 44 : 34)
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
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(selected ? Theme.onAccent : Theme.accent)
            .padding(.horizontal, 7)
            .background(Capsule().fill(selected ? Theme.onAccent.opacity(0.2) : Theme.accent.opacity(0.14)))
    }

    private func dot(selected: Bool) -> some View {
        Circle().fill(selected ? Theme.onAccent : Theme.bad).frame(width: 9, height: 9)
            .overlay(Circle().stroke(selected ? Theme.accent : Theme.pane, lineWidth: 2))
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: rail ? 10 : 8, height: rail ? 10 : 8)
            if !rail { Text(statusText).font(.callout.weight(.medium)).foregroundStyle(Theme.sidebarSecondary) }
            if !rail { Spacer(minLength: 0) }
        }
        .padding(.horizontal, rail ? 0 : 10)
        .padding(.vertical, 6)
        .help(statusText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sync status: \(statusText)")
    }

    private var statusColor: Color {
        switch service.status?.state {
        case "ok": Theme.good
        case "paused", "disabled": Theme.caution
        case "failed", "stopped": Theme.bad
        default: .secondary
        }
    }

    private var statusText: String {
        switch service.status?.state {
        case "ok": "Syncing"
        case "paused": "Paused"
        case "disabled": "Sync off"
        case "failed": "Needs attention"
        case "stopped": "Stopped"
        case "not-installed": "Not set up"
        default: "Checking…"
        }
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
                if reduceTransparency {
                    shape.fill(Theme.pane)
                } else if activeState == .inactive {
                    shape.fill(Theme.sidebarInactive)
                } else {
                    shape.fill(
                        LinearGradient(
                            colors: [Theme.glassSheen, Theme.glassFill],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .panelChrome(shape)
    }
}

/// Lets the window draw under its title bar and moves the window controls
/// into the floating sidebar.
struct WindowChrome: NSViewRepresentable {
    let collapsed: Bool

    private static let barHeight: CGFloat = 52

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowObserver()
        view.onWindow = { [weak coordinator = context.coordinator] in coordinator?.apply() }
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.apply() }
    }

    final class WindowObserver: NSView {
        var onWindow: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { DispatchQueue.main.async { [weak self] in self?.onWindow?() } }
        }
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        private var observers: [NSObjectProtocol] = []

        func apply() {
            guard let window = view?.window else { return }
            // Let the blurred desktop show through the window.
            window.isOpaque = false
            window.backgroundColor = .clear
            if observers.isEmpty {
                observe(window)
                // Keep the search field from grabbing focus at launch.
                window.makeFirstResponder(nil)
            }
            guard let close = window.standardWindowButton(.closeButton),
                let titlebar = close.superview,
                let container = titlebar.superview
            else { return }
            let height = WindowChrome.barHeight
            let barFrame = NSRect(
                x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
            if container.frame != barFrame { container.frame = barFrame }
            if titlebar.frame != container.bounds { titlebar.frame = container.bounds }

            // Same spot in both states: centered in the rail, which also fits the full panel.
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            let step = (buttons.dropFirst().first?.frame.minX ?? 34) - close.frame.minX
            let span = step * 2 + close.frame.width
            let left = Sidebar.inset + (Sidebar.railWidth - span) / 2
            let top = Sidebar.inset + 10 + 16
            for (index, button) in buttons.enumerated() {
                let origin = NSPoint(
                    x: left + step * CGFloat(index), y: height - top - button.frame.height / 2)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }

        private func observe(_ window: NSWindow) {
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                // AppKit lays the title bar out again on its own; put the buttons back.
                NSWindow.didUpdateNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
            }
        }

    }
}
