import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var name = ""
    @State private var saving = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("First name", text: $name)
                        .textContentType(.givenName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    Button(saving ? "Saving…" : "Save name") {
                        Task { await save() }
                    }
                    .disabled(trimmed.isEmpty || trimmed == model.name || trimmed.count > 40 || saving)
                } header: {
                    Text("Your name")
                } footer: {
                    Text("Shown to the kitchen on your orders.")
                }

                Section {
                    switch model.notificationsAllowed {
                    case true?:
                        Label("On: you'll be told when your pizza is ready", systemImage: "bell.badge")
                    case false?:
                        Label("Off: you won't hear when your pizza is ready", systemImage: "bell.slash")
                            .foregroundStyle(.orange)
                        Button("Turn on in Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                openURL(url)
                            }
                        }
                    case nil:
                        Button("Allow notifications") {
                            Task { await model.requestNotificationPermission() }
                        }
                    }
                } header: {
                    Text("Notifications")
                }

                Section("About") {
                    LabeledContent("Server", value: Config.baseURL.absoluteString)
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                name = model.name ?? ""
                await model.refreshNotificationPermission()
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await model.register(name: trimmed)
        } catch {
            model.alertMessage = (error as? APIError)?.message ?? error.localizedDescription
        }
    }
}
