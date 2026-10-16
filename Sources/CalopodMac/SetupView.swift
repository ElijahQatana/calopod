import CalopodCommands
import CalopodDomain
import SwiftUI

struct SetupView: View {
    let model: SetupModel

    @State private var mainSources = Set<String>()
    @State private var mainTarget: String?
    @State private var armSources = Set<String>()
    @State private var armTarget: String?
    @State private var armRule: ArmRuleMode = .busy
    @State private var armName = ""
    @State private var pendingRemoval: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let busy = model.busy {
                    HStack { ProgressView().controlSize(.small); Text(busy) }
                }
                if let notice = model.notice {
                    Text(notice).foregroundStyle(.red)
                }
                connectionsSection
                Divider()
                mainSection
                Divider()
                armsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 560)
        .task { await model.reload() }
    }

    // MARK: Connections

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Connect your calendars").font(.title3.bold())
            Text("Calopod reads the calendars you select and never changes them. Select each calendar only once, even if it is reachable two ways.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Add Calendars on this Mac") { Task { await model.connect(.mac) } }
                Button("Add Google") { Task { await model.connect(.google) } }
                Button("Add Microsoft") { Task { await model.connect(.microsoft) } }
            }
            .disabled(model.isBusy)
            ForEach(model.snapshot?.connections ?? []) { connection in
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(connection.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        ForEach(connection.calendars) { calendar in
                            Toggle(isOn: Binding(
                                get: { calendar.isSelected },
                                set: { value in Task { await model.setSelected(calendar.id, value) } }
                            )) {
                                Text(calendar.name + (calendar.isReadOnly ? " (read-only)" : ""))
                            }
                            .disabled(model.isBusy)
                        }
                        HStack {
                            Button("Refresh") { Task { await model.refresh(connection.id) } }
                            Button("Remove Connection", role: .destructive) {
                                Task { await model.disconnect(connection.id) }
                            }
                        }
                        .disabled(model.isBusy)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(connection.label).font(.headline)
                }
            }
        }
    }

    // MARK: Main calendar

    @ViewBuilder
    private var mainSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2. Main calendar").font(.title3.bold())
            if let main = model.snapshot?.arms.first(where: \.isMain) {
                Text("\(main.sourceNames.joined(separator: ", ")) → \(main.targetName)")
                Text("Shows full event details. Change it by removing it below.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Pick the calendars to combine and one writable calendar that will show them with full details.")
                    .font(.callout).foregroundStyle(.secondary)
                calendarPicker(sources: $mainSources, target: $mainTarget)
                Button("Set as Main calendar") {
                    guard let target = mainTarget else { return }
                    Task {
                        await model.configureMain(sources: Array(mainSources), target: target)
                        mainSources = []
                        mainTarget = nil
                    }
                }
                .disabled(model.isBusy || mainSources.isEmpty || mainTarget == nil)
            }
        }
    }

    // MARK: Arms

    private var armsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("3. Arms").font(.title3.bold())
            Text("An Arm copies chosen calendars into another calendar, either as Busy blocks or with full details. Creating or editing one does not change any events until a sync runs.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach((model.snapshot?.arms ?? []).filter { !$0.isMain }) { arm in
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(arm.sourceNames.joined(separator: ", ")) → \(arm.targetName)")
                            .font(.callout)
                        Picker("Shows", selection: Binding(
                            get: { arm.rule },
                            set: { value in Task { await model.setRule(arm.id, value) } }
                        )) {
                            Text("Busy only").tag(ArmRuleMode.busy)
                            Text("Full details").tag(ArmRuleMode.fullDetails)
                        }
                        .pickerStyle(.segmented)
                        Toggle("Enabled", isOn: Binding(
                            get: { arm.isEnabled },
                            set: { value in Task { await model.setArmEnabled(arm.id, value) } }
                        ))
                        removeButton(arm.id)
                    }
                    .disabled(model.isBusy)
                } label: {
                    Text(arm.name).font(.headline)
                }
            }
            if let main = model.snapshot?.arms.first(where: \.isMain) {
                removeButton(main.id, title: "Remove Main calendar")
            }
            GroupBox("New Arm") {
                VStack(alignment: .leading, spacing: 8) {
                    calendarPicker(sources: $armSources, target: $armTarget)
                    Picker("Shows", selection: $armRule) {
                        Text("Busy only").tag(ArmRuleMode.busy)
                        Text("Full details").tag(ArmRuleMode.fullDetails)
                    }
                    .pickerStyle(.segmented)
                    TextField("Name (optional)", text: $armName)
                    Button("Create Arm") {
                        guard let target = armTarget else { return }
                        let name = armName.isEmpty ? nil : armName
                        Task {
                            await model.addArm(
                                sources: Array(armSources),
                                target: target,
                                rule: armRule,
                                name: name
                            )
                            armSources = []
                            armTarget = nil
                            armName = ""
                        }
                    }
                    .disabled(model.isBusy || armSources.isEmpty || armTarget == nil)
                }
            }
        }
    }

    private func removeButton(_ armID: String, title: String = "Remove Arm") -> some View {
        Group {
            if pendingRemoval == armID {
                HStack {
                    Text("Remove? Events already copied are left in place.")
                        .font(.callout)
                    Button("Remove", role: .destructive) {
                        pendingRemoval = nil
                        Task { await model.removeArm(armID) }
                    }
                    Button("Cancel") { pendingRemoval = nil }
                }
            } else {
                Button(title, role: .destructive) { pendingRemoval = armID }
            }
        }
        .disabled(model.isBusy)
    }

    private func calendarPicker(
        sources: Binding<Set<String>>,
        target: Binding<String?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.selectedCalendars.isEmpty {
                Text("Select at least one calendar above first.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("From").font(.subheadline.bold())
            ForEach(model.selectedCalendars, id: \.id) { calendar in
                Toggle(calendar.title, isOn: Binding(
                    get: { sources.wrappedValue.contains(calendar.id) },
                    set: { value in
                        if value { sources.wrappedValue.insert(calendar.id) }
                        else { sources.wrappedValue.remove(calendar.id) }
                    }
                ))
            }
            Picker("Into", selection: target) {
                Text("Choose a calendar").tag(String?.none)
                ForEach(model.selectedCalendars.filter { !$0.isReadOnly }, id: \.id) {
                    Text($0.title).tag(String?.some($0.id))
                }
            }
        }
    }
}
