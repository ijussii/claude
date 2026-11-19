import Foundation

enum ServerEvent {
    case ready
    case message(sid: Int, from: String, id: String, body: String, ts: Date)
    case sent(id: String)
    case user(username: String, pubkey: String?)
    case call(from: String, callId: String, kind: String, data: [String: Any]?)
    case error(code: String, id: String?)
}

enum RelayError: LocalizedError {
    case server(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected response from the server."
        case .server(let code):
            switch code {
            case "username_taken": return "That username is already taken."
            case "invalid_username": return "Usernames are 3–20 characters: a–z, 0–9 and underscore."
            case "rate_limited": return "Too many attempts. Try again later."
            default: return "Server error (\(code))."
            }
        }
    }
}

/// WebSocket connection to the relay with automatic reconnect.
@MainActor
final class RelayClient {
    var onEvent: ((ServerEvent) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    private(set) var isConnected = false

    private var task: URLSessionWebSocketTask?
    private var identity: Identity?
    private var attempt = 0
    private var generation = 0          // bumped on every (re)open/stop so stale callbacks are ignored
    private var reconnectAllowed = true   // automatic retries (backoff)
    private var authFailed = false         // bad token: never retry

    func start(identity: Identity) {
        self.identity = identity
        attempt = 0
        reconnectAllowed = true
        authFailed = false
        open()
    }

    func stop() {
        identity = nil
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setConnected(false)
    }

    /// Call when the app returns to the foreground; iOS silently drops sockets in the background.
    func reconnectNow() {
        guard identity != nil, !isConnected, !authFailed else { return }
        attempt = 0
        reconnectAllowed = true
        task?.cancel(with: .goingAway, reason: nil)
        open()
    }

    func send(_ object: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    // MARK: - Internals

    private func open() {
        guard let identity else { return }
        generation += 1
        let gen = generation
        let t = URLSession.shared.webSocketTask(with: Config.relayURL)
        task = t
        t.resume()
        send(["t": "auth", "username": identity.username, "token": identity.token])
        receive(t, gen)
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure:
                    self.handleDisconnect()
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(t, gen)
                }
            }
        }
    }

    private func handleDisconnect() {
        setConnected(false)
        guard identity != nil, reconnectAllowed else { return }
        attempt += 1
        let delay = min(30.0, pow(2.0, Double(attempt)))
        let gen = generation
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if gen == self.generation, self.identity != nil, !self.isConnected { self.open() }
        }
    }

    private func setConnected(_ value: Bool) {
        guard value != isConnected else { return }
        isConnected = value
        onConnectionChange?(value)
    }

    private func handle(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = obj["t"] as? String else { return }

        switch type {
        case "ready":
            attempt = 0
            setConnected(true)
            onEvent?(.ready)
        case "msg":
            guard let sid = obj["sid"] as? Int, let from = obj["from"] as? String,
                  let id = obj["id"] as? String, let body = obj["body"] as? String else { return }
            let ms = (obj["ts"] as? Double) ?? Date().timeIntervalSince1970 * 1000
            onEvent?(.message(sid: sid, from: from, id: id, body: body, ts: Date(timeIntervalSince1970: ms / 1000)))
        case "sent":
            if let id = obj["id"] as? String { onEvent?(.sent(id: id)) }
        case "user":
            guard let name = obj["username"] as? String else { return }
            let found = (obj["found"] as? Bool) ?? false
            onEvent?(.user(username: name, pubkey: found ? obj["pubkey"] as? String : nil))
        case "call":
            guard let from = obj["from"] as? String, let callId = obj["callId"] as? String,
                  let kind = obj["kind"] as? String else { return }
            onEvent?(.call(from: from, callId: callId, kind: kind, data: obj["data"] as? [String: Any]))
        case "error":
            let code = (obj["code"] as? String) ?? "unknown"
            // Don't auto-retry (and fight another device for the session) or hammer the server with a bad token.
            // Coming back to the foreground still retries after signed_in_elsewhere, but never after auth_failed.
            if code == "signed_in_elsewhere" { reconnectAllowed = false }
            if code == "auth_failed" { reconnectAllowed = false; authFailed = true }
            onEvent?(.error(code: code, id: obj["id"] as? String))
        default:
            break
        }
    }

    // MARK: - One-shot registration (before we have a token)

    nonisolated static func register(username: String, publicKey: String) async throws -> String {
        let t = URLSession.shared.webSocketTask(with: Config.relayURL)
        t.resume()
        defer { t.cancel(with: .normalClosure, reason: nil) }
        let payload = try JSONSerialization.data(withJSONObject: ["t": "register", "username": username, "pubkey": publicKey])
        try await t.send(.string(String(decoding: payload, as: UTF8.self)))
        let reply = try await t.receive()
        guard case .string(let text) = reply,
              let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw RelayError.badResponse
        }
        if obj["t"] as? String == "registered", let token = obj["token"] as? String { return token }
        throw RelayError.server(obj["code"] as? String ?? "unknown")
    }
}
