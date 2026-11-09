import SwiftUI

/// Shown for a moment when the app opens: the app icon's oven-glow ground, a pizza that
/// gets its toppings, and the name. The static launch screen (Info.plist `UILaunchScreen`)
/// uses the same `LaunchBackground` colour, so there is no flash between the two.
struct SplashView: View {
    /// Called once the toppings have landed and the picture has been seen for a moment.
    var onFinished: () -> Void = {}

    @State private var layers: [PizzaLayer] = []
    @State private var appeared = false

    private static let toppings: [PizzaLayer] = [
        PizzaLayer(toppingId: 1, style: .cheese),
        PizzaLayer(toppingId: 3, style: .pepperoni),
        PizzaLayer(toppingId: 11, style: .basil),
    ]

    /// "Version 1.2 (4)": marketing version and build number.
    private static let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }()

    var body: some View {
        ZStack {
            Color("LaunchBackground")
            RadialGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.12).opacity(0.85),
                                    Color(red: 0.55, green: 0.16, blue: 0.05).opacity(0.5), .clear],
                           center: .center, startRadius: 60, endRadius: 360)
                .opacity(appeared ? 1 : 0)

            VStack(spacing: 28) {
                PizzaView(spec: PizzaSpec(sauceHex: "#b5321e", layers: layers), showsDivider: false)
                    .frame(width: 220, height: 220)
                    .rotationEffect(.degrees(appeared ? 0 : -90))
                    .scaleEffect(appeared ? 1 : 0.6)
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
                Text("Family Pizza")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
            }

            Text(Self.version)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .opacity(appeared ? 1 : 0)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 60)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Family Pizza")
        .task {
            // About 3 seconds in all: spin in, toppings one by one, a pause to take it in.
            withAnimation(.spring(duration: 0.8, bounce: 0.3)) { appeared = true }
            try? await Task.sleep(for: .milliseconds(500))
            for topping in Self.toppings {
                try? await Task.sleep(for: .milliseconds(350))
                layers.append(topping)
            }
            try? await Task.sleep(for: .milliseconds(1400))
            onFinished()
        }
    }
}

#Preview {
    SplashView()
}
