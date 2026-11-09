import SwiftUI

/// Customise a menu pizza: swap the sauce, and put each topping (the recipe's and any extras)
/// on the left half, the whole pizza or the right half, normal or double, or leave it off.
/// It starts as the recipe. The picture at the top follows every change.
struct PizzaDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let pizza: MenuPizza

    /// How much of each topping is on each half. Starts as the recipe (run-out toppings aside).
    @State private var amounts: [Int: HalfAmounts]
    /// Non-recipe toppings in the order they were added (later ones are drawn on top).
    @State private var extrasOrder: [Int] = []
    @State private var sauceId: Int?                  // nil = the pizza's usual sauce
    @State private var askingLabel = false
    @State private var label = ""
    @State private var saving = false
    @State private var confirmation: String?

    init(pizza: MenuPizza) {
        self.pizza = pizza
        _amounts = State(initialValue: Dictionary(
            uniqueKeysWithValues: pizza.toppings.filter(\.active).map { ($0.id, $0.amounts) }))
    }

    private var baseIds: Set<Int> { Set(pizza.toppings.map(\.id)) }
    private var extraChoices: [ToppingInfo] { model.toppings.filter { !baseIds.contains($0.id) } }

    /// What goes in the basket: run-out base toppings are left off.
    private var customisation: Customisation { customisation(leaveOffRunOut: true) }

    /// The whole pizza as it should be made; the server turns it back into "No X / + Y / Extra Z"
    /// when that says it exactly. A favourite keeps a topping that has run out today at its
    /// recipe amount, so it isn't saved as "No X" for ever (it's left off at order time instead).
    private func customisation(leaveOffRunOut: Bool) -> Customisation {
        // Only send a sauce when it differs from the usual one.
        var c = Customisation(pizzaId: pizza.id, sauceId: sauceId == pizza.sauce?.id ? nil : sauceId)
        for topping in pizza.toppings {
            if !topping.active {
                if !leaveOffRunOut { c.toppings += topping.amounts.placed(id: topping.id) }
                continue
            }
            c.toppings += amount(topping.id).placed(id: topping.id)
        }
        for id in extrasOrder {
            c.toppings += amount(id).placed(id: id)
        }
        return c
    }

    private func amount(_ id: Int) -> HalfAmounts { amounts[id] ?? HalfAmounts() }

    private var isRecipe: Bool {
        extrasOrder.isEmpty && pizza.toppings.filter(\.active).allSatisfy { amount($0.id) == $0.amounts }
    }

    /// The picture follows what's on screen (run-out toppings are left off).
    private var spec: PizzaSpec {
        model.spec(pizza: pizza, customisation: customisation)
    }

    var body: some View {
        PizzaStageLayout(spec: spec, caption: halfCaption(customisation.toppings)) {
            form
        }
        .modifiers(pizza: pizza, model: model, saving: saving, askingLabel: $askingLabel, label: $label,
                   confirmation: $confirmation, addToCart: {
            model.addToCart(pizza: pizza, customisation: customisation)
            confirmation = "Added to your basket"
        }, save: { Task { await saveFavourite() } })
        .sensoryFeedback(trigger: amounts) { old, new in
            // A firmer tap when something goes to double.
            let doubles = { (a: [Int: HalfAmounts]) in a.values.reduce(0) { $0 + ($1.left == 2 ? 1 : 0) + ($1.right == 2 ? 1 : 0) } }
            return doubles(new) > doubles(old) ? .impact(weight: .medium) : .selection
        }
        .onChange(of: model.toppings) {
            // An extra switched off while choosing: drop it rather than fail at checkout.
            let active = Set(model.toppings.map(\.id))
            for id in extrasOrder where !active.contains(id) { amounts[id] = nil }
            extrasOrder.removeAll { !active.contains($0) }
        }
    }

    private var form: some View {
        Form {
            if !pizza.description.isEmpty {
                Section { Text(pizza.description).foregroundStyle(.secondary) }
            }

            if !model.sauces.isEmpty {
                Section("Sauce") {
                    SaucePicker(sauces: model.sauces, selection: Binding(
                        get: { sauceId ?? pizza.sauce?.id },
                        set: { sauceId = $0 }), usualId: pizza.sauce?.id)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 0))
                }
            }

            // Cheese has its own section, like the sauce: the recipe's cheese and any other cheese.
            if hasCheeseSection {
                Section {
                    ForEach(baseCheeses) { baseRow($0) }
                    ForEach(extraCheeses) { toppingRow($0, usual: HalfAmounts()) }
                } header: {
                    sectionHeader("Cheese")
                } footer: {
                    Text(Self.pickerHint)
                }
            }

            if !baseToppings.isEmpty {
                Section {
                    ForEach(baseToppings) { baseRow($0) }
                } header: {
                    if hasCheeseSection { Text("Comes with") } else { sectionHeader("Comes with") }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if !hasCheeseSection { Text(Self.pickerHint) }
                        if pizza.hasUnavailableTopping {
                            Text("Struck-through toppings have run out and will be left off.")
                        }
                    }
                }
            }

            if !extraToppings.isEmpty {
                Section("Add") {
                    ForEach(extraToppings) { toppingRow($0, usual: HalfAmounts()) }
                }
            }
        }
    }

    private static let pickerHint = "◐ left half, ● whole pizza, ◑ right half. Tap for normal, again for double, again to take it off."

    private var baseCheeses: [BaseTopping] { pizza.toppings.filter { $0.artStyle == .cheese } }
    private var baseToppings: [BaseTopping] { pizza.toppings.filter { $0.artStyle != .cheese } }
    private var extraCheeses: [ToppingInfo] { extraChoices.filter { $0.artStyle == .cheese } }
    private var extraToppings: [ToppingInfo] { extraChoices.filter { $0.artStyle != .cheese } }
    private var hasCheeseSection: Bool { !baseCheeses.isEmpty || !extraCheeses.isEmpty }

    /// A section title with "Start again" (back to the recipe) once anything has changed.
    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            if !isRecipe {
                Button("Start again") {
                    withAnimation(.spring(duration: 0.4)) {
                        amounts = Dictionary(uniqueKeysWithValues:
                            pizza.toppings.filter(\.active).map { ($0.id, $0.amounts) })
                        extrasOrder.removeAll()
                    }
                }
                .font(.footnote)
                .textCase(nil)
            }
        }
    }

    @ViewBuilder private func baseRow(_ topping: BaseTopping) -> some View {
        if topping.active {
            toppingRow(topping, usual: topping.amounts)
        } else {
            HStack(spacing: 12) {
                ToppingThumb(topping: topping, size: 40, dimmed: true)
                Text(topping.name).strikethrough()
                Spacer()
                Text("Run out").foregroundStyle(.red)
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    /// A topping with ◐ ● ◑; `usual` is how the recipe has it (none for extras).
    private func toppingRow(_ topping: some ToppingPictured, usual: HalfAmounts) -> some View {
        let now = amount(topping.id)
        let changed = now != usual
        // Say where it goes unless it's simply normal all over as usual.
        let caption: String? = !now.isOn ? (usual.isOn ? "Left off" : nil)
            : (now.whole == 1 && !changed ? nil : now.description)
        return HStack(spacing: 12) {
            ToppingThumb(topping: topping, size: 40, dimmed: usual.isOn && !now.isOn)
            VStack(alignment: .leading, spacing: 2) {
                Text(topping.name)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let caption {
                    Text(caption + (changed && usual.isOn && now.isOn ? " (usually \(usual.description.lowercased()))" : ""))
                        .font(.caption.weight(now.hasDouble ? .bold : .regular))
                        .foregroundStyle(now.hasDouble ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .transition(.opacity)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            SidePicker(toppingName: topping.name, amounts: Binding(
                get: { amount(topping.id) },
                set: { value in
                    withAnimation(.spring(duration: 0.4)) {
                        amounts[topping.id] = value.isOn ? value : nil
                        guard !baseIds.contains(topping.id) else { return }
                        if value.isOn {
                            if !extrasOrder.contains(topping.id) { extrasOrder.append(topping.id) }
                        } else {
                            extrasOrder.removeAll { $0 == topping.id }
                        }
                    }
                }))
        }
        .padding(.vertical, 2)
    }

    private func saveFavourite() async {
        let trimmed = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !trimmed.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            try await model.saveFavourite(label: trimmed, customisation: customisation(leaveOffRunOut: false))
            confirmation = "Saved to favourites"
        } catch {
            model.alertMessage = (error as? APIError)?.message ?? error.localizedDescription
        }
    }
}

/// Toolbar, "Add to basket" bar, favourite prompt and toast for the customise screen.
private struct DetailChrome: ViewModifier {
    let pizza: MenuPizza
    let model: AppModel
    let saving: Bool
    @Binding var askingLabel: Bool
    @Binding var label: String
    @Binding var confirmation: String?
    let addToCart: () -> Void
    let save: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationTitle(pizza.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)  // room for the "Add to basket" bar
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        label = pizza.name
                        askingLabel = true
                    } label: {
                        Label("Save as favourite", systemImage: "star")
                    }
                    .disabled(saving)
                }
                ToolbarItem(placement: .topBarTrailing) { CartButton() }
            }
            // Always reachable, however long the topping list is.
            .safeAreaInset(edge: .bottom) {
                Button(action: addToCart) {
                    Label("Add to basket", systemImage: "basket.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .alert("Name this favourite", isPresented: $askingLabel) {
                TextField("e.g. Jason's usual", text: $label)
                    .textInputAutocapitalization(.sentences)
                Button("Save", action: save)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .overlay(alignment: .bottom) {
                if let confirmation {
                    Toast(text: confirmation) { self.confirmation = nil }
                        .padding(.bottom, 90)  // above the "Add to basket" bar
                }
            }
            .animation(.default, value: confirmation)
            .sensoryFeedback(.success, trigger: confirmation) { _, new in new != nil }
    }
}

private extension View {
    func modifiers(pizza: MenuPizza, model: AppModel, saving: Bool, askingLabel: Binding<Bool>, label: Binding<String>,
                   confirmation: Binding<String?>, addToCart: @escaping () -> Void, save: @escaping () -> Void) -> some View {
        modifier(DetailChrome(pizza: pizza, model: model, saving: saving, askingLabel: askingLabel, label: label,
                              confirmation: confirmation, addToCart: addToCart, save: save))
    }
}
