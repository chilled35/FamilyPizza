import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isRegistered {
                TabView(selection: $model.selectedTab) {
                    MenuView()
                        .tabItem { Label("Menu", systemImage: "list.bullet") }
                        .tag(Tab.menu)
                    FavouritesView()
                        .tabItem { Label("Favourites", systemImage: "star") }
                        .tag(Tab.favourites)
                    OrdersView()
                        .tabItem { Label("My orders", systemImage: "bag") }
                        .badge(model.readyOrders)
                        .tag(Tab.orders)
                }
            } else {
                OnboardingView()
            }
        }
        .fullScreenCover(item: Binding(
            get: { model.trackingOrderId.map(TrackedOrder.init) },
            set: { model.trackingOrderId = $0?.id })
        ) { tracked in
            OrderTrackerView(orderId: tracked.id)
        }
        .alert("Family Pizza", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

private struct TrackedOrder: Identifiable {
    let id: Int
}

/// Toolbar button that opens the basket, with a count.
struct CartButton: View {
    @Environment(AppModel.self) private var model
    @State private var showingCart = false

    var body: some View {
        Button {
            showingCart = true
        } label: {
            // Icon plus count (toolbar buttons clip overlays, so no floating badge).
            if model.cart.isEmpty {
                Image(systemName: "basket")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "basket.fill")
                    Text("\(model.cart.count)").font(.body.bold().monospacedDigit())
                }
                .foregroundStyle(.tint)
            }
        }
        .accessibilityLabel(model.cart.isEmpty ? "Basket, empty" : "Basket, \(model.cart.count) pizzas")
        .sheet(isPresented: $showingCart) {
            CartView()
        }
    }
}

/// Shown above a list when the last refresh failed (e.g. not on home Wi-Fi).
struct OfflineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.lastRefreshError {
            Label(error.message, systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
