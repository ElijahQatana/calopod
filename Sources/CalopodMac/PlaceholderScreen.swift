import SwiftUI

/// Stand-in for screens that are not built yet.
struct PlaceholderScreen: View {
    let screen: Screen
    let detail: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(screen.title, systemImage: screen.symbol)
        } description: {
            Text(detail)
        } actions: {
            if let action {
                Button(action.title, action: action.run).buttonStyle(.accentFilled)
            }
        }
    }
}
