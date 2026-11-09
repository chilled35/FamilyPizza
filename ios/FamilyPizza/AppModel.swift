import Foundation
import Observation
import UIKit
import UserNotifications

enum Tab: Hashable {
    case menu, favourites, orders
}

/// All app state, plus every call to the server. One instance, owned by AppDelegate.
@MainActor
@Observable
final class AppModel {
    let uuid = DeviceIdentity.uuid()
    private(set) var api = APIClient(baseURL: Config.baseURL)

    /// First name; nil until the person has registered on this phone.
    private(set) var name: String? = UserDefaults.standard.string(forKey: "userName")

    private(set) var menu: [MenuPizza] = []
    private(set) var toppings: [ToppingInfo] = []         // active toppings, for "add" and build your own
    private(set) var sauces: [Sauce] = []                 // active sauces, usual order (Tomato first)
    let toppingImages = ToppingImages()
    /// Photo pieces for the pizza picture, from the server; empty (everything drawn) until they load.
    private(set) var pieceBook = PizzaPieceBook()
    private(set) var favourites: [Favourite] = []
    private(set) var orders: [Order] = []
    var cart: [CartItem] = []

    var selectedTab: Tab = .menu
    /// The order shown full screen in the tracker (set after checkout, or by tapping an order).
    var trackingOrderId: Int?
    /// A problem worth telling the person about (shown as an alert).
    var alertMessage: String?
    private(set) var lastRefreshError: APIError?
    private(set) var notificationsAllowed: Bool?

    private var pushToken: String?
    private var uploadedPushToken: String?

    var isRegistered: Bool { name != nil }
    var readyOrders: Int { orders.filter { $0.status == .ready }.count }
    var hasActiveOrders: Bool { orders.contains { $0.status.isActive } }

    // MARK: - Lifecycle

    /// On launch and every return to the foreground.
    func refreshAll() async {
        guard let name else { return }
        // Re-register every time: idempotent, and recreates the user if the server DB was reset.
        try? await registerOnServer(name: name)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.refreshMenu() }
            group.addTask { await self.refreshFavourites() }
            group.addTask { await self.refreshOrders() }
        }
        await refreshNotificationPermission()
    }

    func serverIsReachable() async -> Bool {
        do {
            let _: [String: String] = try await api.get("health")
            return true
        } catch {
            return false
        }
    }

    // MARK: - Identity

    /// First-launch registration, and later name changes.
    func register(name rawName: String) async throws {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        try await registerOnServer(name: trimmed)
        name = trimmed
        UserDefaults.standard.set(trimmed, forKey: "userName")
        await uploadPushTokenIfNeeded()
    }

    private func registerOnServer(name: String) async throws {
        struct Body: Encodable { let uuid: String; let name: String }
        let _: User = try await api.post("api/register", Body(uuid: uuid, name: name))
    }

    /// Runs `operation`; if the server has forgotten this phone (404), registers again and retries once.
    private func asUser<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as APIError where error.isUnknownUser {
            guard let name else { throw error }
            try await registerOnServer(name: name)
            uploadedPushToken = nil
            await uploadPushTokenIfNeeded()
            return try await operation()
        }
    }

    // MARK: - Menu

    func refreshMenu() async {
        do {
            async let pizzas: [MenuPizza] = api.get("api/menu")
            async let extras: [ToppingInfo] = api.get("api/toppings")
            async let sauceList: [Sauce] = api.get("api/sauces")
            (menu, toppings, sauces) = try await (pizzas, extras, sauceList)
            lastRefreshError = nil
        } catch let error as APIError {
            lastRefreshError = error
            return
        } catch {
            return
        }
        // Photos arrive a moment later; drawings stand in until then.
        let all: [any ToppingPictured] = toppings + menu.flatMap(\.toppings)
        pieceBook = ToppingPieces.book(for: all, server: toppingImages.pieces)
        await toppingImages.load(all, baseURL: api.baseURL)
        // Each topping's pieces (seeded on the server, changed by the owner in /admin).
        pieceBook = ToppingPieces.book(for: all, server: toppingImages.pieces)
    }

    /// Any topping the app knows about (active extras and menu base toppings, including run-out ones).
    func toppingInfo(id: Int) -> (any ToppingPictured)? {
        if let t = toppings.first(where: { $0.id == id }) { return t }
        for pizza in menu { if let t = pizza.toppings.first(where: { $0.id == id }) { return t } }
        return nil
    }

    func toppingStyle(id: Int) -> ToppingStyle { toppingInfo(id: id)?.artStyle ?? .generic }

    func sauce(id: Int?) -> Sauce? { id.flatMap { id in sauces.first { $0.id == id } } }

    // MARK: - Pictures

    /// What a menu pizza looks like with `customisation` applied.
    func spec(pizza: MenuPizza, customisation c: Customisation) -> PizzaSpec {
        let sauce = sauce(id: c.sauceId) ?? pizza.sauce
        if !c.toppings.isEmpty {  // the whole pizza, halves included
            return PizzaSpec(sauceHex: sauce?.colour, layers: c.toppings.map {
                PizzaLayer(toppingId: $0.id, style: toppingStyle(id: $0.id), side: $0.side, extra: $0.extra)
            })
        }
        var layers: [PizzaLayer] = []
        let removed = Set(c.removed)
        let added = c.added
        for topping in pizza.toppings where topping.active && !removed.contains(topping.id) {
            var amounts = topping.amounts
            if added.contains(topping.id) {  // "extra": double wherever the recipe puts it
                amounts = HalfAmounts(left: amounts.left > 0 ? 2 : 0, right: amounts.right > 0 ? 2 : 0)
            }
            layers += amounts.placed(id: topping.id).map {
                PizzaLayer(toppingId: topping.id, style: topping.artStyle, side: $0.side, extra: $0.extra)
            }
        }
        let baseIds = Set(pizza.toppings.map(\.id))
        for id in added where !baseIds.contains(id) {
            layers.append(PizzaLayer(toppingId: id, style: toppingStyle(id: id)))
        }
        return PizzaSpec(sauceHex: sauce?.colour, layers: layers)
    }

    func spec(buildYourOwn c: Customisation) -> PizzaSpec {
        PizzaSpec(sauceHex: sauce(id: c.sauceId)?.colour,
                  layers: c.toppings.map { PizzaLayer(toppingId: $0.id, style: toppingStyle(id: $0.id), side: $0.side, extra: $0.extra) })
    }

    /// The picture for a pizza in an order (menu pizzas use today's recipe).
    func spec(for item: OrderItem) -> PizzaSpec {
        if item.pizzaId == nil {
            return PizzaSpec(sauceHex: item.sauce?.colour, layers: (item.toppings ?? []).map {
                PizzaLayer(toppingId: $0.id, style: toppingStyle(id: $0.id), side: $0.side, extra: $0.extra)
            })
        }
        if let toppings = item.toppings, !toppings.isEmpty {  // halves changed: drawn as ordered
            return PizzaSpec(sauceHex: item.sauce?.colour ?? pizza(id: item.pizzaId ?? -1)?.sauce?.colour,
                             layers: toppings.map {
                PizzaLayer(toppingId: $0.id, style: toppingStyle(id: $0.id), side: $0.side, extra: $0.extra)
            })
        }
        let customisation = Customisation(pizzaId: item.pizzaId, sauceId: item.sauce?.id,
                                          added: item.added.map(\.id), removed: item.removed.map(\.id))
        if let pizza = item.pizzaId.flatMap(pizza(id:)) {
            var spec = spec(pizza: pizza, customisation: customisation)
            if let sauce = item.sauce { spec.sauceHex = sauce.colour }
            return spec
        }
        return PizzaSpec(sauceHex: item.sauce?.colour ?? "#b5321e",
                         layers: item.added.map { PizzaLayer(toppingId: $0.id, style: toppingStyle(id: $0.id)) })
    }

    func pizza(id: Int) -> MenuPizza? { menu.first { $0.id == id } }

    // MARK: - Basket and orders

    func addToCart(pizza: MenuPizza, customisation: Customisation, name: String? = nil) {
        let baseIds = Set(pizza.toppings.map(\.id))
        let names = Dictionary((pizza.toppings.map { ToppingRef(id: $0.id, name: $0.name) }
                                + toppings.map { ToppingRef(id: $0.id, name: $0.name) })
            .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sauce = sauce(id: customisation.sauceId)
        let summary = customisation.toppings.isEmpty
            ? ToppingText.summary(
                added: customisation.added.compactMap { names[$0] },
                removed: customisation.removed.compactMap { names[$0] },
                baseIds: baseIds, sauce: sauce, usualSauceId: pizza.sauce?.id)
            : ToppingText.changes(
                recipe: pizza.toppings,
                made: customisation.toppings.map { ($0.id, names[$0.id]?.name ?? "?", $0.side, $0.extra) },
                sauce: sauce, usualSauceId: pizza.sauce?.id)
        cart.append(CartItem(pizzaName: name ?? pizza.name, customisation: customisation, summary: summary,
                             spec: spec(pizza: pizza, customisation: customisation)))
    }

    func addToCart(buildYourOwn customisation: Customisation, name: String = "Build your own") {
        let summary = ToppingText.buildYourOwn(
            sauce: sauce(id: customisation.sauceId),
            toppings: customisation.toppings.map { (toppingInfo(id: $0.id)?.name ?? "?", $0.side, $0.extra) })
        cart.append(CartItem(pizzaName: name, customisation: customisation, summary: summary,
                             spec: spec(buildYourOwn: customisation)))
    }

    /// Why a favourite can't be ordered right now, or nil if it can.
    /// Base toppings that have run out are not a problem: they're left off (see `orderable`).
    func problem(with favourite: Favourite) -> String? {
        if favourite.pizzaId == nil {  // build your own: everything on it must be available
            guard !toppings.isEmpty || !sauces.isEmpty else { return nil }  // menu not loaded yet
            let active = Set(toppings.map(\.id))
            if let missing = (favourite.toppings ?? []).first(where: { !active.contains($0.id) }) {
                return "\(missing.name) has run out"
            }
            if let sauce = favourite.sauce, !sauces.contains(where: { $0.id == sauce.id }) {
                return "\(sauce.label) has run out"
            }
            return nil
        }
        guard let pizza = favourite.pizzaId.flatMap(pizza(id:)) else {
            return menu.isEmpty ? nil : "\(favourite.pizzaName) is off the menu"
        }
        let base = Dictionary(uniqueKeysWithValues: pizza.toppings.map { ($0.id, $0) })
        let activeExtras = Set(toppings.map(\.id))
        if let saved = favourite.toppings, !saved.isEmpty {
            // Made exactly as saved: a run-out base topping is left off, anything else must be on.
            if let missing = saved.first(where: { base[$0.id] == nil && !activeExtras.contains($0.id) }) {
                return "\(missing.name) has run out"
            }
        } else {
            if let missing = favourite.added.first(where: { topping in
                base[topping.id].map { !$0.active } ?? !activeExtras.contains(topping.id)
            }) {
                return "\(missing.name) has run out"
            }
            if let gone = favourite.removed.first(where: { base[$0.id] == nil }) {
                return "\(pizza.name) no longer comes with \(gone.name)"
            }
        }
        if let sauce = favourite.sauce, !sauces.isEmpty, !sauces.contains(where: { $0.id == sauce.id }) {
            return "\(sauce.label) has run out"
        }
        return nil
    }

    /// Base toppings of the favourite's pizza that have run out and will be left off.
    func runOut(for favourite: Favourite) -> [BaseTopping] {
        let base = favourite.pizzaId.flatMap(pizza(id:))?.toppings ?? []
        if let saved = favourite.toppings, !saved.isEmpty {
            let on = Set(saved.map(\.id))
            return base.filter { !$0.active && on.contains($0.id) }
        }
        let removed = Set(favourite.removed.map(\.id))
        return base.filter { !$0.active && !removed.contains($0.id) }
    }

    /// Adds a favourite as it can be made today (run-out base toppings left off).
    /// Returns the confirmation to show.
    func addToCart(favourite: Favourite) -> String {
        if favourite.pizzaId == nil {
            if let problem = problem(with: favourite) { return problem }
            let label = favourite.label == "Build your own" ? favourite.label : "\(favourite.label) (Build your own)"
            addToCart(buildYourOwn: favourite.customisation, name: label)
            return "\(favourite.label) added to your basket"
        }
        guard problem(with: favourite) == nil, let pizza = favourite.pizzaId.flatMap(pizza(id:)) else {
            return problem(with: favourite) ?? "Can't add that right now"
        }
        var customisation = favourite.customisation
        let leftOff = runOut(for: favourite)
        if customisation.toppings.isEmpty {
            customisation.removed += leftOff.map(\.id)
        } else {
            let gone = Set(leftOff.map(\.id))
            customisation.toppings.removeAll { gone.contains($0.id) }
        }
        let label = favourite.label == pizza.name ? pizza.name : "\(favourite.label) (\(pizza.name))"
        addToCart(pizza: pizza, customisation: customisation, name: label)
        if leftOff.isEmpty {
            return "\(favourite.label) added to your basket"
        }
        return "Added, without \(leftOff.map(\.name).formatted(.list(type: .and))) (run out)"
    }

    func placeOrder(note: String) async throws {
        struct Body: Encodable { let uuid: String; let items: [Customisation]; let note: String }
        let body = Body(uuid: uuid, items: cart.map(\.customisation),
                        note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let order: Order = try await asUser { try await api.post("api/orders", body) }
            cart.removeAll()
            orders.insert(order, at: 0)
            selectedTab = .orders
            trackingOrderId = order.id
        } catch let error as APIError where error.isConflict {
            await refreshMenu()
            throw APIError(status: 409, message: "\(error.message)\n\nThe menu has been refreshed. Please check your pizzas and try again.")
        }
    }

    func refreshOrders() async {
        guard isRegistered else { return }
        do {
            orders = try await asUser { try await api.get("api/orders", query: ["uuid": uuid]) }
            lastRefreshError = nil
        } catch let error as APIError {
            lastRefreshError = error
        } catch {}
    }

    func order(id: Int) -> Order? { orders.first { $0.id == id } }

    /// Live updates for one order (the tracker). Ends after "collected"; throws if the line drops.
    func orderUpdates(id: Int) -> AsyncThrowingStream<Order, Error> {
        api.events("api/orders/\(id)/stream", query: ["uuid": uuid], as: Order.self)
    }

    func update(_ order: Order) {
        if let index = orders.firstIndex(where: { $0.id == order.id }) {
            orders[index] = order
        } else {
            orders.insert(order, at: 0)
        }
    }

    // MARK: - Favourites

    func refreshFavourites() async {
        guard isRegistered else { return }
        do {
            favourites = try await asUser { try await api.get("api/favourites", query: ["uuid": uuid]) }
        } catch let error as APIError {
            lastRefreshError = error
        } catch {}
    }

    func saveFavourite(label: String, customisation: Customisation) async throws {
        struct Body: Encodable {
            let uuid: String; let label: String
            let pizzaId: Int?  // nil (left out) = build your own, needs server v0.9+
            let sauceId: Int?; let added: [Int]; let removed: [Int]
            let toppings: [PlacedTopping]?  // nil is left out, for servers older than v0.8
        }
        let body = Body(uuid: uuid, label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                        pizzaId: customisation.pizzaId, sauceId: customisation.sauceId,
                        added: customisation.added, removed: customisation.removed,
                        toppings: customisation.toppings.isEmpty ? nil : customisation.toppings)
        do {
            let saved: Favourite = try await asUser { try await api.post("api/favourites", body) }
            favourites.append(saved)
            favourites.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        } catch let error as APIError where error.isConflict {
            throw APIError(status: 409, message: customisation.pizzaId == nil
                ? "You already have a build-your-own favourite called “\(body.label)”."
                : "You already have a favourite called “\(body.label)” for this pizza.")
        }
    }

    // MARK: - Menu suggestions

    /// Sends a build-your-own pizza to the owner as an idea for the menu (server v0.9+).
    func suggestForMenu(name: String, customisation: Customisation) async throws {
        struct Body: Encodable { let uuid: String; let name: String; let sauceId: Int; let toppings: [PlacedTopping] }
        struct Sent: Decodable { let id: Int }
        guard let sauceId = customisation.sauceId else { return }
        let body = Body(uuid: uuid, name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)),
                        sauceId: sauceId, toppings: customisation.toppings)
        let _: Sent = try await asUser { try await api.post("api/suggestions", body) }
    }

    func deleteFavourite(_ favourite: Favourite) async {
        favourites.removeAll { $0.id == favourite.id }
        do {
            try await asUser {
                try await api.call("DELETE", "api/favourites/\(favourite.id)", query: ["uuid": uuid])
            }
        } catch let error as APIError where error.status == 404 {
            // Already gone.
        } catch {
            alertMessage = (error as? APIError)?.message ?? error.localizedDescription
            await refreshFavourites()
        }
    }

    // MARK: - Push notifications

    /// Ask once, after registration. Afterwards iOS remembers the answer.
    func requestNotificationPermission() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        notificationsAllowed = granted
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func refreshNotificationPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationsAllowed = true
            UIApplication.shared.registerForRemoteNotifications()  // iOS hands back the (maybe new) token
        case .denied:
            notificationsAllowed = false
        case .notDetermined:
            notificationsAllowed = nil
        @unknown default:
            notificationsAllowed = nil
        }
    }

    func didReceivePushToken(_ token: Data) async {
        pushToken = token.map { String(format: "%02x", $0) }.joined()
        await uploadPushTokenIfNeeded()
    }

    private func uploadPushTokenIfNeeded() async {
        guard isRegistered, let pushToken, pushToken != uploadedPushToken else { return }
        struct Body: Encodable { let uuid: String; let apnsToken: String; let environment: String }
        let body = Body(uuid: uuid, apnsToken: pushToken, environment: Config.apnsEnvironment)
        do {
            try await api.call("POST", "api/devices", body: body)
            uploadedPushToken = pushToken
        } catch {
            // Retried on the next launch / foreground.
            print("Uploading push token failed: \(error.localizedDescription)")
        }
    }

    /// A push arrived (in the foreground) or was tapped: show the order.
    func handlePush(tapped: Bool, orderId: Int? = nil) async {
        if tapped {
            selectedTab = .orders
            if let orderId { trackingOrderId = orderId }
        }
        await refreshOrders()
    }
}
