import SwiftUI

enum MenuRoute: Hashable {
    case pizza(MenuPizza)
    case buildYourOwn
}

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                OfflineBanner()
                if !model.menu.isEmpty {
                    Section {
                        NavigationLink(value: MenuRoute.buildYourOwn) {
                            BuildYourOwnRow()
                        }
                    } footer: {
                        Text("Thin crust, your sauce, your toppings: all over or on one half, normal or double.")
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    Section {
                        ForEach(model.menu) { pizza in
                            NavigationLink(value: MenuRoute.pizza(pizza)) {
                                PizzaRow(pizza: pizza)
                            }
                        }
                    } header: {
                        Text("Our pizzas")
                    }
                }
            }
            .overlay {
                if model.menu.isEmpty {
                    if model.lastRefreshError == nil {
                        ProgressView()
                    } else {
                        ContentUnavailableView("No menu", systemImage: "wifi.exclamationmark",
                                               description: Text("Pull down to try again."))
                    }
                }
            }
            .refreshable { await model.refreshMenu() }
            // Large titles are always left-aligned, so draw a big centred one in the bar instead.
            // navigationTitle stays for the back button on pushed screens.
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MenuRoute.self) { route in
                switch route {
                case .pizza(let pizza): PizzaDetailView(pizza: pizza)
                case .buildYourOwn: BuildYourOwnView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Menu")
                        .font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "person.crop.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { CartButton() }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
        }
    }
}

private struct PizzaRow: View {
    @Environment(AppModel.self) private var model
    let pizza: MenuPizza

    var body: some View {
        HStack(spacing: 14) {
            PizzaThumb(spec: model.spec(pizza: pizza, customisation: Customisation(pizzaId: pizza.id)), size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(pizza.name).font(.headline)
                if !pizza.description.isEmpty {
                    Text(pizza.description).font(.subheadline).foregroundStyle(.secondary)
                }
                ToppingList(toppings: pizza.toppings, sauce: pizza.sauce)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct BuildYourOwnRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            PizzaThumb(spec: PizzaSpec(sauceHex: model.sauces.first?.colour), size: 64)
                .overlay {
                    Image(systemName: "plus")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text("Build your own").font(.headline)
                Text("Pick a sauce and toppings, half and half if you like")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// "Tomato sauce · Mozzarella, Pepperoni (left half), ~~Basil~~" with unavailable toppings struck through.
/// Cheese comes straight after the sauce.
struct ToppingList: View {
    let toppings: [BaseTopping]
    var sauce: Sauce?

    init(toppings: [BaseTopping], sauce: Sauce? = nil) {
        self.toppings = toppings.filter { $0.artStyle == .cheese } + toppings.filter { $0.artStyle != .cheese }
        self.sauce = sauce
    }

    var body: some View {
        if !toppings.isEmpty || sauce != nil {
            let start = sauce.map { Text($0.label + (toppings.isEmpty ? "" : " · ")).foregroundStyle(.secondary) } ?? Text("")
            toppings.enumerated().reduce(start) { text, entry in
                let (index, topping) = entry
                let name = Text(topping.recipeLabel)
                    .strikethrough(!topping.active)
                    .foregroundStyle(topping.active ? Color.secondary : Color.red)
                return text + (index == 0 ? Text("") : Text(", ").foregroundStyle(.secondary)) + name
            }
            .font(.footnote)
            .accessibilityLabel(((sauce.map { [$0.label] } ?? []) + toppings.map { $0.active ? $0.recipeLabel : "\($0.recipeLabel), unavailable" })
                .joined(separator: ", "))
        }
    }
}
