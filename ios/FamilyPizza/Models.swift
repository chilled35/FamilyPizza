import Foundation
import SwiftUI

// Shapes match the server's OpenAPI schema (http://192.168.0.50:8000/docs).
// JSON keys are snake_case; APIClient converts them.

struct ToppingRef: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
}

/// Anything that can show a topping picture: its photo from the server, or a drawing.
protocol ToppingPictured {
    var id: Int { get }
    var name: String { get }
    var style: String? { get }
    var imageUrl: String? { get }
}

extension ToppingPictured {
    var artStyle: ToppingStyle { ToppingStyle(serverValue: style) }
}

/// An active topping from `GET /api/toppings`.
struct ToppingInfo: Codable, Hashable, Identifiable, Sendable, ToppingPictured {
    let id: Int
    let name: String
    let style: String?
    /// Relative to the server and versioned; nil until the owner uploads a photo.
    let imageUrl: String?
}

/// A base topping on a menu pizza. `active == false` means it's currently unavailable.
struct BaseTopping: Codable, Hashable, Identifiable, Sendable, ToppingPictured {
    let id: Int
    let name: String
    let active: Bool
    let style: String?
    let imageUrl: String?
    /// How much the recipe puts on each half: 0 none, 1 normal, 2 double (server v0.8+; older
    /// servers send neither, meaning normal all over).
    let left: Int?
    let right: Int?

    var amounts: HalfAmounts { HalfAmounts(left: left ?? 1, right: right ?? 1) }

    /// "Mozzarella", "Double Ham", "Pepperoni (left half)".
    var recipeLabel: String {
        switch amounts.whole {
        case 1: name
        case 2: "Double \(name)"
        default: "\(name) (\(amounts.description.lowercased()))"
        }
    }
}

struct Sauce: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    /// "#rrggbb" for the picture; "" = nothing painted (e.g. "No sauce").
    let colour: String

    /// "Tomato sauce", but "No sauce" rather than "No sauce sauce".
    var label: String { colour.isEmpty || name.localizedCaseInsensitiveContains("sauce") ? name : "\(name) sauce" }
}

struct MenuPizza: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let description: String
    /// The pizza's usual sauce; the person may swap it.
    let sauce: Sauce?
    let toppings: [BaseTopping]

    var hasUnavailableTopping: Bool { toppings.contains { !$0.active } }
}

struct User: Codable, Sendable {
    let id: Int
    let uuid: String
    let name: String
}

/// A topping on one or both halves: build your own, or a menu pizza with its halves changed.
struct PlacedTopping: Codable, Hashable, Sendable {
    let id: Int
    var side: PizzaSide = .whole
    var extra = false
}

/// One pizza as sent to the server (`Customisation` in server/main.py).
/// Menu pizza: `pizzaId`, then either `toppings` (the whole pizza as it should be made, halves
/// and doubles included; what this app sends, needs server v0.8+) or the older `added` (may
/// repeat a base topping, meaning "extra") and `removed` (base toppings left off);
/// `sauceId` nil = the pizza's usual sauce.
/// Build your own: `pizzaId` nil, `sauceId` set, `toppings` with a side each.
struct Customisation: Codable, Hashable, Sendable {
    var pizzaId: Int?
    var sauceId: Int?
    var added: [Int] = []
    var removed: [Int] = []
    var toppings: [PlacedTopping] = []

    var isBuildYourOwn: Bool { pizzaId == nil }
}

struct PlacedToppingRef: Codable, Hashable, Sendable {
    let id: Int
    let name: String
    let side: PizzaSide
    let extra: Bool
}

struct OrderItem: Codable, Hashable, Sendable {
    /// nil = build your own.
    let pizzaId: Int?
    let pizzaName: String
    /// nil only on orders placed before sauces existed.
    let sauce: Sauce?
    let added: [ToppingRef]
    let removed: [ToppingRef]
    let toppings: [PlacedToppingRef]?
}

enum OrderStatus: String, Codable, Sendable {
    case new, preparing, ready, collected

    var title: String {
        switch self {
        case .new: "Pending"
        case .preparing: "Baking"
        case .ready: "Ready to collect"
        case .collected: "Collected"
        }
    }

    /// One line for the tracker.
    var detail: String {
        switch self {
        case .new: "Waiting for the kitchen to start it."
        case .preparing: "In the oven now."
        case .ready: "Come and get it while it's hot!"
        case .collected: "Enjoy your pizza."
        }
    }

    var symbol: String {
        switch self {
        case .new: "clock.fill"
        case .preparing: "flame.fill"
        case .ready: "bell.fill"
        case .collected: "checkmark.circle.fill"
        }
    }

    /// Tracker step: 0 pending, 1 baking, 2 ready (collected counts as done).
    var step: Int {
        switch self {
        case .new: 0
        case .preparing: 1
        case .ready, .collected: 2
        }
    }

    var colour: Color {
        switch self {
        case .new: .blue
        case .preparing: .orange
        case .ready: .green
        case .collected: .secondary
        }
    }

    var isActive: Bool { self != .collected }
}

struct Order: Codable, Identifiable, Sendable {
    let id: Int
    let status: OrderStatus
    let note: String
    let createdAt: Date
    let updatedAt: Date
    let items: [OrderItem]
}

struct Favourite: Codable, Identifiable, Sendable {
    let id: Int
    let label: String
    /// nil = build your own (sauce + toppings as saved; server v0.9+).
    let pizzaId: Int?
    let pizzaName: String
    /// The sauce it will come with (saved swap, or the pizza's usual one).
    let sauce: Sauce?
    /// As saved: nil = the pizza's usual sauce.
    let sauceId: Int?
    let added: [ToppingRef]
    let removed: [ToppingRef]
    /// Set (instead of added/removed) when the halves were changed: the pizza exactly as saved.
    let toppings: [PlacedToppingRef]?
    /// False when the pizza is off the menu or a needed topping is switched off.
    let available: Bool

    var hasHalves: Bool { !(toppings ?? []).isEmpty }

    var customisation: Customisation {
        if let toppings, !toppings.isEmpty {
            return Customisation(pizzaId: pizzaId, sauceId: sauceId,
                                 toppings: toppings.map { PlacedTopping(id: $0.id, side: $0.side, extra: $0.extra) })
        }
        return Customisation(pizzaId: pizzaId, sauceId: sauceId, added: added.map(\.id), removed: removed.map(\.id))
    }
}

/// A pizza waiting in the basket, not yet sent.
struct CartItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let pizzaName: String
    let customisation: Customisation
    let summary: String
    let spec: PizzaSpec
}

// MARK: - Describing customisations

enum ToppingText {
    /// "BBQ sauce · + Ham · Extra Mozzarella · No Basil", or "" when unchanged.
    /// The sauce is mentioned only when it isn't the pizza's usual one (`usualSauceId`).
    static func summary(added: [ToppingRef], removed: [ToppingRef], baseIds: Set<Int>,
                        sauce: Sauce? = nil, usualSauceId: Int? = nil) -> String {
        var parts: [String] = []
        if let sauce, let usualSauceId, sauce.id != usualSauceId {
            parts.append(sauce.label)
        }
        for topping in uniqueInOrder(added) {
            parts.append(baseIds.contains(topping.id) ? "Extra \(topping.name)" : "+ \(topping.name)")
        }
        for topping in removed {
            parts.append("No \(topping.name)")
        }
        return parts.joined(separator: " · ")
    }

    /// `recipe`: the pizza's base toppings today, from the menu (nil if it's off the menu, in
    /// which case an added base topping reads "+ X" rather than "Extra X", and a pizza with
    /// changed halves is listed in full).
    static func summary(_ item: OrderItem, recipe: [BaseTopping]?, usualSauceId: Int?) -> String {
        let toppings = item.toppings ?? []
        if item.pizzaId == nil || (!toppings.isEmpty && recipe == nil) {
            return buildYourOwn(sauce: item.sauce, toppings: toppings.map { ($0.name, $0.side, $0.extra) })
        }
        if let recipe, !toppings.isEmpty {
            return changes(recipe: recipe, made: toppings.map { ($0.id, $0.name, $0.side, $0.extra) },
                           sauce: item.sauce, usualSauceId: usualSauceId)
        }
        return summary(added: item.added, removed: item.removed, baseIds: Set(recipe?.map(\.id) ?? []),
                       sauce: item.sauce, usualSauceId: usualSauceId)
    }

    static func summary(_ favourite: Favourite, recipe: [BaseTopping]?, usualSauceId: Int?) -> String {
        if favourite.pizzaId == nil {
            return buildYourOwn(sauce: favourite.sauce, toppings: (favourite.toppings ?? []).map { ($0.name, $0.side, $0.extra) })
        }
        if let toppings = favourite.toppings, !toppings.isEmpty {
            guard let recipe else {
                return buildYourOwn(sauce: favourite.sauce, toppings: toppings.map { ($0.name, $0.side, $0.extra) })
            }
            return changes(recipe: recipe, made: toppings.map { ($0.id, $0.name, $0.side, $0.extra) },
                           sauce: favourite.sauce, usualSauceId: usualSauceId)
        }
        return summary(added: favourite.added, removed: favourite.removed, baseIds: Set(recipe?.map(\.id) ?? []),
                       sauce: favourite.sauce, usualSauceId: usualSauceId)
    }

    /// A menu pizza made as `made` (every topping on it, by half) compared with its recipe:
    /// "No Basil · + Ham · Extra Mozzarella · Pepperoni: left half · + Olives (right half)",
    /// or "" when it's the recipe as it is.
    static func changes(recipe: [BaseTopping], made: [(id: Int, name: String, side: PizzaSide, extra: Bool)],
                        sauce: Sauce? = nil, usualSauceId: Int? = nil) -> String {
        var parts: [String] = []
        if let sauce, let usualSauceId, sauce.id != usualSauceId {
            parts.append(sauce.label)
        }
        let now = HalfAmounts.byTopping(made.map { ($0.id, $0.side, $0.extra) })
        var names = Dictionary(made.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for topping in recipe { names[topping.id] = topping.name }
        let was = Dictionary(uniqueKeysWithValues: recipe.map { ($0.id, $0.amounts) })
        var ids = recipe.map(\.id)
        for entry in made where !ids.contains(entry.id) { ids.append(entry.id) }
        for id in ids {
            let before = was[id] ?? HalfAmounts(), after = now[id] ?? HalfAmounts()
            guard before != after, let name = names[id] else { continue }
            if !after.isOn {
                parts.append("No \(name)")
            } else if !before.isOn {
                parts.append(after.whole == 1 ? "+ \(name)" : "+ \(name) (\(after.description.lowercased()))")
            } else if before.whole == 1 && after.whole == 2 {
                parts.append("Extra \(name)")
            } else {
                parts.append("\(name): \(after.description.lowercased())")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// "Tomato sauce · Mozzarella · Left: Pepperoni · Right: Double Mushroom"
    static func buildYourOwn(sauce: Sauce?, toppings: [(name: String, side: PizzaSide, extra: Bool)]) -> String {
        var parts: [String] = []
        if let sauce { parts.append(sauce.label) }
        let label = { (t: (name: String, side: PizzaSide, extra: Bool)) in t.extra ? "Double \(t.name)" : t.name }
        let whole = toppings.filter { $0.side == .whole }.map(label)
        let left = toppings.filter { $0.side == .left }.map(label)
        let right = toppings.filter { $0.side == .right }.map(label)
        if !whole.isEmpty { parts.append(whole.joined(separator: ", ")) }
        if !left.isEmpty { parts.append("Left: " + left.joined(separator: ", ")) }
        if !right.isEmpty { parts.append("Right: " + right.joined(separator: ", ")) }
        if toppings.isEmpty { parts.append("No toppings") }
        return parts.joined(separator: " · ")
    }

    private static func uniqueInOrder(_ toppings: [ToppingRef]) -> [ToppingRef] {
        var seen = Set<Int>()
        return toppings.filter { seen.insert($0.id).inserted }
    }
}
