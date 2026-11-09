import SwiftUI

struct FavouritesView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmation: String?

    var body: some View {
        NavigationStack {
            List {
                OfflineBanner()
                ForEach(model.favourites) { favourite in
                    Button {
                        confirmation = model.addToCart(favourite: favourite)
                    } label: {
                        FavouriteRow(favourite: favourite)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.problem(with: favourite) != nil)
                }
                .onDelete { offsets in
                    let doomed = offsets.map { model.favourites[$0] }
                    Task { for favourite in doomed { await model.deleteFavourite(favourite) } }
                }
            }
            .overlay {
                if model.favourites.isEmpty {
                    ContentUnavailableView("No favourites yet", systemImage: "star",
                                           description: Text("Customise a pizza on the menu or build your own, then tap ☆ to save it."))
                }
            }
            .refreshable { await model.refreshFavourites() }
            .navigationTitle("Favourites")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { CartButton() }
            }
            .overlay(alignment: .bottom) {
                if let confirmation {
                    Text(confirmation)
                        .font(.subheadline.bold())
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(for: .seconds(1.5))
                            withAnimation { self.confirmation = nil }
                        }
                }
            }
            .animation(.default, value: confirmation)
            .sensoryFeedback(.success, trigger: confirmation) { _, new in new != nil }
        }
    }
}

private struct FavouriteRow: View {
    @Environment(AppModel.self) private var model
    let favourite: Favourite

    var body: some View {
        // Judged against the current menu rather than the server's `available` flag,
        // which also counts run-out base toppings (those are simply left off).
        let problem = model.problem(with: favourite)
        let runOut = model.runOut(for: favourite)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(favourite.label).font(.headline)
                if favourite.label != favourite.pizzaName {
                    Text(favourite.pizzaName).font(.subheadline)
                }
                let pizza = favourite.pizzaId.flatMap { model.pizza(id: $0) }
                let summary = ToppingText.summary(favourite, recipe: pizza?.toppings, usualSauceId: pizza?.sauce?.id)
                if !summary.isEmpty {
                    Text(summary).font(.footnote).foregroundStyle(.secondary)
                }
                if let problem {
                    Text("Not available: \(problem)").font(.footnote).foregroundStyle(.red)
                } else if !runOut.isEmpty {
                    Text("\(runOut.map(\.name).formatted(.list(type: .and))) run out, will be left off")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            Spacer()
            if problem == nil {
                Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(problem == nil ? .primary : .secondary)
        .contentShape(Rectangle())
        .accessibilityHint(problem == nil ? "Adds to your basket" : "")
    }
}
