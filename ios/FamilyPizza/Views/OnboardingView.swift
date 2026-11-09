import SwiftUI

/// First launch: ask for a first name, register this phone, then ask to allow notifications.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var reachable: Bool?
    @State private var working = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            // Drawn, not fetched: the menu (and its photos) isn't loaded before registration.
            PizzaView(spec: PizzaSpec(sauceHex: "#b5321e", layers: [
                PizzaLayer(toppingId: -1, style: .cheese),
                PizzaLayer(toppingId: -3, style: .pepperoni),
                PizzaLayer(toppingId: -11, style: .basil),
            ]))
            .frame(width: 120, height: 120)
            Text("Family Pizza")
                .font(.largeTitle.bold())
            Text("What's your first name? The kitchen sees it on your orders.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            TextField("First name", text: $name)
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($nameFocused)
                .onSubmit { Task { await start() } }
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: name) { _, value in
                    if value.count > 40 { name = String(value.prefix(40)) }
                }

            Button {
                Task { await start() }
            } label: {
                Group {
                    if working {
                        ProgressView()
                    } else {
                        Text("Let's eat")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(trimmed.isEmpty || working)

            serverStatus
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .task {
            nameFocused = true
            await checkServer()
        }
    }

    @ViewBuilder private var serverStatus: some View {
        switch reachable {
        case nil:
            Label("Looking for the pizza server…", systemImage: "antenna.radiowaves.left.and.right")
                .font(.footnote).foregroundStyle(.secondary)
        case true?:
            Label("Pizza server found", systemImage: "checkmark.circle")
                .font(.footnote).foregroundStyle(.green)
        case false?:
            VStack(spacing: 8) {
                Label(APIError.unreachable.message, systemImage: "wifi.exclamationmark")
                    .font(.footnote).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await checkServer() } }
                    .font(.footnote)
            }
        }
    }

    private func checkServer() async {
        reachable = nil
        reachable = await model.serverIsReachable()
    }

    private func start() async {
        guard !trimmed.isEmpty, !working else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            try await model.register(name: trimmed)
            await model.requestNotificationPermission()
            await model.refreshAll()
        } catch {
            self.error = (error as? APIError)?.message ?? error.localizedDescription
            reachable = await model.serverIsReachable()
        }
    }
}
