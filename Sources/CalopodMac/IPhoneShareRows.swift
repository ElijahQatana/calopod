import AppKit
import CalopodSnapshot
import SwiftUI

extension SnapshotLevel {
    var title: String {
        switch self {
        case .full: "Everything in the feed"
        case .busy: "Free and busy time only"
        }
    }

    var reads: String {
        switch self {
        case .full:
            "They can read your Inbox items (titles, times, places, notes, organizers and meeting links), the events and calendar names you send to the iPhone, your reminder settings and this Mac's name. They can't change anything."
        case .busy:
            "They can read when you are busy for the next two weeks, when this Mac last synced and this Mac's name. No titles, places, notes, links or calendar names. They can't change anything."
        }
    }
}

struct IPhoneShareRows: View {
    let feed: IPhoneFeedModel
    @State private var inviting = false

    var body: some View {
        CardRow {
            Text("People with a different Apple ID can read a copy of the feed on their iPhone. You choose who, and what they can read.")
                .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
        }
        ForEach(feed.people) { shared in
            CardRow {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shared.person.name).lineLimit(1)
                        Text("\(shared.level.title), \(shared.person.status == .accepted ? "accepted" : "invited")")
                            .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { Task { await feed.remove(shared) } }.disabled(feed.isBusy)
                }
            }
        }
        if let problem = feed.shareProblem {
            CardRow { Banner(kind: .error, text: problem) }
        }
        CardRow {
            HStack {
                Button("Invite someone…") { inviting = true }.disabled(feed.isBusy)
                Spacer()
                ForEach([SnapshotLevel.full, .busy], id: \.self) { level in
                    if feed.people.contains(where: { $0.level == level }) {
                        Button(level == .full ? "Stop sharing everything" : "Stop sharing busy time") {
                            Task { await feed.stopSharing(level) }
                        }
                        .disabled(feed.isBusy)
                    }
                }
            }
        }
        .sheet(isPresented: $inviting) { InviteSheet(feed: feed) }
    }
}

struct InviteSheet: View {
    let feed: IPhoneFeedModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var level = SnapshotLevel.busy
    @State private var link: URL?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Invite someone").font(Theme.Fonts.heading)
            if let link { sent(link) } else { form }
        }
        .padding(Theme.pagePadding)
        .frame(width: 460)
        .background(Theme.pane)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Their Apple ID email address", text: $email).textFieldStyle(.roundedBorder)
            Picker("What they can read", selection: $level) {
                Text(SnapshotLevel.busy.title).tag(SnapshotLevel.busy)
                Text(SnapshotLevel.full.title).tag(SnapshotLevel.full)
            }
            .pickerStyle(.radioGroup)
            Text(level.reads).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem { Banner(kind: .error, text: problem) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Invite") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(feed.isBusy || email.isEmpty)
            }
        }
    }

    private func sent(_ link: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send this link to \(email). They open it on their iPhone with Calopod installed. It only works for that Apple ID.")
                .font(Theme.Fonts.body).fixedSize(horizontal: false, vertical: true)
            Text(link.absoluteString).font(Theme.Fonts.secondary).textSelection(.enabled).lineLimit(2)
            HStack {
                Spacer()
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func send() {
        problem = nil
        Task {
            do { link = try await feed.invite(email: email, level: level) } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
