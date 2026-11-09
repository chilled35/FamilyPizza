import Foundation

/// A failed request, with a message fit to show the person.
struct APIError: LocalizedError, Sendable {
    /// HTTP status, or 0 when the server couldn't be reached.
    let status: Int
    let message: String

    var errorDescription: String? { message }

    /// 404 "Unknown device: call POST /api/register first" (e.g. the server database was reset).
    var isUnknownUser: Bool { status == 404 && message.localizedCaseInsensitiveContains("register") }
    /// 409: a pizza or topping is no longer available, or a duplicate favourite label.
    var isConflict: Bool { status == 409 }

    static let unreachable = APIError(
        status: 0,
        message: "Can't reach the pizza server. Are you on the home Wi-Fi?")
}

struct APIClient: Sendable {
    let baseURL: URL

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601  // server sends e.g. 2026-11-08T21:03:34Z
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await send("GET", path, query: query, body: nil)
        return try decode(data)
    }

    func post<T: Decodable>(_ path: String, _ body: some Encodable) async throws -> T {
        let data = try await send("POST", path, query: [:], body: try Self.encoder.encode(body))
        return try decode(data)
    }

    /// POST/DELETE whose success response has no body (204).
    func call(_ method: String, _ path: String, query: [String: String] = [:], body: (any Encodable)? = nil) async throws {
        let encoded = try body.map { try Self.encoder.encode($0) }
        _ = try await send(method, path, query: query, body: encoded)
    }

    /// Server-Sent Events from `path`: yields each event's name and decoded `data`.
    /// Ends when the server closes the stream; throws if it can't connect or the line drops.
    func events<T: Decodable & Sendable>(_ path: String, query: [String: String] = [:],
                                         as type: T.Type) -> AsyncThrowingStream<T, Error> {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var builder = URLRequest(url: components.url!)
        builder.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let request = builder
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await Self.streamSession.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else { throw APIError(status: status, message: "Live updates unavailable (HTTP \(status)).") }
                    for try await line in bytes.lines {
                        // `lines` skips blank lines, so events aren't split on them: each server
                        // event is "event: x" then a single "data: {...}" line, decoded on its own.
                        if line.hasPrefix("data:") {
                            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            if let decoded = try? Self.decoder.decode(T.self, from: Data(data.utf8)) {
                                continuation.yield(decoded)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streams stay open for minutes; the server sends a keep-alive every 15 s.
    private static let streamSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 24 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError(status: -1, message: "Unexpected reply from the pizza server (\(error.localizedDescription)).")
        }
    }

    private func send(_ method: String, _ path: String, query: [String: String], body: Data?) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.unreachable
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(status: status, message: Self.detail(from: data) ?? "The pizza server said no (HTTP \(status)).")
        }
        return data
    }

    /// FastAPI errors: {"detail": "text"} or {"detail": [{"msg": "..."}, ...]} for validation.
    private static func detail(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let text = json["detail"] as? String {
            return text
        }
        if let list = json["detail"] as? [[String: Any]] {
            let messages = list.compactMap { $0["msg"] as? String }
            return messages.isEmpty ? nil : messages.joined(separator: "\n")
        }
        return nil
    }
}
