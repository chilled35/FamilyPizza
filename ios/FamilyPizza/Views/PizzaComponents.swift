import SwiftUI

/// The live pizza picture at the top of the customise and build-your-own screens.
struct PizzaStage: View {
    @Environment(AppModel.self) private var model
    let spec: PizzaSpec
    var caption: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            // A soft spotlight so the pizza sits on something, in light and dark mode.
            RadialGradient(colors: [Color.orange.opacity(0.16), .clear], center: .center, startRadius: 10, endRadius: 260)
            PizzaView(spec: spec, images: model.toppingImages.images)
                .padding(.vertical, 10)
                .padding(.bottom, caption == nil ? 0 : 14)
            if let caption {
                Text(caption)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 4)
                    .contentTransition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) { Divider() }
        .animation(.default, value: caption)
    }
}

/// Lays out a screen with the pizza picture across the top 30% of the screen and `content` below it.
struct PizzaStageLayout<Content: View>: View {
    let spec: PizzaSpec
    var caption: String?
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                PizzaStage(spec: spec, caption: caption)
                    // 30% of the whole screen: this view starts below the navigation bar.
                    .frame(height: max(160, (geo.size.height + geo.safeAreaInsets.top) * 0.3))
                content
            }
        }
    }
}

/// Sauce chips, scrolling sideways. `usualId` gets a "usual" tag (menu pizzas).
struct SaucePicker: View {
    let sauces: [Sauce]
    @Binding var selection: Int?
    var usualId: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sauces) { sauce in
                    let on = selection == sauce.id
                    Button {
                        selection = sauce.id
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: sauce.colour) ?? .clear)
                                .overlay(Circle().strokeBorder(.secondary.opacity(0.5),
                                                               style: StrokeStyle(lineWidth: 1, dash: sauce.colour.isEmpty ? [3, 2] : [])))
                                .frame(width: 20, height: 20)
                            Text(sauce.name)
                            if sauce.id == usualId {
                                Text("usual").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                        .background(on ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.fill.quaternary), in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(sauce.label + (sauce.id == usualId ? ", usual" : ""))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// "Half and half" / "Left half customised" / "Right half customised" under the picture, or nil.
func halfCaption(_ placed: [PlacedTopping]) -> String? {
    let left = placed.contains { $0.side == .left }
    let right = placed.contains { $0.side == .right }
    switch (left, right) {
    case (true, true): return "Half and half"
    case (true, false): return "Left half customised"
    case (false, true): return "Right half customised"
    default: return nil
    }
}

/// How much of one topping is on each half of a pizza: 0 none, 1 normal, 2 double.
struct HalfAmounts: Hashable, Sendable {
    var left = 0
    var right = 0

    var isOn: Bool { left > 0 || right > 0 }
    /// Both halves the same and not empty: shown as "whole pizza".
    var whole: Int? { left == right && left > 0 ? left : nil }
    var hasDouble: Bool { left == 2 || right == 2 }

    /// The next amount for a tap: none → normal → double → none.
    static func next(_ amount: Int) -> Int { (amount + 1) % 3 }

    /// The reverse of `placed(id:)`: placed toppings -> amounts per topping id.
    static func byTopping(_ placed: [(id: Int, side: PizzaSide, extra: Bool)]) -> [Int: HalfAmounts] {
        var out: [Int: HalfAmounts] = [:]
        for entry in placed {
            var amounts = out[entry.id] ?? HalfAmounts()
            let amount = entry.extra ? 2 : 1
            if entry.side != .right { amounts.left = amount }
            if entry.side != .left { amounts.right = amount }
            out[entry.id] = amounts
        }
        return out
    }

    /// What the server gets: one whole entry when both halves match, else one entry per half.
    func placed(id: Int) -> [PlacedTopping] {
        if let whole { return [PlacedTopping(id: id, side: .whole, extra: whole == 2)] }
        var out: [PlacedTopping] = []
        if left > 0 { out.append(PlacedTopping(id: id, side: .left, extra: left == 2)) }
        if right > 0 { out.append(PlacedTopping(id: id, side: .right, extra: right == 2)) }
        return out
    }

    /// e.g. "Whole pizza", "Double, left half", "Double left · normal right".
    var description: String {
        func word(_ n: Int) -> String { n == 2 ? "double" : "normal" }
        if let whole { return whole == 2 ? "Double, whole pizza" : "Whole pizza" }
        switch (left, right) {
        case (0, let r): return r == 2 ? "Double, right half" : "Right half"
        case (let l, 0): return l == 2 ? "Double, left half" : "Left half"
        default: return "\(word(left).capitalized) left · \(word(right)) right"
        }
    }
}

/// Left half / whole / right half for one build-your-own topping. Each tap moves that part on:
/// none → normal → double → none. "Whole" sets both halves together (uneven halves start again
/// at normal). A double glows and carries a "2×" badge so it can't be missed.
struct SidePicker: View {
    let toppingName: String
    @Binding var amounts: HalfAmounts

    var body: some View {
        HStack(spacing: 6) {
            option(label: "Left half", symbol: "circle.lefthalf.filled",
                   amount: amounts.whole == nil ? amounts.left : 0, covered: amounts.whole != nil) {
                amounts.left = HalfAmounts.next(amounts.left)
            }
            option(label: "Whole pizza", symbol: "circle.fill", offSymbol: "circle",
                   amount: amounts.whole ?? 0, covered: false) {
                let next = amounts.whole.map(HalfAmounts.next) ?? 1
                amounts = HalfAmounts(left: next, right: next)
            }
            option(label: "Right half", symbol: "circle.righthalf.filled",
                   amount: amounts.whole == nil ? amounts.right : 0, covered: amounts.whole != nil) {
                amounts.right = HalfAmounts.next(amounts.right)
            }
        }
    }

    /// `covered`: this half is on via "whole", so it shows faintly rather than as off.
    private func option(label: String, symbol: String, offSymbol: String? = nil, amount: Int, covered: Bool,
                        tap: @escaping () -> Void) -> some View {
        let on = amount > 0
        let double = amount == 2
        let accent: Color = double ? .orange : .accentColor
        // A tap gesture rather than a Button: inside a Form row a Button drops the second of two
        // quick taps, and tap-tap for "double" is exactly what people do.
        return Image(systemName: on || covered ? symbol : (offSymbol ?? symbol))
                .font(.title2)
                .foregroundStyle(on ? AnyShapeStyle(accent) : covered ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.tertiary))
                .frame(width: 40, height: 40)
                .background(on ? AnyShapeStyle(accent.opacity(double ? 0.22 : 0.14)) : AnyShapeStyle(.clear), in: Circle())
                .overlay(Circle().strokeBorder(double ? Color.orange : .clear, lineWidth: 2))
                .shadow(color: double ? .orange.opacity(0.9) : .clear, radius: double ? 7 : 0)
                .overlay(alignment: .topTrailing) {
                    if double {
                        Text("2×")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange, in: Capsule())
                            .offset(x: 6, y: -4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .scaleEffect(double ? 1.06 : 1)
                .contentShape(Circle())
                .onTapGesture(perform: tap)
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, tap)
                .accessibilityLabel("\(toppingName), \(label)")
                .accessibilityValue(double ? "double" : on ? "normal" : covered ? "on, whole pizza" : "none")
                .accessibilityHint("Tap for normal, again for double, again to remove")
                .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A small static picture of a pizza for lists.
struct PizzaThumb: View {
    @Environment(AppModel.self) private var model
    let spec: PizzaSpec
    var size: CGFloat = 56

    var body: some View {
        PizzaView(spec: spec, images: model.toppingImages.images, showsDivider: true)
            .frame(width: size, height: size)
            .transaction { $0.animation = nil }
    }
}
