import AppKit
import SwiftUI

struct MainWindow: View {
    let navigation: AppNavigation
    let sidebar: SidebarState
    let service: ServiceModel
    let setup: SetupModel
    let inbox: InboxModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(
                navigation: navigation, state: sidebar, service: service,
                inboxCount: inbox.count)
            detail
        }
        .padding(Sidebar.inset)
        .ignoresSafeArea(.container, edges: .top)
        .background { GlassWindowBackground() }
        .background { WindowChrome(collapsed: sidebar.isCollapsed) }
        .navigationTitle(navigation.selection.title)
        .frame(minWidth: 860, minHeight: 580)
        .tint(Theme.accent)
    }

    private var detail: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return screen
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                if sidebar.isCollapsed {
                    HStack { SidebarToggle(state: sidebar); Spacer() }
                        .padding(.horizontal, 14).padding(.top, 12)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .panelFill(.card, in: shape)
            .clipShape(shape)
            .panelChrome(shape)
            .padding(.leading, Sidebar.inset)
    }

    @ViewBuilder
    private var screen: some View {
        switch navigation.selection {
        case .overview: OverviewScreen(model: service, navigation: navigation, setup: setup)
        case .calendar: CalendarScreen()
        case .inbox: InboxScreen(model: inbox, navigation: navigation, colors: .shared)
        case .calendars: CalendarsScreen(model: setup)
        case .arms: ArmsScreen(model: setup)
        case .service: ServiceScreen(model: service)
        }
    }
}

/// Blurs the desktop behind the window and warms it, as the mockup does.
private struct GlassWindowBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        } else {
            BehindWindowBlur().overlay(Theme.windowTint).ignoresSafeArea()
        }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
