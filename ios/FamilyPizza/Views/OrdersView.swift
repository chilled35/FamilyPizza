import SwiftUI

struct OrdersView: View {
    @Environment(AppModel.self) private var model

    private var active: [Order] { model.orders.filter { $0.status.isActive } }
    private var past: [Order] { model.orders.filter { !$0.status.isActive } }

    var body: some View {
        NavigationStack {
            List {
                OfflineBanner()
                if !active.isEmpty {
                    Section {
                        ForEach(active) { order in
                            Button { model.trackingOrderId = order.id } label: { OrderRow(order: order) }
                                .buttonStyle(.plain)
                                .accessibilityHint("Opens the order tracker")
                        }
                    } header: {
                        Text("On the go")
                    } footer: {
                        Text("Tap an order to follow it live.")
                    }
                }
                if !past.isEmpty {
                    Section("Earlier") {
                        ForEach(past) { order in
                            Button { model.trackingOrderId = order.id } label: { OrderRow(order: order) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .overlay {
                if model.orders.isEmpty {
                    ContentUnavailableView("No orders yet", systemImage: "bag",
                                           description: Text("Orders you send appear here, with their progress."))
                }
            }
            .refreshable { await model.refreshOrders() }
            .navigationTitle("My orders")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { CartButton() }
            }
            // While this tab is on screen, keep statuses fresh (push covers "ready" when the app is closed).
            .task {
                while !Task.isCancelled {
                    await model.refreshOrders()
                    try? await Task.sleep(for: .seconds(model.hasActiveOrders ? 10 : 60))
                }
            }
        }
    }
}

private struct OrderRow: View {
    @Environment(AppModel.self) private var model
    let order: Order

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(order.status.title, systemImage: order.status.symbol)
                    .font(.subheadline.bold())
                    .foregroundStyle(order.status.colour)
                Spacer()
                Text("#\(order.id)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(Array(order.items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 10) {
                    PizzaThumb(spec: model.spec(for: item), size: 40)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.pizzaName)
                        let summary = ToppingText.summary(item, recipe: item.pizzaId.flatMap { model.pizza(id: $0)?.toppings },
                                                          usualSauceId: item.pizzaId.flatMap { model.pizza(id: $0)?.sauce?.id })
                        if !summary.isEmpty {
                            Text(summary).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !order.note.isEmpty {
                Text("“\(order.note)”").font(.footnote).italic().foregroundStyle(.secondary)
            }
            Text(order.createdAt, format: Calendar.current.isDateInToday(order.createdAt)
                 ? .dateTime.hour().minute()
                 : .dateTime.weekday().day().month().hour().minute())
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .listRowBackground(order.status == .ready ? Color.green.opacity(0.15) : nil)
    }
}
