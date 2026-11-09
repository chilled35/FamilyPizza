import SwiftUI
import UIKit

/// Photo pieces of each topping (Assets.xcassets/Toppings, cut by ios/tools/cut_toppings.py),
/// scattered on the pizza picture in place of the drawn ones.
///
/// Assets are named `piece-<set>-<nn>`, numbered from 01. A topping's set comes from its name
/// first (so "Harissa Chicken" gets harissa chicken, and a "Basil" left as style "generic" on the
/// server still gets basil leaves), then from its style.
@MainActor
enum ToppingPieces {
    private static var cache: [String: [Image]] = [:]

    /// Every set for every style, plus the toppings the app knows by id.
    static func book(for toppings: [any ToppingPictured]) -> PizzaPieceBook {
        var book = PizzaPieceBook()
        for style in ToppingStyle.allCases {
            let found = sets(for: style).flatMap(images(inSet:))
            if !found.isEmpty { book.byStyle[style] = found }
        }
        for topping in toppings {
            let found = sets(name: topping.name, style: topping.artStyle).flatMap(images(inSet:))
            if !found.isEmpty { book.byTopping[topping.id] = found }
        }
        return book
    }

    /// Name words checked in order, like guess_style in server/main.py (first match wins).
    private static let nameWords: [(word: String, sets: [String])] = [
        ("harissa", ["chicken-harissa"]), ("chipotle", ["chicken-chipotle"]), ("chipolte", ["chicken-chipotle"]),
        ("chicken", ["chicken-chipotle", "chicken-harissa"]),
        ("pepperoni", ["pepperoni"]), ("salami", ["pepperoni"]), ("chorizo", ["pepperoni"]),
        ("ham", ["ham"]), ("bacon", ["ham"]),
        ("mushroom", ["mushroom"]), ("onion", ["onion"]), ("pineapple", ["pineapple"]),
        ("chilli", ["chilli"]), ("chili", ["chilli"]), ("jalape", ["chilli"]),
        ("pepper", ["pepper"]), ("olive", ["olive"]),
        ("basil", ["basil"]), ("spinach", ["basil"]), ("rocket", ["basil"]),
        ("sweetcorn", ["sweetcorn"]), ("corn", ["sweetcorn"]),
        ("tomato", ["tomato"]), ("sausage", ["sausage"]), ("meatball", ["sausage"]),
    ]

    private static func sets(name: String, style: ToppingStyle) -> [String] {
        let lower = name.lowercased()
        // The owner's chosen style wins over a name guess, except to tell the chickens apart.
        if style != .generic && style != .chicken { return sets(for: style) }
        return nameWords.first { lower.contains($0.word) }?.sets ?? sets(for: style)
    }

    private static func sets(for style: ToppingStyle) -> [String] {
        switch style {
        case .chicken: ["chicken-chipotle", "chicken-harissa"]
        case .cheese, .generic: []  // cheese is drawn melted; generic has no pieces
        default: [style.rawValue]
        }
    }

    private static func images(inSet set: String) -> [Image] {
        if let cached = cache[set] { return cached }
        var found: [Image] = []
        for n in 1...99 {
            let name = String(format: "piece-%@-%02d", set, n)
            guard let image = UIImage(named: name) else { break }
            found.append(Image(uiImage: image))
        }
        cache[set] = found
        return found
    }
}
