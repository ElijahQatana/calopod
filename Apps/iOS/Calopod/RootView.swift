import SwiftUI

struct RootView: View {
    var store: SnapshotStore
    var now: () -> Date = { .now }

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.screen)
            case .sharingOff:
                EmptyState(
                    title: "Welcome", subtitle: "iPhone sync is off", heading: "Your Mac stays in charge",
                    message: "Calopod on your Mac can share your Inbox, calendar and sync status with this phone. Nothing appears here until you turn it on there.",
                    steps: ["Open Calopod on your Mac", "Go to Settings, then iPhone", "Turn on Share with iPhone"],
                    systemImage: "macbook.and.iphone")
            case .nothingPublished:
                EmptyState(
                    title: "Waiting", subtitle: "Nothing published yet", heading: "Nothing here yet",
                    message: "Sharing is on, but your Mac hasn't published anything. Open Calopod on your Mac and let it finish a sync.",
                    systemImage: "icloud")
            case .failed:
                EmptyState(
                    title: "Offline", subtitle: "Couldn't reach iCloud", heading: "Can't read your snapshot",
                    message: "Check that this phone is online and signed in to iCloud, then open the app again.",
                    systemImage: "icloud.slash")
            case .needsNewerApp:
                EmptyState(
                    title: "Update needed", subtitle: "Your Mac is newer", heading: "Update Calopod on this phone",
                    message: "Your Mac is publishing in a format this version doesn't understand yet.",
                    systemImage: "arrow.down.app")
            case .content(let snapshot, let offline):
                let context = SnapshotContext(snapshot: snapshot, offline: offline, now: now())
                TabView {
                    InboxTab(context: context).tabItem { Label("Inbox", systemImage: "tray") }
                    CalendarTab(context: context).tabItem { Label("Calendar", systemImage: "calendar") }
                    StatusTab(context: context).tabItem { Label("Status", systemImage: "waveform.path.ecg") }
                }
            }
        }
        .tint(Theme.accent)
        .task { await store.refresh() }
    }
}
