import CalopodCommands
import CalopodDomain
import SwiftUI

struct ArmsScreen: View {
    let model: SetupModel
    private let colors = CalendarColors.shared

    @State private var creating = false

    var body: some View {
        ScrollView { page }
                .task { await model.reload() }
            .sheet(isPresented: $creating) { NewArmSheet(model: model, colors: colors).appTypography() }
    }

    var page: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            header
            if let busy = model.busy { BusyLine(text: busy) }
            if let notice = model.notice, !creating { Banner(kind: .error, text: notice) }
            if let arms = model.snapshot?.arms {
                if arms.isEmpty {
                    emptyState
                } else {
                    ForEach(arms) { ArmCard(model: model, arm: $0, colors: colors) }
                }
            }
        }
        .pageEdges(inlineHeader: true)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        PageHeader(
            title: "Arms",
            subtitle: "An arm copies events from one or more calendars into another, as Busy blocks or with full details."
        ) {
            Button { creating = true } label: { Label("New arm", systemImage: "plus") }
                .buttonStyle(.accentFilled)
                .disabled(model.isBusy)
                .keyboardShortcut("n", modifiers: .command)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(Theme.Fonts.emptyGlyph)
                .foregroundStyle(Theme.accent)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Theme.accent.opacity(0.12)))
            Text("No arms yet").font(Theme.Fonts.sectionTitle)
            Text("Choose New arm to send one or more calendars into another. First-run setup, from Overview, builds a Main calendar and Busy blocks for you.")
                .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .background(armCardShape.fill(Theme.paneLine))
    }
}

let armCardShape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
