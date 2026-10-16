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
            .sheet(isPresented: $creating) { NewArmSheet(model: model, colors: colors) }
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
        .padding(Theme.pagePadding)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Arms").font(Theme.title(.title))
                Text("An arm copies events from one or more calendars into another, as Busy blocks or with full details.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { creating = true } label: { Label("New arm", systemImage: "plus") }
                .buttonStyle(.accentFilled)
                .disabled(model.isBusy)
                .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Theme.accent.opacity(0.12)))
            Text("No arms yet").font(Theme.title(.title3))
            Text("Choose New arm to send one or more calendars into another. First-run setup, from Overview, builds a Main calendar and Busy blocks for you.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .background(cardShape.fill(Theme.paneLine))
    }
}

let armCardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
private let cardShape = armCardShape
