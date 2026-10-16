import CalopodCommands
import CalopodDomain
import SwiftUI

/// The Main calendar and Arms: which calendars flow into which, and how much detail they show.
struct ArmsScreen: View {
    let model: SetupModel

    @State private var mainSources = Set<String>()
    @State private var mainTarget: String?
    @State private var armSources = Set<String>()
    @State private var armTarget: String?
    @State private var armRule: ArmRuleMode = .busy
    @State private var armName = ""
    @State private var pendingRemoval: String?

    var body: some View {
        ScreenScaffold {
            ScreenHeader(
                title: "Arms",
                subtitle: "Choose where your events are copied. Nothing changes until a sync runs."
            )
            BusyLine(text: model.busy)
            if let notice = model.notice { Banner(kind: .error, text: notice) }

            mainCard
            ForEach((model.snapshot?.arms ?? []).filter { !$0.isMain }) { armCard($0) }
            newArmCard
        }
        .task { await model.reload() }
    }

    // MARK: Main calendar

    @ViewBuilder
    private var mainCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Main calendar")
                if let main = model.snapshot?.arms.first(where: \.isMain) {
                    route(main)
                    Text("Shows every event in full detail.").font(.callout).foregroundStyle(.secondary)
                    removeControl(main.id, title: "Remove Main calendar")
                } else {
                    Text("One calendar that shows everything you do, in full detail.")
                        .font(.callout).foregroundStyle(.secondary)
                    picker(sources: $mainSources, target: $mainTarget)
                    Button("Set as Main calendar") {
                        guard let target = mainTarget else { return }
                        Task {
                            await model.configureMain(sources: Array(mainSources), target: target)
                            mainSources = []
                            mainTarget = nil
                        }
                    }
                    .buttonStyle(.accentFilled)
                    .disabled(model.isBusy || mainSources.isEmpty || mainTarget == nil)
                }
            }
        }
    }

    // MARK: Arms

    private func armCard(_ arm: SetupArm) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(arm.name).font(.headline)
                    Spacer()
                    Toggle("Enabled", isOn: Binding(
                        get: { arm.isEnabled },
                        set: { value in Task { await model.setArmEnabled(arm.id, value) } }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                route(arm)
                Picker("Shows", selection: Binding(
                    get: { arm.rule },
                    set: { value in Task { await model.setRule(arm.id, value) } }
                )) {
                    Text("Busy only").tag(ArmRuleMode.busy)
                    Text("Full details").tag(ArmRuleMode.fullDetails)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                removeControl(arm.id, title: "Remove")
            }
            .disabled(model.isBusy)
        }
    }

    private var newArmCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("New arm")
                picker(sources: $armSources, target: $armTarget)
                Picker("Shows", selection: $armRule) {
                    Text("Busy only").tag(ArmRuleMode.busy)
                    Text("Full details").tag(ArmRuleMode.fullDetails)
                }
                .pickerStyle(.segmented)
                TextField("Name (optional)", text: $armName)
                    .textFieldStyle(.roundedBorder)
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
                .buttonStyle(.accentFilled)
                .disabled(model.isBusy || armSources.isEmpty || armTarget == nil)
            }
        }
    }

    // MARK: Pieces

    private func route(_ arm: SetupArm) -> some View {
        HStack(spacing: 8) {
            Text(arm.sourceNames.joined(separator: ", ")).lineLimit(2)
            Image(systemName: "arrow.right").foregroundStyle(Theme.accent)
            Text(arm.targetName).fontWeight(.medium)
        }
        .font(.callout)
    }

    private func removeControl(_ armID: String, title: String) -> some View {
        Group {
            if pendingRemoval == armID {
                HStack {
                    Text("Remove? Events already copied stay where they are.").font(.callout)
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

    private func picker(sources: Binding<Set<String>>, target: Binding<String?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.selectedCalendars.isEmpty {
                Banner(kind: .info, text: "Choose at least one calendar on the Calendars screen first.")
            }
            Text("From").font(.subheadline.weight(.semibold))
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
