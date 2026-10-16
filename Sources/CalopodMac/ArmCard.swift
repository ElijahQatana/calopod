import CalopodCommands
import CalopodDomain
import SwiftUI

/// One arm: its name and controls on top, then where its events come from and go.
struct ArmCard: View {
    let model: SetupModel
    let arm: SetupArm
    let colors: CalendarColors

    @State private var renaming = false
    @State private var confirmingRemoval = false

    private var ruleBinding: Binding<ArmRuleMode> {
        Binding(
            get: { arm.rule },
            set: { value in
                guard arm.canChangeRule else { return }
                Task { await model.setRule(arm.id, value) }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topRow
            flow
            if confirmingRemoval { removalConfirm }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelFill(.inner, in: armCardShape)
        .overlay(armCardShape.strokeBorder(Theme.paneLine, lineWidth: 1))
        .disabled(model.isBusy)
    }

    // MARK: Rows

    private var topRow: some View {
        HStack(spacing: 10) {
            ArmTitle(model: model, arm: arm, editing: $renaming)
                .opacity(arm.isEnabled ? 1 : 0.6)
                .layoutPriority(1)
            Spacer(minLength: 4)
            ruleBadge
            overflowMenu
            Toggle("Enabled", isOn: Binding(
                get: { arm.isEnabled },
                set: { value in Task { await model.setArmEnabled(arm.id, value) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Enabled")
                .accessibilityValue("\(arm.name), \(arm.isEnabled ? "on" : "off")")
        }
    }

    @ViewBuilder
    private var ruleBadge: some View {
        let label = HStack(spacing: 4) {
            Text(Self.ruleName(arm.rule))
            if arm.canChangeRule { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .fixedSize()
        if arm.canChangeRule {
            Menu {
                Picker("Rule", selection: ruleBinding) {
                    Text("Busy only").tag(ArmRuleMode.busy)
                    Text("Full details").tag(ArmRuleMode.fullDetails)
                }
                .pickerStyle(.inline)
            } label: { label }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose what the copies show")
                .accessibilityLabel("Rule for \(arm.name)")
                .accessibilityValue(Self.ruleName(arm.rule))
        } else {
            label
                .help("The Main calendar always shows full details")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rule for \(arm.name)")
                .accessibilityValue("\(Self.ruleName(arm.rule)), fixed")
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button("Rename") { renaming = true }
            Divider()
            Button(arm.isMain ? "Remove Main calendar…" : "Remove…", role: .destructive) { confirmingRemoval = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions for \(arm.name)")
    }

    private var flow: some View {
        let sources = Array(zip(arm.sourceIDs, model.sourceNames(of: arm)))
        return HStack(alignment: .top, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(sources, id: \.0) { id, name in CalendarChip(name: name, color: colors.color(for: id).color) }
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(height: 26)
            CalendarChip(name: model.targetName(of: arm), color: colors.color(for: arm.targetID).color, isTarget: true)
        }
        .opacity(arm.isEnabled ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Copies from \(sources.map(\.1).joined(separator: ", ")) into \(model.targetName(of: arm))")
    }

    private var removalConfirm: some View {
        HStack(spacing: 8) {
            Text("Remove this arm? Events already copied stay put.").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { confirmingRemoval = false }.buttonStyle(.quiet)
            Button("Remove", role: .destructive) {
                confirmingRemoval = false
                Task { await model.removeArm(arm.id) }
            }
            .buttonStyle(.quiet)
        }
    }

    static func ruleName(_ rule: ArmRuleMode) -> String { rule == .busy ? "Busy only" : "Full details" }
}

/// A calendar as a small capsule with its color. The destination gets an outline.
struct CalendarChip: View {
    let name: String
    let color: Color
    var isTarget = false

    var body: some View {
        CappedWidth(limit: 280) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 11).frame(height: 26)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay { if isTarget { Capsule().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1) } }
        }
    }
}

/// Keeps a long name from stretching its capsule: the child is offered at most `limit` and
/// then sized to what it needs, unlike a flexible frame, which grows to fill the offer.
struct CappedWidth: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(offer(proposal))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: offer(proposal))
    }

    private func offer(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? limit, limit), height: proposal.height)
    }
}

/// The arm's name. Double-click, the pencil or Rename edits it in place.
private struct ArmTitle: View {
    let model: SetupModel
    let arm: SetupArm
    @Binding var editing: Bool

    @State private var draft = ""
    @State private var problem: String?
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if editing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .focused($focused)
                    .onSubmit { Task { await commit(keepOpenOnError: true) } }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused && editing { Task { await commit(keepOpenOnError: false) } }
                    }
                if let problem { Text(problem).font(.caption).foregroundStyle(Theme.bad) }
            } else {
                HStack(spacing: 6) {
                    Text(arm.name).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    Button { editing = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0)
                        .help("Rename")
                        .accessibilityLabel("Rename \(arm.name)")
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { editing = true }
                .onHover { hovering = $0 }
                .contextMenu { Button("Rename") { editing = true } }
            }
        }
        .onChange(of: editing) { _, isEditing in
            if isEditing { begin() }
        }
    }

    private func begin() {
        draft = arm.name
        problem = nil
        focused = true
    }

    private func commit(keepOpenOnError: Bool) async {
        guard editing else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == arm.name { editing = false; return }
        if let message = await model.renameArm(arm.id, to: name) {
            if keepOpenOnError { problem = message; focused = true } else { editing = false }
        } else {
            editing = false
        }
    }
}
