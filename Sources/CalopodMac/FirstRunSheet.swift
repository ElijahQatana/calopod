import CalopodCommands
import CalopodDomain
import SwiftUI

/// Three steps from nothing connected to a first reviewed sync. Skipping keeps the place.
struct FirstRunSheet: View {
    let progress: FirstRunProgress
    let setup: SetupModel
    let service: ServiceModel
    let navigation: AppNavigation

    @Environment(\.dismiss) private var dismiss
    @State private var fullTarget: String?
    @State private var busyTarget: String?
    @State private var targetsConfirmed = false
    @State private var previewed = false
    private let colors = CalendarColors.shared

    private var sourceIDs: [String] { setup.selectedCalendars.map(\.id) }
    private var connectionCount: Int { setup.snapshot?.connections.count ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let busy = setup.busy ?? service.busyAction { BusyLine(text: busy) }
                    if let notice = setup.notice ?? service.notice { Banner(kind: .error, text: notice) }
                    switch progress.step {
                    case .connect: connect
                    case .calendars: calendars
                    case .destinations: destinations
                    }
                }
                .padding(Theme.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 560)
        .background(Theme.pane)
        .task {
            progress.begin()
            await setup.reload()
        }
        .onChange(of: setup.snapshot) { _, snapshot in
            colors.assignMissing(
                to: (snapshot?.connections ?? []).flatMap { connection in
                    connection.calendars.map {
                        CalendarColorSource(id: $0.id, providerColor: $0.providerColor, provider: connection.provider)
                    }
                },
                ignoring: setup.aliases.ignored)
        }
    }

    // MARK: Frame

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(FirstRunProgress.Step.allCases, id: \.self) { step in
                    Capsule()
                        .fill(step.rawValue <= progress.step.rawValue ? Theme.accent : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            Text("Step \(progress.step.rawValue + 1) of 3").font(.caption).foregroundStyle(.secondary)
            Text(progress.step.title).font(Theme.title(.title))
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Button("Skip for now") { dismiss() }
            Spacer()
            if !progress.isFirst && !progress.isFinished {
                Button("Back") { progress.back() }.disabled(isWorking)
            }
            if progress.isFinished {
                Button("Done") { dismiss() }.buttonStyle(.accentFilled)
            } else if !progress.isLast {
                Button("Continue") { progress.next() }
                    .buttonStyle(.accentFilled)
                    .disabled(!progress.canContinue(connections: connectionCount, selectedCalendars: sourceIDs.count))
            } else if service.pendingPreview != nil {
                Button("Discard preview") { service.discardPreview() }.disabled(isWorking)
                Button("Approve and sync") { Task { await approve() } }
                    .buttonStyle(.accentFilled).disabled(isWorking)
            } else if previewed && service.notice == nil {
                Button("Finish") { progress.approvePreview() }.buttonStyle(.accentFilled)
            } else {
                Button("Save and preview") { Task { await saveAndPreview() } }
                    .buttonStyle(.accentFilled).disabled(!canSave || isWorking)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 14)
    }

    private var isWorking: Bool { setup.isBusy || service.isBusy }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }

    // MARK: 1 Connect

    @ViewBuilder
    private var connect: some View {
        Text("Where do your calendars live? Add as many accounts as you like.")
        HStack(spacing: 10) {
            providerButton("This Mac", "laptopcomputer", .mac)
            providerButton("Google", "g.circle", .google)
            providerButton("Microsoft", "m.circle", .microsoft)
        }
        ForEach(setup.snapshot?.connections ?? []) { connection in
            Label {
                Text(connection.label)
                Text("\(connection.calendars.count) calendars").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
            }
        }
        card {
            Label("Calopod never edits or deletes events it did not create.", systemImage: "hand.raised")
            Label("Sign-in tokens stay in the Keychain on this Mac.", systemImage: "key")
        }
        .font(.callout)
    }

    private func providerButton(_ title: String, _ symbol: String, _ provider: SetupProvider) -> some View {
        Button {
            Task { await setup.connect(provider) }
        } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(isWorking)
    }

    // MARK: 2 Calendars and colors

    @ViewBuilder
    private var calendars: some View {
        Text("Choose the calendars Calopod should read. Each gets a color, which only shows here.")
        ForEach(setup.snapshot?.connections ?? []) { connection in
            card {
                Label(connection.label, systemImage: "calendar").font(.headline)
                ForEach(connection.warnings, id: \.self) { Banner(kind: .caution, text: $0) }
                // Ignored calendars are left out unless they are already chosen, so nothing chosen is hidden.
                ForEach(connection.calendars.filter { !setup.aliases.isIgnored($0.id) || $0.isSelected }) { calendar in
                    Toggle(
                        isOn: Binding(
                            get: { calendar.isSelected },
                            set: { value in Task { await setup.setSelected(calendar.id, value) } }
                        )
                    ) {
                        HStack(spacing: 8) {
                            CalendarColorDot(calendarID: calendar.id, colors: colors)
                            Text(setup.aliases.name(for: calendar))
                            if calendar.isReadOnly {
                                Text("read-only").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isWorking)
                }
            }
        }
        Hint {
            Text("Some calendars, such as subscribed or shared ones, can be read here but not changed. Replies to invitations on them can only be sent from the Calendar app.")
        }
    }

    // MARK: 3 Where events go

    @ViewBuilder
    private var destinations: some View {
        if progress.isFinished {
            finished
        } else {
            Text("Your \(sourceIDs.count) chosen calendars are copied into two others. Each target should be a fresh, empty calendar that only Calopod uses.")
            route(
                "Full details", "Everything, with titles, locations and notes.",
                existing: setup.fullDetailsArm, target: $fullTarget, other: busyTarget)
            route(
                "Busy only", "Only the time, shown as Busy.",
                existing: setup.busyArm, target: $busyTarget, other: fullTarget)
            if setup.fullDetailsArm == nil || setup.busyArm == nil {
                Toggle("These targets are fresh and empty, and only Calopod will use them.", isOn: $targetsConfirmed)
                    .font(.callout)
            }
            if let preview = service.pendingPreview {
                previewCard(preview)
            } else if previewed && service.notice == nil {
                Banner(kind: .info, text: "Nothing to change right now. Finish to complete setup.")
            } else {
                Hint { Text("Nothing is copied yet. Saving only records these choices, then shows what a sync would do.") }
            }
        }
    }

    private func route(
        _ title: String, _ detail: String, existing: SetupArm?, target: Binding<String?>, other: String?
    ) -> some View {
        card {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
            if let existing {
                LabeledContent("Copies into") { Text(setup.targetName(of: existing)).fontWeight(.medium) }
            } else {
                Picker("Copies into", selection: target) {
                    Text("Choose a calendar").tag(String?.none)
                    ForEach(setup.targetCandidates.filter { $0.id != other }, id: \.id) {
                        Text($0.title).tag(String?.some($0.id))
                    }
                }
            }
        }
    }

    private func previewCard(_ preview: SyncPreview) -> some View {
        card {
            Text("Review before syncing").font(.headline)
            Text("\(preview.creates) to create, \(preview.updates) to update, \(preview.removals) to remove, \(preview.repairs) to repair")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(preview.lines.prefix(6)) { line in
                LabeledContent {
                    Text(line.reason).foregroundStyle(.secondary)
                } label: {
                    Text("\(line.action.capitalized) · \(line.armName)")
                }
                .font(.callout)
            }
            if preview.lines.count > 6 {
                Text("and \(preview.lines.count - 6) more").font(.callout).foregroundStyle(.secondary)
            }
            if preview.removals > 0 {
                Banner(kind: .caution, text: "Includes removing copies Calopod made earlier.")
            }
            ForEach(preview.warnings, id: \.self) { Banner(kind: .caution, text: $0) }
        }
    }

    private var finished: some View {
        card {
            Label("Setup is done", systemImage: "checkmark.circle.fill").font(.headline)
                .foregroundStyle(Theme.good, .primary)
            Text("Background sync is still off. Turn it on when you are happy with the first sync.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open background sync") {
                navigation.selection = .service
                dismiss()
            }
        }
    }

    // MARK: Actions on step 3

    private var canSave: Bool {
        let fullReady = setup.fullDetailsArm != nil || fullTarget != nil
        let busyReady = setup.busyArm != nil || busyTarget != nil
        let needsConfirm = setup.fullDetailsArm == nil || setup.busyArm == nil
        return fullReady && busyReady && (!needsConfirm || targetsConfirmed)
    }

    /// Records the two arms, then asks for the usual dry run. No calendar is written.
    private func saveAndPreview() async {
        await setup.setUpTwoArms(
            sources: sourceIDs,
            fullDetailsTarget: setup.fullDetailsArm == nil ? fullTarget : nil,
            busyTarget: setup.busyArm == nil ? busyTarget : nil)
        guard setup.notice == nil else { return }
        await service.previewSync()
        previewed = true
    }

    private func approve() async {
        if service.pendingPreview != nil { await service.applyPreview() }
        if service.notice == nil { progress.approvePreview() }
    }
}
