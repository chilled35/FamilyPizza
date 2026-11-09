import SwiftUI

// Draws pizzas and toppings with SwiftUI Canvas: shaded, textured, seeded so pieces stay put.
// Pure SwiftUI (no UIKit) so ios/tools/make_icon.swift can compile it on macOS for the app icon.

/// How a topping is drawn. Raw values match `TOPPING_STYLES` in server/main.py.
enum ToppingStyle: String, CaseIterable, Sendable {
    case cheese, pepperoni, ham, mushroom, onion, pepper, pineapple, chilli,
         olive, basil, sweetcorn, tomato, sausage, chicken, generic

    init(serverValue: String?) {
        self = serverValue.flatMap(ToppingStyle.init(rawValue:)) ?? .generic
    }
}

/// Where a topping goes on a build-your-own pizza.
enum PizzaSide: String, Codable, CaseIterable, Hashable, Sendable {
    case left, whole, right
}

/// One topping on the picture.
struct PizzaLayer: Hashable, Identifiable, Sendable {
    let toppingId: Int
    let style: ToppingStyle
    var side: PizzaSide = .whole
    var extra = false

    var id: String { "\(toppingId)-\(side.rawValue)-\(extra)" }
    /// Which topping on which part of the pizza; "extra" changes the amount, not the slot.
    var slot: String { "\(toppingId)-\(side.rawValue)" }
}

/// Photo pieces to scatter in place of the drawn ones, filled in by the app
/// (ToppingPieces.swift). Empty, as in the icon tool, means everything is drawn.
struct PizzaPieceBook: Sendable {
    var byTopping: [Int: [Image]] = [:]
    var byStyle: [ToppingStyle: [Image]] = [:]

    func pieces(for layer: PizzaLayer) -> [Image] {
        layer.style == .cheese ? [] : byTopping[layer.toppingId] ?? byStyle[layer.style] ?? []
    }
}

extension EnvironmentValues {
    @Entry var pizzaPieces = PizzaPieceBook()
}

/// Everything the picture needs.
struct PizzaSpec: Hashable, Sendable {
    /// "#rrggbb"; nil or "" = no sauce (bare dough).
    var sauceHex: String?
    var layers: [PizzaLayer] = []

    var isHalfAndHalf: Bool { layers.contains { $0.side != .whole } }
}

// MARK: - Views

/// A whole pizza, top-down. Toppings animate in and out as `spec` changes.
struct PizzaView: View {
    let spec: PizzaSpec
    /// Photos by topping id; only used for `.generic` toppings (an owner-added topping
    /// the app has no drawing for is shown as little discs of its photo).
    var images: [Int: Image] = [:]
    var showsDivider = true
    /// Toppings added while the picture is on screen fall onto it piece by piece, as if dropped
    /// by hand (the live picture on the customise and build-your-own screens).
    var dropsToppings = false

    @Environment(\.pizzaPieces) private var pieceBook
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        // Cheese melts under everything else.
        let ordered = spec.layers.filter { $0.style == .cheese } + spec.layers.filter { $0.style != .cheese }
        let drops = dropsToppings && appeared && !reduceMotion
        ZStack {
            PizzaBase(sauceHex: spec.sauceHex)
                .id(spec.sauceHex ?? "")
                .transition(.opacity)
            ForEach(ordered, id: \.slot) { layer in
                let falls = drops && layer.style != .cheese
                ToppingLayerView(layer: layer, image: images[layer.toppingId],
                                 pieces: pieceBook.pieces(for: layer), dropsNewPieces: falls)
                    .transition(falls ? .asymmetric(insertion: .identity, removal: .opacity)
                                      : .scale(scale: 1.18).combined(with: .opacity))
            }
            if showsDivider && spec.isHalfAndHalf {
                HalfDivider().transition(.opacity)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(.spring(duration: 0.45, bounce: 0.25), value: spec)
        .accessibilityHidden(true)
        .drawingGroup()
        .onAppear { appeared = true }  // toppings already there when it appears don't fall
    }
}

/// Crust, dough and sauce.
struct PizzaBase: View, Equatable {
    let sauceHex: String?

    var body: some View {
        Canvas { ctx, size in
            let g = Geometry(size)
            var rng = SeededRandom(seed: 0xC0FFEE)
            PizzaPainter.crust(&ctx, g, &rng)
            if let sauce = Color(hex: sauceHex) {
                PizzaPainter.sauce(&ctx, g, colour: sauce, hex: sauceHex ?? "", &rng)
            } else {
                PizzaPainter.bareDough(&ctx, g, &rng)
            }
        }
    }
}

struct ToppingLayerView: View {
    let layer: PizzaLayer
    let image: Image?
    var pieces: [Image] = []
    /// Pieces that weren't on the pizza at the last update fall in (a new topping, or "extra").
    var dropsNewPieces = false

    @State private var clock = DropClock()
    @State private var settledAt: Date?

    var body: some View {
        let _ = settledAt  // read, so landing re-renders
        let now = Date()
        let drops = clock.note(count: PizzaPainter.pieceCount(layer), falls: dropsNewPieces, now: now)
        let landed = drops.landingTime
        TimelineView(.animation(paused: landed.map { $0 <= now } ?? true)) { timeline in
            Canvas { ctx, size in
                let g = Geometry(size)
                PizzaPainter.layer(&ctx, g, layer, image: image.map { ctx.resolve($0) },
                                   pieces: pieces.map { ctx.resolve($0) }, drops: drops, now: timeline.date)
            }
        }
        // Re-render once everything has landed, which pauses the timeline.
        .task(id: landed) {
            guard let landed, landed > .now else { return }
            try? await Task.sleep(for: .seconds(landed.timeIntervalSinceNow + 0.05))
            if !Task.isCancelled { settledAt = landed }
        }
    }
}

/// When each batch of a layer's pieces started falling. A reference type kept in `@State`, so
/// `body` can note a new piece count in the same update that draws it (no frame where the new
/// pieces sit on the pizza before they fall).
@MainActor
final class DropClock {
    private var known: Int?
    private var batches: [PieceDrops.Batch] = []

    func note(count: Int, falls: Bool, now: Date) -> PieceDrops {
        batches.removeAll { $0.start + PieceDrops.duration < now }
        // A layer that arrives while drops are on starts from nothing, so all its pieces fall.
        let before = known ?? (falls ? 0 : count)
        if count > before, falls {
            batches.append(.init(pieces: before..<count, start: now))
        }
        batches = batches.compactMap { b in
            let kept = b.pieces.clamped(to: 0..<count)
            return kept.isEmpty ? nil : .init(pieces: kept, start: b.start)
        }
        known = count
        return PieceDrops(batches: batches)
    }
}

/// The pieces of a layer still falling or settling.
struct PieceDrops: Sendable {
    struct Batch: Sendable {
        let pieces: Range<Int>
        let start: Date
    }

    /// From the first piece leaving the hand to the last one settling.
    static let spread: TimeInterval = 0.5
    static let fall: TimeInterval = 0.3
    static let settle: TimeInterval = 0.16
    static let duration = spread + fall + settle

    var batches: [Batch] = []

    var landingTime: Date? { batches.map { $0.start + Self.duration }.max() }

    /// Seconds since piece `index` started falling (negative: not dropped yet); nil if it isn't falling.
    func elapsed(_ index: Int, delay: TimeInterval, now: Date) -> TimeInterval? {
        guard let batch = batches.last(where: { $0.pieces.contains(index) }) else { return nil }
        let t = now.timeIntervalSince(batch.start) - delay * Self.spread * min(1, Double(batch.pieces.count) / 8)
        return t >= Self.fall + Self.settle ? nil : t
    }
}

private struct HalfDivider: View {
    var body: some View {
        Canvas { ctx, size in
            let g = Geometry(size)
            var path = Path()
            path.move(to: CGPoint(x: g.c.x, y: g.c.y - g.r * 0.86))
            path.addLine(to: CGPoint(x: g.c.x, y: g.c.y + g.r * 0.86))
            ctx.stroke(path, with: .color(.white.opacity(0.55)),
                       style: StrokeStyle(lineWidth: max(1, g.r * 0.012), lineCap: .round, dash: [g.r * 0.04, g.r * 0.035]))
        }
    }
}

/// A small topping picture for lists, drawn when the owner hasn't uploaded a photo.
struct ToppingArtIcon: View {
    let style: ToppingStyle
    let seed: Int

    var body: some View {
        Canvas { ctx, size in
            let g = Geometry(size)
            PizzaPainter.icon(&ctx, g, style: style, seed: seed)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: - Geometry and randomness

struct Geometry {
    let c: CGPoint
    /// Pizza radius.
    let r: CGFloat

    init(_ size: CGSize) {
        c = CGPoint(x: size.width / 2, y: size.height / 2)
        r = min(size.width, size.height) / 2 * 0.98
    }

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * r, y: c.y + y * r) }
}

/// SplitMix64: the same seed always gives the same pizza.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: Int) { state = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
    mutating func range(_ r: ClosedRange<CGFloat>) -> CGFloat { r.lowerBound + unit() * (r.upperBound - r.lowerBound) }
    mutating func angle() -> Angle { .radians(Double(unit()) * 2 * .pi) }
}

extension Color {
    /// "#rrggbb" (or "rrggbb"); nil for nil, "" or anything malformed.
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    fileprivate init(_ hex: UInt32, _ opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

// MARK: - Painting

enum PizzaPainter {
    /// A closed, slightly wobbly circle (nothing hand-made is perfectly round).
    static func wobblyCircle(center: CGPoint, radius: CGFloat, wobble: CGFloat, _ rng: inout SeededRandom,
                             points: Int = 96) -> Path {
        let harmonics: [(k: Double, a: CGFloat, phase: Double)] = [
            (3, wobble * 0.5, Double(rng.unit()) * 6.28), (5, wobble * 0.3, Double(rng.unit()) * 6.28),
            (9, wobble * 0.15, Double(rng.unit()) * 6.28), (17, wobble * 0.08, Double(rng.unit()) * 6.28),
        ]
        var path = Path()
        for i in 0...points {
            let t = Double(i) / Double(points) * 2 * .pi
            var rr = radius
            for h in harmonics { rr += radius * h.a * CGFloat(sin(h.k * t + h.phase)) }
            let p = CGPoint(x: center.x + rr * CGFloat(cos(t)), y: center.y + rr * CGFloat(sin(t)))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    /// An irregular blob of `n` points, smoothed with quadratic curves.
    static func blob(radius: CGFloat, irregularity: CGFloat, n: Int = 8, _ rng: inout SeededRandom,
                     squash: CGFloat = 1) -> Path {
        var pts: [CGPoint] = []
        for i in 0..<n {
            let t = Double(i) / Double(n) * 2 * .pi
            let rr = radius * (1 + rng.range(-irregularity...irregularity))
            pts.append(CGPoint(x: rr * CGFloat(cos(t)), y: rr * CGFloat(sin(t)) * squash))
        }
        var path = Path()
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(pts[n - 1], pts[0]))
        for i in 0..<n { path.addQuadCurve(to: mid(pts[i], pts[(i + 1) % n]), control: pts[i]) }
        path.closeSubpath()
        return path
    }

    static func disc(_ radius: CGFloat, at p: CGPoint = .zero) -> Path {
        Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
    }

    static func radial(_ colours: [Color], center: CGPoint = .zero, radius: CGFloat) -> GraphicsContext.Shading {
        .radialGradient(Gradient(colors: colours), center: center, startRadius: 0, endRadius: radius)
    }

    // MARK: Base

    static func crust(_ ctx: inout GraphicsContext, _ g: Geometry, _ rng: inout SeededRandom) {
        let outer = wobblyCircle(center: g.c, radius: g.r * 0.985, wobble: 0.012, &rng)
        // Soft shadow under the pizza.
        ctx.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.28), radius: g.r * 0.035, x: 0, y: g.r * 0.02))
            l.fill(outer, with: .color(Color(0xC98B45)))
        }
        // Baked rim: pale inside, golden, browned at the outer edge.
        ctx.fill(outer, with: .radialGradient(
            Gradient(stops: [.init(color: Color(0xF0CE8E), location: 0.80), .init(color: Color(0xE2AE62), location: 0.88),
                             .init(color: Color(0xC88640), location: 0.95), .init(color: Color(0x9A5E26), location: 1)]),
            center: g.c, startRadius: 0, endRadius: g.r))
        // Highlight along the top of the rim, shade along the bottom (light from top-left).
        ctx.drawLayer { l in
            l.clip(to: outer)
            l.fill(Path(CGRect(x: 0, y: 0, width: g.c.x * 2, height: g.c.y * 2)), with: .linearGradient(
                Gradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.14)]),
                startPoint: g.point(-0.7, -0.7), endPoint: g.point(0.7, 0.7)))
        }
        // Char spots and blisters on the rim.
        ctx.drawLayer { l in
            l.clip(to: outer)
            l.addFilter(.blur(radius: g.r * 0.008))
            for _ in 0..<46 {
                let a = rng.unit() * 2 * .pi
                let d = g.r * rng.range(0.875...0.975)
                let p = CGPoint(x: g.c.x + d * cos(a), y: g.c.y + d * sin(a))
                let s = g.r * rng.range(0.008...0.03)
                let dark = rng.unit() < 0.6
                var spot = l
                spot.translateBy(x: p.x, y: p.y)
                spot.rotate(by: .radians(Double(a)))
                spot.fill(Path(ellipseIn: CGRect(x: -s * 1.6, y: -s, width: s * 3.2, height: s * 2)),
                          with: .color(dark ? Color(0x5A3416, Double(rng.range(0.15...0.4)))
                                            : Color(0xFFF1D0, Double(rng.range(0.25...0.5)))))
            }
        }
        // Flour dusting.
        for _ in 0..<60 {
            let a = rng.unit() * 2 * .pi
            let d = g.r * rng.range(0.86...0.98)
            ctx.fill(disc(g.r * rng.range(0.002...0.005), at: CGPoint(x: g.c.x + d * cos(a), y: g.c.y + d * sin(a))),
                     with: .color(.white.opacity(0.5)))
        }
    }

    static func sauce(_ ctx: inout GraphicsContext, _ g: Geometry, colour: Color, hex: String, _ rng: inout SeededRandom) {
        let edge = wobblyCircle(center: g.c, radius: g.r * 0.845, wobble: 0.03, &rng, points: 140)
        // Where sauce meets crust the dough puffs up: a soft dark line.
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: g.r * 0.012))
            l.stroke(edge, with: .color(Color(0x6B3E1A, 0.45)), lineWidth: g.r * 0.02)
        }
        ctx.fill(edge, with: .color(colour))
        ctx.drawLayer { l in
            l.clip(to: edge)
            // Thinner at the edge, pooled in the middle.
            l.fill(edge, with: radial([.clear, .clear, .black.opacity(0.22)], center: g.c, radius: g.r * 0.86))
            // Texture: darker and lighter flecks.
            l.addFilter(.blur(radius: g.r * 0.004))
            for _ in 0..<140 {
                let p = g.point(rng.range(-0.85...0.85), rng.range(-0.85...0.85))
                let s = g.r * rng.range(0.004...0.016)
                l.fill(disc(s, at: p), with: .color(rng.unit() < 0.5 ? .black.opacity(0.14) : .white.opacity(0.10)))
            }
        }
        // Herb flecks in tomato, garlic & herb and pesto; none in BBQ.
        let herby = !hex.lowercased().hasPrefix("#5a1d")
        if herby {
            ctx.drawLayer { l in
                l.clip(to: edge)
                for _ in 0..<70 {
                    let p = g.point(rng.range(-0.8...0.8), rng.range(-0.8...0.8))
                    var f = l
                    f.translateBy(x: p.x, y: p.y)
                    f.rotate(by: rng.angle())
                    let s = g.r * rng.range(0.005...0.011)
                    f.fill(Path(ellipseIn: CGRect(x: -s * 1.8, y: -s * 0.7, width: s * 3.6, height: s * 1.4)),
                           with: .color(Color(0x2F5A1B, 0.75)))
                }
            }
        }
        // Gloss.
        ctx.drawLayer { l in
            l.clip(to: edge)
            l.fill(edge, with: radial([.white.opacity(0.18), .clear], center: g.point(-0.35, -0.4), radius: g.r * 0.7))
        }
    }

    static func bareDough(_ ctx: inout GraphicsContext, _ g: Geometry, _ rng: inout SeededRandom) {
        let edge = wobblyCircle(center: g.c, radius: g.r * 0.845, wobble: 0.025, &rng)
        ctx.fill(edge, with: radial([Color(0xF3DCA8), Color(0xE9C584)], center: g.c, radius: g.r * 0.85))
        ctx.drawLayer { l in
            l.clip(to: edge)
            l.addFilter(.blur(radius: g.r * 0.006))
            for _ in 0..<60 {
                let p = g.point(rng.range(-0.8...0.8), rng.range(-0.8...0.8))
                l.fill(disc(g.r * rng.range(0.006...0.02), at: p), with: .color(Color(0xC9944F, 0.35)))
            }
            // Olive-oil sheen.
            l.fill(edge, with: radial([.white.opacity(0.22), .clear], center: g.point(-0.3, -0.35), radius: g.r * 0.6))
        }
    }

    // MARK: Toppings

    struct Recipe {
        let size: CGFloat      // piece radius, as a fraction of the pizza radius
        let count: Int         // pieces on a whole pizza
        let spacing: CGFloat   // minimum gap between centres, in piece radii
    }

    static func recipe(_ style: ToppingStyle) -> Recipe {
        switch style {
        case .cheese: Recipe(size: 0.15, count: 90, spacing: 0)
        case .pepperoni: Recipe(size: 0.105, count: 13, spacing: 1.7)
        case .ham: Recipe(size: 0.075, count: 16, spacing: 1.5)
        case .mushroom: Recipe(size: 0.075, count: 12, spacing: 1.7)
        case .onion: Recipe(size: 0.085, count: 11, spacing: 1.2)
        case .pepper: Recipe(size: 0.06, count: 15, spacing: 1.4)
        case .pineapple: Recipe(size: 0.06, count: 15, spacing: 1.6)
        case .chilli: Recipe(size: 0.04, count: 18, spacing: 1.8)
        case .olive: Recipe(size: 0.042, count: 16, spacing: 2)
        case .basil: Recipe(size: 0.085, count: 7, spacing: 2)
        case .sweetcorn: Recipe(size: 0.026, count: 48, spacing: 1.6)
        case .tomato: Recipe(size: 0.1, count: 8, spacing: 1.8)
        case .sausage: Recipe(size: 0.045, count: 22, spacing: 1.6)
        case .chicken: Recipe(size: 0.065, count: 14, spacing: 1.6)
        case .generic: Recipe(size: 0.065, count: 13, spacing: 1.8)
        }
    }

    /// Seeded scatter inside the sauce, restricted to one half when asked.
    static func scatter(count: Int, size: CGFloat, spacing: CGFloat, side: PizzaSide,
                        _ rng: inout SeededRandom, limit: CGFloat = 0.78) -> [CGPoint] {
        var placed: [CGPoint] = []
        let maxR = limit - size * 0.5
        let minGap = size * spacing
        for _ in 0..<count {
            var best: CGPoint?
            var bestGap: CGFloat = -1
            for _ in 0..<24 {
                let a = rng.unit() * 2 * .pi
                let d = sqrt(rng.unit()) * maxR
                let p = CGPoint(x: d * cos(a), y: d * sin(a))
                switch side {
                case .left where p.x > -size * 0.6: continue
                case .right where p.x < size * 0.6: continue
                default: break
                }
                let gap = placed.map { hypot($0.x - p.x, $0.y - p.y) }.min() ?? .infinity
                if gap >= minGap { best = p; break }
                if gap > bestGap { best = p; bestGap = gap }
            }
            if let best { placed.append(best) }
        }
        return placed
    }

    /// How many pieces a layer scatters.
    static func pieceCount(_ layer: PizzaLayer) -> Int {
        let recipe = recipe(layer.style)
        let count = layer.side == .whole ? recipe.count : Int((Double(recipe.count) * 0.55).rounded(.up))
        return layer.extra ? Int((Double(count) * 1.7).rounded()) : count
    }

    /// A photo piece's longest side, in piece radii (`Recipe.size`), so it covers about as much
    /// pizza as the drawing it replaces.
    static func photoSpan(_ style: ToppingStyle) -> CGFloat {
        switch style {
        case .pepperoni, .tomato: 2.1
        case .sweetcorn: 2.9
        case .basil, .sausage: 3.0
        case .olive: 3.1
        case .mushroom, .pineapple: 3.2
        case .ham, .onion: 3.4
        case .chicken, .chilli: 3.6
        case .pepper: 4.2  // thin curved strips: long for the pizza they cover
        case .cheese, .generic: 2.2
        }
    }

    /// One topping's pieces. With `pieces`, photo pieces stand in for the drawing; pieces in
    /// `drops` are drawn falling (bigger, nearer the eye, their shadow further off) at `now`.
    static func layer(_ ctx: inout GraphicsContext, _ g: Geometry, _ layer: PizzaLayer,
                      image: GraphicsContext.ResolvedImage?, pieces: [GraphicsContext.ResolvedImage] = [],
                      drops: PieceDrops = PieceDrops(), now: Date = .distantPast) {
        let recipe = recipe(layer.style)
        let sideSalt = PizzaSide.allCases.firstIndex(of: layer.side) ?? 0
        let seed = layer.toppingId &* 7919 &+ sideSalt &* 104_729
        var rng = SeededRandom(seed: seed)
        // The first points are the same with or without extra, so "extra" adds pieces.
        let points = scatter(count: pieceCount(layer), size: recipe.size, spacing: recipe.spacing, side: layer.side, &rng)
        let s = g.r * recipe.size

        if layer.style == .cheese {
            cheese(&ctx, g, points: points, side: layer.side, &rng)
            return
        }

        /// Everything random about piece `i`, from its own generator so pieces never shift
        /// when others are added, removed or drawn in a different order.
        struct Piece {
            var rng: SeededRandom
            let at: CGPoint
            let angle: Angle
            let scale: CGFloat
            let photo: Int
            let delay: TimeInterval
            let spin: Angle
        }
        let all = points.enumerated().map { i, p in
            var r = SeededRandom(seed: seed &+ (i + 1) &* 0x2545_F491)
            return Piece(rng: r, at: CGPoint(x: g.c.x + p.x * g.r, y: g.c.y + p.y * g.r),
                         angle: r.angle(), scale: r.range(0.88...1.1), photo: Int(r.next() >> 33),
                         delay: Double(r.unit()), spin: .degrees(Double(r.range(-50...50))))
        }

        func draw(_ piece: Piece, in c: inout GraphicsContext, lift: CGFloat = 0, squash: CGFloat = 1) {
            var c = c
            var rng = piece.rng
            c.translateBy(x: piece.at.x, y: piece.at.y)
            c.rotate(by: piece.angle + piece.spin * Double(lift))
            let size = s * piece.scale * (1 + lift * 0.75) * squash
            if pieces.isEmpty {
                PizzaPainter.piece(&c, layer.style, size, &rng, image: image)
            } else {
                let photo = pieces[piece.photo % pieces.count]
                let span = size * photoSpan(layer.style)
                let k = span / max(photo.size.width, photo.size.height, 1)
                let w = photo.size.width * k, h = photo.size.height * k
                c.draw(photo, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
            }
        }

        // Landed (and settling) pieces, with the usual soft shadow.
        var falling: [(Piece, CGFloat)] = []
        ctx.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.32), radius: g.r * 0.012, x: g.r * 0.004, y: g.r * 0.009))
            for (i, piece) in all.enumerated() {
                guard let t = drops.elapsed(i, delay: piece.delay, now: now) else {
                    draw(piece, in: &l)
                    continue
                }
                if t < 0 { continue }  // still in the hand
                if t < PieceDrops.fall {
                    let p = t / PieceDrops.fall
                    falling.append((piece, CGFloat(1 - p * p)))  // speeds up as it falls
                } else {
                    // A small squash as it lands.
                    let q = (t - PieceDrops.fall) / PieceDrops.settle
                    draw(piece, in: &l, squash: 1 - 0.07 * CGFloat(sin(q * .pi)))
                }
            }
        }
        // Falling pieces above the rest; their shadow drifts further off the higher they are.
        for (piece, lift) in falling {
            let fade = min(1, (1 - lift) * 4 + 0.15)
            var shadow = ctx
            shadow.opacity = 0.3 * (1 - lift * 0.6)
            shadow.addFilter(.blur(radius: g.r * (0.012 + lift * 0.03)))
            shadow.fill(disc(s * piece.scale * 0.95, at: CGPoint(x: piece.at.x + g.r * 0.09 * lift, y: piece.at.y + g.r * 0.13 * lift)),
                        with: .color(.black))
            var c = ctx
            c.opacity = Double(fade)
            draw(piece, in: &c, lift: lift)
        }
    }

    /// Melted mozzarella: overlapping soft blobs with browned spots.
    static func cheese(_ ctx: inout GraphicsContext, _ g: Geometry, points: [CGPoint], side: PizzaSide,
                       _ rng: inout SeededRandom) {
        var clip = Path(ellipseIn: CGRect(x: g.c.x - g.r * 0.83, y: g.c.y - g.r * 0.83, width: g.r * 1.66, height: g.r * 1.66))
        if side != .whole {
            let half = CGRect(x: side == .left ? g.c.x - g.r : g.c.x + g.r * 0.02, y: g.c.y - g.r,
                              width: g.r * 0.98, height: g.r * 2)
            clip = clip.intersection(Path(half))
        }
        ctx.drawLayer { l in
            l.clip(to: clip)
            l.drawLayer { melt in
                melt.addFilter(.blur(radius: g.r * 0.006))
                for p in points {
                    var c = melt
                    c.translateBy(x: g.c.x + p.x * g.r, y: g.c.y + p.y * g.r)
                    c.fill(blob(radius: g.r * 0.13 * rng.range(0.75...1.2), irregularity: 0.35, &rng),
                           with: .color(Color(0xFAEDCB, 0.96)))
                }
            }
            // Sheen and browning.
            l.drawLayer { b in
                b.addFilter(.blur(radius: g.r * 0.01))
                for p in points where rng.unit() < 0.45 {
                    let q = CGPoint(x: g.c.x + (p.x + rng.range(-0.05...0.05)) * g.r,
                                    y: g.c.y + (p.y + rng.range(-0.05...0.05)) * g.r)
                    b.fill(disc(g.r * rng.range(0.012...0.03), at: q), with: .color(Color(0xC98A3A, Double(rng.range(0.35...0.7)))))
                }
                for p in points where rng.unit() < 0.3 {
                    let q = CGPoint(x: g.c.x + p.x * g.r - g.r * 0.02, y: g.c.y + p.y * g.r - g.r * 0.02)
                    b.fill(disc(g.r * 0.02, at: q), with: .color(.white.opacity(0.45)))
                }
            }
        }
    }

    /// One piece, centred on the origin of `c` (already rotated). `s` is its radius in points.
    static func piece(_ c: inout GraphicsContext, _ style: ToppingStyle, _ s: CGFloat, _ rng: inout SeededRandom,
                      image: GraphicsContext.ResolvedImage?) {
        switch style {
        case .cheese:
            c.fill(blob(radius: s, irregularity: 0.3, &rng), with: .color(Color(0xFBF1D3)))
        case .pepperoni:
            let edge = blob(radius: s, irregularity: 0.05, n: 12, &rng)
            c.fill(edge, with: radial([Color(0xD8503A), Color(0xB83423), Color(0x8C2015)],
                                      center: CGPoint(x: -s * 0.25, y: -s * 0.25), radius: s * 1.25))
            c.stroke(edge, with: .color(Color(0x5E1209, 0.55)), lineWidth: s * 0.1)
            for _ in 0..<7 {  // fat
                let p = CGPoint(x: rng.range(-0.6...0.6) * s, y: rng.range(-0.6...0.6) * s)
                c.fill(disc(s * rng.range(0.05...0.11), at: p), with: .color(Color(0xF4C3B2, 0.55)))
            }
            c.fill(disc(s * 0.35, at: CGPoint(x: -s * 0.35, y: -s * 0.35)), with: .color(.white.opacity(0.12)))
        case .ham:
            let w = s * 1.5, h = s * rng.range(0.9...1.15)
            let path = Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: s * 0.25)
            c.fill(path, with: .linearGradient(Gradient(colors: [Color(0xF3B9B3), Color(0xDE8A84)]),
                                               startPoint: CGPoint(x: -w / 2, y: -h / 2), endPoint: CGPoint(x: w / 2, y: h / 2)))
            var vein = Path()
            vein.move(to: CGPoint(x: -w * 0.4, y: h * 0.1))
            vein.addQuadCurve(to: CGPoint(x: w * 0.4, y: -h * 0.05), control: CGPoint(x: 0, y: -h * 0.4))
            c.stroke(vein, with: .color(.white.opacity(0.4)), lineWidth: s * 0.12)
            c.stroke(path, with: .color(Color(0xB86560, 0.5)), lineWidth: s * 0.06)
        case .mushroom:
            var cap = Path()
            cap.move(to: CGPoint(x: -s, y: 0))
            cap.addCurve(to: CGPoint(x: s, y: 0), control1: CGPoint(x: -s, y: -s * 1.25), control2: CGPoint(x: s, y: -s * 1.25))
            cap.addLine(to: CGPoint(x: s * 0.32, y: 0))
            cap.addLine(to: CGPoint(x: s * 0.28, y: s * 0.75))
            cap.addQuadCurve(to: CGPoint(x: -s * 0.28, y: s * 0.75), control: CGPoint(x: 0, y: s * 0.85))
            cap.addLine(to: CGPoint(x: -s * 0.32, y: 0))
            cap.closeSubpath()
            c.fill(cap, with: .linearGradient(Gradient(colors: [Color(0xEADBC0), Color(0xCDB28A)]),
                                              startPoint: CGPoint(x: 0, y: -s), endPoint: CGPoint(x: 0, y: s)))
            for i in -3...3 {  // gills
                var gill = Path()
                gill.move(to: CGPoint(x: CGFloat(i) * s * 0.07, y: -s * 0.05))
                gill.addLine(to: CGPoint(x: CGFloat(i) * s * 0.26, y: -s * 0.7))
                c.stroke(gill, with: .color(Color(0x9C7C58, 0.45)), lineWidth: s * 0.05)
            }
            c.stroke(cap, with: .color(Color(0x6E4E32, 0.85)), lineWidth: s * 0.13)
        case .onion:
            let span = Double(rng.range(200...330))
            let start = Double(rng.range(0...360))
            for (radius, width, colour) in [(s, s * 0.2, Color(0x8E3F86)), (s * 0.86, s * 0.08, Color(0xE6C8E1, 0.9)),
                                            (s * 0.62, s * 0.14, Color(0xA45A9B, 0.9))] {
                var arc = Path()
                arc.addArc(center: .zero, radius: radius, startAngle: .degrees(start), endAngle: .degrees(start + span), clockwise: false)
                c.stroke(arc, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        case .pepper:
            let colours: [UInt32] = [0x2E8B3A, 0xC62828, 0xF2B705]
            let colour = Color(colours[Int(rng.unit() * 3) % 3])
            var strip = Path()
            strip.addArc(center: CGPoint(x: 0, y: s * 1.4), radius: s * 1.5, startAngle: .degrees(-120),
                         endAngle: .degrees(-60), clockwise: false)
            c.stroke(strip, with: .color(colour), style: StrokeStyle(lineWidth: s * 0.6, lineCap: .round))
            c.stroke(strip, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: s * 0.12, lineCap: .round))
        case .pineapple:
            var wedge = Path()
            wedge.move(to: CGPoint(x: -s * 0.9, y: -s * 0.6))
            wedge.addLine(to: CGPoint(x: s * 0.9, y: -s * 0.6))
            wedge.addLine(to: CGPoint(x: s * 0.55, y: s * 0.7))
            wedge.addLine(to: CGPoint(x: -s * 0.55, y: s * 0.7))
            wedge.closeSubpath()
            let rounded = wedge.strokedPath(StrokeStyle(lineWidth: s * 0.3, lineJoin: .round)).union(wedge)
            c.fill(rounded, with: .linearGradient(Gradient(colors: [Color(0xFCE89A), Color(0xEBB63A)]),
                                                  startPoint: CGPoint(x: 0, y: -s), endPoint: CGPoint(x: 0, y: s)))
            for i in -2...2 {
                var fibre = Path()
                fibre.move(to: CGPoint(x: CGFloat(i) * s * 0.3, y: -s * 0.55))
                fibre.addLine(to: CGPoint(x: CGFloat(i) * s * 0.2, y: s * 0.6))
                c.stroke(fibre, with: .color(Color(0xC98E1E, 0.35)), lineWidth: s * 0.06)
            }
        case .chilli:
            c.stroke(disc(s * 0.85), with: .color(Color(0xD42A1F)), lineWidth: s * 0.32)
            c.fill(disc(s * 0.68), with: .color(Color(0xE9573C, 0.5)))
            for _ in 0..<4 {
                let p = CGPoint(x: rng.range(-0.35...0.35) * s, y: rng.range(-0.35...0.35) * s)
                c.fill(disc(s * 0.12, at: p), with: .color(Color(0xF6E7A8)))
            }
        case .olive:
            c.stroke(disc(s * 0.75), with: .color(Color(0x1E1C1B)), lineWidth: s * 0.48)
            var shine = Path()
            shine.addArc(center: .zero, radius: s * 0.8, startAngle: .degrees(200), endAngle: .degrees(250), clockwise: false)
            c.stroke(shine, with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: s * 0.12, lineCap: .round))
        case .basil:
            var leaf = Path()
            leaf.move(to: CGPoint(x: -s * 1.3, y: 0))
            leaf.addQuadCurve(to: CGPoint(x: s * 1.3, y: 0), control: CGPoint(x: 0, y: -s * 1.1))
            leaf.addQuadCurve(to: CGPoint(x: -s * 1.3, y: 0), control: CGPoint(x: 0, y: s * 1.1))
            c.fill(leaf, with: .linearGradient(Gradient(colors: [Color(0x4A9E3A), Color(0x1F5E1C)]),
                                               startPoint: CGPoint(x: 0, y: -s), endPoint: CGPoint(x: 0, y: s)))
            var vein = Path()
            vein.move(to: CGPoint(x: -s * 1.2, y: 0))
            vein.addLine(to: CGPoint(x: s * 1.1, y: 0))
            for i in 0..<3 {
                let x = -s * 0.6 + CGFloat(i) * s * 0.55
                vein.move(to: CGPoint(x: x, y: 0)); vein.addLine(to: CGPoint(x: x + s * 0.35, y: -s * 0.35))
                vein.move(to: CGPoint(x: x, y: 0)); vein.addLine(to: CGPoint(x: x + s * 0.35, y: s * 0.35))
            }
            c.stroke(vein, with: .color(Color(0x9BD58A, 0.55)), lineWidth: s * 0.06)
            c.fill(leaf, with: radial([.white.opacity(0.18), .clear], center: CGPoint(x: -s * 0.4, y: -s * 0.3), radius: s))
        case .sweetcorn:
            let k = Path(roundedRect: CGRect(x: -s, y: -s * 0.85, width: s * 2, height: s * 1.7), cornerRadius: s * 0.7)
            c.fill(k, with: radial([Color(0xFDE27A), Color(0xF2B21C), Color(0xD9930A)],
                                   center: CGPoint(x: -s * 0.3, y: -s * 0.3), radius: s * 1.4))
            c.fill(disc(s * 0.28, at: CGPoint(x: -s * 0.35, y: -s * 0.3)), with: .color(.white.opacity(0.55)))
        case .tomato:
            c.fill(disc(s), with: .color(Color(0xCF3326)))
            c.fill(disc(s * 0.82), with: .color(Color(0xE65A45)))
            for i in 0..<4 {
                var chamber = c
                chamber.rotate(by: .degrees(Double(i) * 90 + 45))
                chamber.fill(Path(ellipseIn: CGRect(x: s * 0.18, y: -s * 0.2, width: s * 0.5, height: s * 0.4)),
                             with: .color(Color(0xF39A7A)))
                chamber.fill(disc(s * 0.06, at: CGPoint(x: s * 0.42, y: 0)), with: .color(Color(0xF8E2A8)))
            }
            c.fill(disc(s * 0.4, at: CGPoint(x: -s * 0.35, y: -s * 0.35)), with: .color(.white.opacity(0.14)))
        case .sausage:
            let b = blob(radius: s, irregularity: 0.3, n: 7, &rng)
            c.fill(b, with: radial([Color(0x9A6040), Color(0x6A3820)], center: CGPoint(x: -s * 0.3, y: -s * 0.3), radius: s * 1.3))
            for _ in 0..<5 {
                let p = CGPoint(x: rng.range(-0.5...0.5) * s, y: rng.range(-0.5...0.5) * s)
                c.fill(disc(s * 0.1, at: p), with: .color(Color(0xD9A27A, 0.6)))
            }
        case .chicken:
            let b = blob(radius: s, irregularity: 0.22, n: 7, &rng, squash: 0.75)
            c.fill(b, with: radial([Color(0xF4DDB4), Color(0xD9AA6C)], center: CGPoint(x: -s * 0.2, y: -s * 0.2), radius: s * 1.2))
            for dy in [-0.25, 0.2] {
                var mark = Path()
                mark.move(to: CGPoint(x: -s * 0.7, y: s * dy - s * 0.15))
                mark.addLine(to: CGPoint(x: s * 0.7, y: s * dy + s * 0.15))
                c.stroke(mark, with: .color(Color(0x5A3416, 0.55)), style: StrokeStyle(lineWidth: s * 0.14, lineCap: .round))
            }
        case .generic:
            let shape = disc(s)
            if let image {
                var clipped = c
                clipped.clip(to: shape)
                clipped.draw(image, in: CGRect(x: -s * 1.3, y: -s * 1.3, width: s * 2.6, height: s * 2.6))
            } else {
                c.fill(blob(radius: s, irregularity: 0.2, &rng), with: radial([Color(0xC9A274), Color(0x93683D)],
                                                                             center: CGPoint(x: -s * 0.3, y: -s * 0.3), radius: s * 1.3))
            }
        }
    }

    // MARK: Icon

    /// A little heap of pieces on a plate, for topping lists without a photo.
    static func icon(_ ctx: inout GraphicsContext, _ g: Geometry, style: ToppingStyle, seed: Int) {
        var rng = SeededRandom(seed: seed &* 31 &+ 7)
        let plate = disc(g.r * 0.98, at: g.c)
        ctx.fill(plate, with: radial([Color(0xFBF8F2), Color(0xE7E0D4)], center: g.c, radius: g.r))
        ctx.stroke(disc(g.r * 0.78, at: g.c), with: .color(.black.opacity(0.05)), lineWidth: g.r * 0.03)
        if style == .cheese {
            ctx.drawLayer { l in
                l.addFilter(.shadow(color: .black.opacity(0.25), radius: g.r * 0.05, x: 0, y: g.r * 0.04))
                for _ in 0..<4 {
                    var c = l
                    c.translateBy(x: g.c.x + rng.range(-0.25...0.25) * g.r, y: g.c.y + rng.range(-0.25...0.25) * g.r)
                    c.fill(blob(radius: g.r * 0.32, irregularity: 0.25, &rng), with: .radialGradient(
                        Gradient(colors: [Color(0xFFFBEF), Color(0xF1E3BD)]), center: .zero, startRadius: 0, endRadius: g.r * 0.4))
                }
            }
            return
        }
        let recipe = recipe(style)
        // Scale pieces so a handful fills the plate.
        let s = g.r * min(0.42, max(0.2, recipe.size * 4))
        let n = style == .sweetcorn ? 9 : (recipe.size > 0.09 ? 3 : 5)
        let points = scatter(count: n, size: s / g.r, spacing: 1.1, side: .whole, &rng, limit: 0.62 + s / g.r * 0.5)
        ctx.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.3), radius: g.r * 0.04, x: g.r * 0.01, y: g.r * 0.03))
            for p in points {
                var c = l
                c.translateBy(x: g.c.x + p.x * g.r, y: g.c.y + p.y * g.r)
                c.rotate(by: rng.angle())
                piece(&c, style, s * rng.range(0.9...1.08), &rng, image: nil)
            }
        }
    }
}
