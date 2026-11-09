import SwiftUI
import UIKit

/// Topping photos from the server, fetched as the menu loads and kept in memory.
/// Image URLs are versioned (`?v=<hash>`) and served `immutable`, so the URL cache on disk
/// answers repeat launches without touching the network; a new upload gets a new URL.
@MainActor
@Observable
final class ToppingImages {
    private(set) var images: [Int: Image] = [:]
    private var loadedURL: [Int: String] = [:]
    private var inFlight: Set<String> = []

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 40 << 20)
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    /// Fetch every photo not already held (all in parallel; they're small and on the LAN).
    func load(_ toppings: [any ToppingPictured], baseURL: URL) async {
        var wanted: [(Int, String)] = []
        for topping in toppings {
            guard let path = topping.imageUrl else {
                // Photo removed by the owner: fall back to the drawing.
                if loadedURL[topping.id] != nil { images[topping.id] = nil; loadedURL[topping.id] = nil }
                continue
            }
            if loadedURL[topping.id] != path, !inFlight.contains(path) { wanted.append((topping.id, path)) }
        }
        guard !wanted.isEmpty else { return }
        inFlight.formUnion(wanted.map(\.1))
        await withTaskGroup(of: (Int, String, UIImage?).self) { group in
            for (id, path) in wanted {
                group.addTask {
                    guard let url = URL(string: path, relativeTo: baseURL),
                          let (data, response) = try? await Self.session.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return (id, path, nil) }
                    return (id, path, UIImage(data: data))
                }
            }
            for await (id, path, image) in group {
                inFlight.remove(path)
                guard let image else { continue }
                images[id] = Image(uiImage: image)
                loadedURL[id] = path
            }
        }
    }
}

/// A topping's picture: the owner's photo when there is one, otherwise a drawing of it.
struct ToppingThumb: View {
    @Environment(AppModel.self) private var model
    let topping: any ToppingPictured
    var size: CGFloat = 40
    var dimmed = false

    var body: some View {
        Group {
            if let photo = model.toppingImages.images[topping.id] {
                photo.resizable().scaledToFill()
            } else {
                ToppingArtIcon(style: topping.artStyle, seed: topping.id)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(.quaternary))
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.5 : 1)
        .accessibilityHidden(true)
    }
}
