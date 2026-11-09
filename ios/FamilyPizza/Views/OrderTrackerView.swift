import SwiftUI

/// Full-screen live tracker for one order: Pending → Baking → Ready, driven by the kitchen.
/// Listens on the server's per-order event stream; if that drops it re-reads the order list
/// and reconnects, so a flaky Wi-Fi moment only delays an update by a few seconds.
struct OrderTrackerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let orderId: Int

    @State private var live = false

    private var order: Order? { model.order(id: orderId) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let order {
                    VStack(spacing: 24) {
                        hero(order)
                        VStack(spacing: 6) {
                            Text(order.status.title)
                                .font(.largeTitle.bold())
                                .foregroundStyle(order.status == .ready ? .green : .primary)
                                .contentTransition(.opacity)
                            Text(order.status.detail)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .accessibilityElement(children: .combine)
                        StepBar(status: order.status)
                            .padding(.horizontal)
                        details(order)
                    }
                    .padding(.vertical)
                    .animation(.spring(duration: 0.5), value: order.status)
                } else {
                    ProgressView().padding(.top, 80)
                }
            }
            .navigationTitle("Order #\(orderId)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { LiveBadge(live: live, finished: order?.status == .collected) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sensoryFeedback(.success, trigger: order?.status) { _, new in new == .ready }
            .sensoryFeedback(.impact, trigger: order?.status) { _, new in new == .preparing }
        }
        .task(id: orderId) { await follow() }
    }

    /// Stream updates; on any drop, refresh from the order list and try again shortly.
    private func follow() async {
        if order == nil { await model.refreshOrders() }
        while !Task.isCancelled {
            do {
                for try await update in model.orderUpdates(id: orderId) {
                    live = true
                    model.update(update)
                }
            } catch {}
            live = false
            if order?.status == .collected { return }
            await model.refreshOrders()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    // MARK: Pieces

    @ViewBuilder private func hero(_ order: Order) -> some View {
        let first = order.items.first.map { model.spec(for: $0) } ?? PizzaSpec(sauceHex: "#b5321e")
        ZStack {
            OvenGlow(active: order.status == .preparing)
            PizzaView(spec: first, images: model.toppingImages.images)
                .frame(width: 220, height: 220)
                .modifier(Spin(active: order.status == .preparing))
                .saturation(order.status == .new ? 0.75 : 1)
            if order.items.count > 1 {
                Text("×\(order.items.count)")
                    .font(.headline)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .offset(x: 95, y: -95)
            }
            if order.status == .ready || order.status == .collected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 54))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .background(Circle().fill(.background).padding(4))
                    .offset(x: 82, y: 82)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(height: 260)
        .accessibilityHidden(true)
    }

    private func details(_ order: Order) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(order.items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 12) {
                    PizzaThumb(spec: model.spec(for: item), size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.pizzaName).font(.headline)
                        let summary = ToppingText.summary(item, recipe: item.pizzaId.flatMap { model.pizza(id: $0)?.toppings },
                                                          usualSauceId: item.pizzaId.flatMap { model.pizza(id: $0)?.sauce?.id })
                        if !summary.isEmpty {
                            Text(summary).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if !order.note.isEmpty {
                Text("“\(order.note)”").font(.footnote).italic().foregroundStyle(.secondary)
            }
            Text("Ordered \(order.createdAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal)
    }
}

/// Pending — Baking — Ready, filled up to the current step; the current one pulses.
private struct StepBar: View {
    let status: OrderStatus

    private let steps: [(OrderStatus, String)] = [(.new, "Pending"), (.preparing, "Baking"), (.ready, "Ready")]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let done = status.step > index || status == .collected
                let current = status.step == index && status != .collected
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(done || current ? AnyShapeStyle(colour(index)) : AnyShapeStyle(.fill.tertiary))
                            .frame(width: 44, height: 44)
                        Image(systemName: done ? "checkmark" : step.0.symbol)
                            .font(.headline)
                            .foregroundStyle(done || current ? .white : .secondary)
                            .symbolEffect(.pulse, isActive: current)
                    }
                    .scaleEffect(current ? 1.12 : 1)
                    Text(step.1)
                        .font(.footnote.weight(current ? .bold : .regular))
                        .foregroundStyle(current ? .primary : .secondary)
                }
                .frame(width: 72)
                if index < steps.count - 1 {
                    Capsule()
                        .fill(status.step > index ? AnyShapeStyle(colour(index + 1)) : AnyShapeStyle(.fill.tertiary))
                        .frame(height: 5)
                        .padding(.top, 20)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(status.step + 1) of 3: \(status.title)")
    }

    private func colour(_ index: Int) -> Color {
        [Color.blue, .orange, .green][index]
    }
}

/// A warm, breathing glow behind the pizza while it bakes.
private struct OvenGlow: View {
    let active: Bool
    @State private var phase = false

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [.orange.opacity(0.55), .red.opacity(0.25), .clear],
                                 center: .center, startRadius: 60, endRadius: 150))
            .frame(width: 300, height: 300)
            .scaleEffect(phase ? 1.06 : 0.94)
            .opacity(active ? (phase ? 1 : 0.65) : 0)
            .animation(active ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : .default, value: phase)
            .animation(.easeInOut(duration: 0.6), value: active)
            .onAppear { phase = true }
    }
}

/// Slow turn, like a pizza on an oven stone.
private struct Spin: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !active)) { context in
            let angle = active ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 40) / 40 * 360 : 0
            content.rotationEffect(.degrees(angle))
        }
    }
}

private struct LiveBadge: View {
    let live: Bool
    let finished: Bool

    var body: some View {
        if !finished {
            HStack(spacing: 6) {
                Circle().fill(live ? .green : .orange).frame(width: 8, height: 8)
                Text(live ? "Live" : "Connecting…").font(.footnote).foregroundStyle(.secondary)
            }
            .fixedSize()
            .padding(.horizontal, 6)
            .accessibilityElement(children: .combine)
        }
    }
}
