import Observation

/// Where the app is: the tab, the Inbox filter a Home tile asked for, and the screens opened from the menu.
@MainActor
@Observable
final class Navigation {
    enum Tab: CaseIterable { case home, inbox, calendar, status }
    enum Page { case settings, calendars, help, about }

    var tab = Tab.home
    var inboxFilter = InboxFilter.all
    var menuOpen = false
    /// Menu screens on top of the tabs. Back removes the top one.
    private(set) var pages: [Page] = []

    var page: Page? { pages.last }

    func openInbox(_ filter: InboxFilter) {
        inboxFilter = filter
        show(.inbox)
    }

    func show(_ tab: Tab) {
        self.tab = tab
        pages = []
        menuOpen = false
    }

    /// From the menu: replaces whatever menu screen was open.
    func open(_ page: Page) {
        pages = [page]
        menuOpen = false
    }

    /// From a menu screen, so Back returns to it.
    func push(_ page: Page) { pages.append(page) }

    func back() { _ = pages.popLast() }
}
