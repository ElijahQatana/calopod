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
        .modifier(WindowBackdrop())
        .background { WindowBlurHelper() }
        .background { WindowChrome() }
        .navigationTitle(navigation.selection.title)
        .frame(minWidth: 860, minHeight: 580)
        .tint(Theme.accent)
        .appTypography()
    }

    private var detail: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return screen
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.sidebarCollapsed, sidebar.isCollapsed)
            .safeAreaInset(edge: .top, spacing: 0) {
                if sidebar.isCollapsed && !inlineHeader {
                    toggleRow.transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if sidebar.isCollapsed && inlineHeader {
                    toggleRow.transition(.opacity)
                }
            }
            .panelFill(.card, in: shape)
            .clipShape(shape)
            .panelChrome(shape)
            .padding(.leading, Sidebar.inset)
    }

    /// Calendar and Inbox put their title on the collapse button's row.
    private var inlineHeader: Bool { navigation.selection == .calendar || navigation.selection == .inbox }

    private var toggleRow: some View {
        HStack { SidebarToggle(state: sidebar); Spacer() }
            .padding(.leading, Theme.Page.toggleLeading).padding(.trailing, Theme.Page.toggleLeading)
            .padding(.top, Theme.Page.toggleTop)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var screen: some View {
        switch navigation.selection {
        case .overview: OverviewScreen(model: service, navigation: navigation, setup: setup)
        case .calendar: CalendarScreen(openInbox: { navigation.openInbox(.changed) })
        case .inbox: InboxScreen(model: inbox, navigation: navigation, colors: .shared)
        case .calendars: CalendarsScreen(model: setup)
        case .arms: ArmsScreen(model: setup)
        case .service: ServiceScreen(model: service)
        case .settings: SettingsScreen()
        }
    }
}
