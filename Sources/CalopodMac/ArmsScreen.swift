import CalopodCommands
import CalopodDomain
import SwiftUI

struct ArmsScreen: View {
    let model: SetupModel

    @State private var armSources = Set<String>()
    @State private var armTarget: String?
    @State private var armRule: ArmRuleMode = .busy
    @State private var armName = ""
    @State private var pendingRemoval: String?

    var body: some View {
        Form {
            if let busy = model.busy { Section { BusyLine(text: busy) } }
            if let notice = model.notice { Section { Banner(kind: .error, text: notice) } }

            ForEach(model.snapshot?.arms ?? []) { armSection($0) }
            newArmSection
        }
        .formStyle(.grouped)
        .task { await model.reload() }
    }

    private static let ruleOptions: [(label: String, value: ArmRuleMode)] = [
        ("Busy only", .busy), ("Full details", .fullDetails),
    ]

    // MARK: Arms

    private func armSection(_ arm: SetupArm) -> some View {
        Section {
            route(arm)
            if arm.isMain {
                // The Main calendar always copies full details, so its rule is not a choice.
                LabeledContent("Shows") { Text("Full details") }
            } else {
                PillPicker(
                    options: Self.ruleOptions,
                    selection: Binding(
                        get: { arm.rule },
                        set: { value in Task { await model.setRule(arm.id, value) } }
                    )
                )
            }
            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { arm.isEnabled },
                    set: { value in Task { await model.setArmEnabled(arm.id, value) } }
                ))
            removeControl(arm.id, title: "Remove")
        } header: {
            Text(arm.name)
        }
        .disabled(model.isBusy)
    }

    private var newArmSection: some View {
        Section {
            picker(sources: $armSources, target: $armTarget)
            PillPicker(options: Self.ruleOptions, selection: $armRule)
            TextField("Name (optional)", text: $armName)
            Button("Create arm") {
                guard let target = armTarget else { return }
                let name = armName.isEmpty ? nil : armName
                Task {
                    await model.addArm(sources: Array(armSources), target: target, rule: armRule, name: name)
                    armSources = []
                    armTarget = nil
                    armName = ""
                }
            }
            .disabled(model.isBusy || armSources.isEmpty || armTarget == nil)
            Hint { Text("An arm copies chosen calendars into another calendar, as Busy blocks or with full details.") }
        } header: {
            Text("New arm")
        }
    }

    // MARK: Pieces

    private func route(_ arm: SetupArm) -> some View {
        LabeledContent {
            Text(arm.targetName).fontWeight(.medium)
        } label: {
            Text(arm.sourceNames.joined(separator: ", ")).lineLimit(2)
        }
    }

    private func removeControl(_ armID: String, title: String) -> some View {
        Group {
            if pendingRemoval == armID {
                HStack {
                    Text("Remove? Events already copied stay put.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { pendingRemoval = nil }
                    Button("Remove", role: .destructive) {
                        pendingRemoval = nil
                        Task { await model.removeArm(armID) }
                    }
                    .foregroundStyle(Theme.bad)
                }
            } else {
                Button(title, role: .destructive) { pendingRemoval = armID }.foregroundStyle(Theme.bad)
            }
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder
    private func picker(sources: Binding<Set<String>>, target: Binding<String?>) -> some View {
        if model.selectedCalendars.isEmpty {
            Banner(kind: .info, text: "Choose at least one calendar on the Calendars screen first.")
        }
        ForEach(model.selectedCalendars, id: \.id) { calendar in
            Toggle(
                calendar.title,
                isOn: Binding(
                    get: { sources.wrappedValue.contains(calendar.id) },
                    set: { value in
                        if value { sources.wrappedValue.insert(calendar.id) } else { sources.wrappedValue.remove(calendar.id) }
                    }
                ))
        }
        Picker("Copy into", selection: target) {
            Text("Choose a calendar").tag(String?.none)
            ForEach(model.selectedCalendars.filter { !$0.isReadOnly }, id: \.id) {
                Text($0.title).tag(String?.some($0.id))
            }
        }
    }
}
