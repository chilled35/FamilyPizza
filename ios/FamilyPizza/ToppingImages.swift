import SwiftUI
import UIKit

/// Topping photos and pieces from the server, fetched as the menu loads and kept in memory.
/// Image URLs are versioned (`?v=<hash>`) and served `immutable`, so the URL cache on disk
/// answers repeat launches without touching the network; a new upload gets a new URL.
@MainActor
@Observable
final class ToppingImages {
    private(set) var images: [Int: Image] = [:]
    /// Pieces cut from the owner's pieces sheet, by topping id (all of a topping's, or none).
    private(set) var pieces: [Int: [Image]] = [:]
    private var loadedURL: [Int: String] = [:]
    private var loadedPieceURLs: [Int: [String]] = [:]
    private var inFlight: Set<String> = []

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 40 << 20)
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    /// Fetch every photo and piece not already held (all in parallel; they're small and on the LAN).
    func load(_ toppings: [any ToppingPictured], baseURL: URL) async {
        async let photos: Void = loadPhotos(toppings, baseURL: baseURL)
        async let cut: Void = loadPieces(toppings, baseURL: baseURL)
        _ = await (photos, cut)
    }

    private func loadPhotos(_ toppings: [any ToppingPictured], baseURL: URL) async {
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

    private func loadPieces(_ toppings: [any ToppingPictured], baseURL: URL) async {
        var wanted: [(Int, [String])] = []
        var seen: Set<Int> = []
        for topping in toppings where seen.insert(topping.id).inserted {
            let paths = topping.pieceUrls ?? []
            if paths.isEmpty {
                // Pieces removed by the owner: back to the bundled pieces (or the photo).
                if loadedPieceURLs[topping.id] != nil { pieces[topping.id] = nil; loadedPieceURLs[topping.id] = nil }
                continue
            }
            let key = paths.joined(separator: " ")
            if loadedPieceURLs[topping.id] != paths, !inFlight.contains(key) { wanted.append((topping.id, paths)) }
        }
        guard !wanted.isEmpty else { return }
        inFlight.formUnion(wanted.map { $0.1.joined(separator: " ") })
        await withTaskGroup(of: (Int, [String], [UIImage]?).self) { group in
            for (id, paths) in wanted {
                group.addTask {
                    var found: [UIImage] = []
                    for path in paths {  // a handful of ~20 KB PNGs: one after another is fine
                        guard let url = URL(string: path, relativeTo: baseURL),
                              let (data, response) = try? await Self.session.data(from: url),
                              (response as? HTTPURLResponse)?.statusCode == 200,
                              let image = UIImage(data: data) else { return (id, paths, nil) }
                        found.append(image)
                    }
                    return (id, paths, found)
                }
            }
            for await (id, paths, found) in group {
                inFlight.remove(paths.joined(separator: " "))
                guard let found else { continue }  // keep what we had; the next refresh retries
                pieces[id] = found.map { Image(uiImage: $0) }
                loadedPieceURLs[id] = paths
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
