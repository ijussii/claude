import Foundation

enum Config {
    private static let relayKey = "relayURL"

    /// Where the relay server lives. Use wss:// (TLS) for anything but local testing.
    /// For a real iPhone on the same Wi-Fi as your Mac, use your Mac's LAN IP, e.g. ws://192.168.1.20:8080
    static let defaultRelay = "ws://localhost:8080"

    static var relayURLString: String {
        get { UserDefaults.standard.string(forKey: relayKey) ?? defaultRelay }
        set { UserDefaults.standard.set(newValue, forKey: relayKey) }
    }

    static var relayURL: URL {
        URL(string: relayURLString) ?? URL(string: defaultRelay)!
    }

    static func isValidRelay(_ s: String) -> Bool {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), u.host != nil else { return false }
        return scheme == "ws" || scheme == "wss"
    }

    /// STUN helps two phones find each other across NATs. Calls between phones on the *same*
    /// Wi-Fi work with just this. For phones on different networks behind strict NATs you will
    /// eventually want a TURN server too (e.g. coturn) - add its URL + credentials here.
    static let iceServers = ["stun:stun.l.google.com:19302"]
}
