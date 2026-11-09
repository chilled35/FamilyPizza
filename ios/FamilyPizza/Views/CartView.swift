import SwiftUI

struct CartView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var sending = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                if model.cart.isEmpty {
                    ContentUnavailableView("Your basket is empty", systemImage: "basket",
                                           description: Text("Pick a pizza from the menu or your favourites."))
                } else {
                    Section {
                        ForEach(model.cart) { item in
                            HStack(spacing: 12) {
                                PizzaThumb(spec: item.spec, size: 52)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.pizzaName).font(.headline)
                                    if !item.summary.isEmpty {
                                        Text(item.summary).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onDelete { model.cart.remove(atOffsets: $0) }
                    } footer: {
                        Text("Swipe left to remove a pizza.")
                    }

                    Section("Note for the kitchen") {
                        TextField("Optional", text: $note, axis: .vertical)
                            .lineLimit(1...4)
                            .onChange(of: note) { _, value in
                                if value.count > 200 { note = String(value.prefix(200)) }
                            }
                    }

                    Section {
                        Button {
                            Task { await send() }
                        } label: {
                            Group {
                                if sending {
                                    ProgressView()
                                } else {
                                    Text(model.cart.count == 1 ? "Send order" : "Send order (\(model.cart.count) pizzas)")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(sending || model.cart.count > 20)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } footer: {
                        if model.cart.count > 20 {
                            Text("The kitchen takes at most 20 pizzas per order.")
                        }
                    }
                }
            }
            .navigationTitle("Basket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await model.placeOrder(note: note)
            dismiss()
        } catch {
            model.alertMessage = (error as? APIError)?.message ?? error.localizedDescription
        }
    }
}
