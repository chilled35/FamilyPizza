import Foundation

enum Config {
    /// The pizza server on the home LAN (HANDOFF §2).
    /// Debug builds can point elsewhere with the launch argument
    /// `-PIZZA_BASE_URL http://127.0.0.1:8765` (used to test in the simulator against a local server).
    static var baseURL: URL {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "PIZZA_BASE_URL"),
           let url = URL(string: override) {
            return url
        }
        #endif
        return URL(string: "http://192.168.0.50:8000")!
    }

    /// Which Apple push server this build's device token belongs to (HANDOFF §4 `POST /api/devices`).
    /// Read from the provisioning profile rather than guessed from DEBUG/RELEASE:
    /// builds installed from Xcode carry a development profile (sandbox tokens);
    /// TestFlight/App Store builds carry no profile (production tokens); simulators use sandbox.
    static let apnsEnvironment: String = {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return "production"
        }
        // The profile is a signed plist; its XML is readable as plain text inside the file.
        let text = String(decoding: data, as: UTF8.self)
        let development = text.range(
            of: #"<key>aps-environment</key>\s*<string>development</string>"#,
            options: .regularExpression) != nil
        return development ? "sandbox" : "production"
        #endif
    }()
}
