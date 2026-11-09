import SwiftUI

/// Build your own: standard thin crust, any sauce, any toppings on the whole pizza or one half.
struct BuildYourOwnView: View {
    @Environment(AppModel.self) private var model

    @State private var sauceId: Int?
    /// How much of each topping is on each half.
    @State private var amounts: [Int: HalfAmounts] = [:]
    /// Topping ids in the order they were added (later ones are drawn on top).
    @State private var order: [Int] = []
    @State private var started = false
    @State private var confirmation: String?
    /// Naming a favourite (`.favourite`) or a menu suggestion (`.suggestion`).
    @State private var naming: Naming?
    @State private var name = ""
    @State private var sending = false

    enum Naming: Identifiable { case favourite, suggestion; var id: Self { self } }

    private var placed: [PlacedTopping] {
        order.flatMap { id in amounts[id]?.placed(id: id) ?? [] }
    }

    private var customisation: Customisation {
        Customisation(pizzaId: nil, sauceId: sauceId, toppings: placed)
    }

    var body: some View {
        PizzaStageLayout(spec: model.spec(buildYourOwn: customisation), caption: halfCaption(placed)) {
            Form {
                Section("Base") {
                    HStack(spacing: 12) {
                        Image(systemName: "circle.dashed")
                            .font(.title2).foregroundStyle(.orange)
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Thin crust")
                            Text("Our standard base").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                Section("Sauce") {
                    if model.sauces.isEmpty {
                        Text("No sauces available").foregroundStyle(.secondary)
                    } else {
                        SaucePicker(sauces: model.sauces, selection: $sauceId)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 0))
                    }
                }

                // Cheese has its own section, like the sauce.
                let cheeses = model.toppings.filter { $0.artStyle == .cheese }
                if !cheeses.isEmpty {
                    Section("Cheese") {
                        ForEach(cheeses) { row($0) }
                    }
                }

                Section {
                    ForEach(model.toppings.filter { $0.artStyle != .cheese }) { topping in
                        row(topping)
                    }
                } header: {
                    Text("Toppings")
                } footer: {
                    Text("Tap once for normal, again for double, again to take it off. ◐ left half, ● whole pizza, ◑ right half.")
                }

                Section {
                    Button {
                        name = ""
                        naming = .suggestion
                    } label: {
                        Label("Suggest this pizza for the menu", systemImage: "lightbulb")
                    }
                    .disabled(sauceId == nil || sending)
                } footer: {
                    Text("The owner sees it in the menu admin and may add it to the menu for everyone.")
                }
            }
            .safeAreaPadding(.bottom, 8)
        }
        .navigationTitle("Build your own")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") {
                    withAnimation {
                        amounts.removeAll()
                        order.removeAll()
                    }
                }
                .disabled(order.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    name = ""
                    naming = .favourite
                } label: {
                    Label("Save as favourite", systemImage: "star")
                }
                .disabled(sauceId == nil || sending)
            }
            ToolbarItem(placement: .topBarTrailing) { CartButton() }
        }
        .alert(naming == .suggestion ? "Suggest for the menu" : "Name this favourite",
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }),
               presenting: naming) { kind in
            TextField(kind == .suggestion ? "Name it (optional)" : "e.g. My half and half", text: $name)
                .textInputAutocapitalization(.words)
            Button(kind == .suggestion ? "Send" : "Save") { Task { await send(kind) } }
                .disabled(kind == .favourite && name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { kind in
            if kind == .suggestion { Text("This pizza goes to the owner as an idea for the menu.") }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.addToCart(buildYourOwn: customisation)
                confirmation = "Added to your basket"
            } label: {
                Label("Add to basket", systemImage: "basket.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .disabled(sauceId == nil)
        }
        .overlay(alignment: .bottom) {
            if let confirmation {
                Toast(text: confirmation) { self.confirmation = nil }
                    .padding(.bottom, 90)
            }
        }
        .animation(.default, value: confirmation)
        .sensoryFeedback(.success, trigger: confirmation) { _, new in new != nil }
        .sensoryFeedback(trigger: amounts) { old, new in
            // A firmer tap when something goes to double.
            let doubles = { (a: [Int: HalfAmounts]) in a.values.reduce(0) { $0 + ($1.left == 2 ? 1 : 0) + ($1.right == 2 ? 1 : 0) } }
            return doubles(new) > doubles(old) ? .impact(weight: .medium) : .selection
        }
        .onAppear(perform: startIfNeeded)
        .onChange(of: model.sauces) { startIfNeeded() }
        .onChange(of: model.toppings) {
            // A topping switched off while choosing: drop it rather than fail at checkout.
            let active = Set(model.toppings.map(\.id))
            order.removeAll { !active.contains($0) }
            amounts = amounts.filter { active.contains($0.key) }
        }
    }

    private func send(_ kind: Naming) async {
        sending = true
        defer { sending = false }
        do {
            switch kind {
            case .favourite:
                let label = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                guard !label.isEmpty else { return }
                try await model.saveFavourite(label: label, customisation: customisation)
                confirmation = "Saved to favourites"
            case .suggestion:
                try await model.suggestForMenu(name: name, customisation: customisation)
                confirmation = "Sent to the owner. Thanks!"
            }
        } catch {
            model.alertMessage = (error as? APIError)?.message ?? error.localizedDescription
        }
    }

    /// Start like a classic: the usual sauce and cheese all over.
    private func startIfNeeded() {
        if sauceId == nil || !model.sauces.contains(where: { $0.id == sauceId }) {
            sauceId = model.sauces.first?.id
        }
        guard !started, !model.toppings.isEmpty else { return }
        started = true
        if let cheese = model.toppings.first(where: { $0.artStyle == .cheese }) {
            amounts = [cheese.id: HalfAmounts(left: 1, right: 1)]
            order = [cheese.id]
        }
    }

    private func amountsBinding(_ topping: ToppingInfo) -> Binding<HalfAmounts> {
        Binding(
            get: { amounts[topping.id] ?? HalfAmounts() },
            set: { value in
                withAnimation(.spring(duration: 0.4)) {
                    if value.isOn {
                        if !order.contains(topping.id) { order.append(topping.id) }
                        amounts[topping.id] = value
                    } else {
                        order.removeAll { $0 == topping.id }
                        amounts[topping.id] = nil
                    }
                }
            })
    }

    @ViewBuilder private func row(_ topping: ToppingInfo) -> some View {
        let amount = amounts[topping.id] ?? HalfAmounts()
        HStack(spacing: 12) {
            ToppingThumb(topping: topping, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(topping.name)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if amount.isOn {
                    Text(amount.description)
                        .font(.caption.weight(amount.hasDouble ? .bold : .regular))
                        .foregroundStyle(amount.hasDouble ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .transition(.opacity)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            SidePicker(toppingName: topping.name, amounts: amountsBinding(topping))
        }
        .padding(.vertical, 2)
    }
}

/// A short confirmation that fades away by itself.
struct Toast: View {
    let text: String
    let onDone: () -> Void

    var body: some View {
        Text(text)
            .font(.subheadline.bold())
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { onDone() }
            }
    }
}
