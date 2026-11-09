import SwiftUI

/// Photo pieces of each topping, scattered on the pizza picture in place of the drawn ones.
///
/// They all come from the server: each topping's `pieceUrls`, fetched by ToppingImages. The
/// server is seeded from the photos in "Food Images/" (ios/tools/seed_server_pieces.py) and the
/// owner adds or changes a topping's pieces in /admin. Until they arrive (and for a topping
/// with none) the picture draws that topping instead.
@MainActor
enum ToppingPieces {
    /// `server` holds each topping's pieces, by topping id. A style also takes the pieces of
    /// its first topping (in `toppings` order) that has some: that draws toppings the menu no
    /// longer lists (old orders) and the splash pizza.
    static func book(for toppings: [any ToppingPictured], server: [Int: [Image]]) -> PizzaPieceBook {
        var book = PizzaPieceBook()
        for topping in toppings {
            guard let found = server[topping.id], !found.isEmpty else { continue }
            book.byTopping[topping.id] = found
            let style = topping.artStyle
            if style != .generic, style != .cheese, book.byStyle[style] == nil { book.byStyle[style] = found }
        }
        return book
    }
}
