import Foundation
import CryptoKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var identity: Identity?
    @Published private(set) var isConnected = false
    @Published private(set) var messages: [Message] = []
    @Published var sessionProblem: String?

    let relay: RelayClient
    let calls: CallManager

    private var publicKeys: [String: String] = [:]
    private var readAt: [String: Date] = [:]
    private var lookupWaiters: [String: [CheckedContinuation<String?, Never>]] = [:]

    static func isValidUsername(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9_]{3,20}$", options: .regularExpression) != nil
    }

    init() {
        let relay = RelayClient()
        self.relay = relay
        self.calls = CallManager(relay: relay)

        let snap = LocalStore.load()
        messages = snap.messages
        publicKeys = snap.publicKeys
        readAt = snap.readAt
        identity = Identity.load()

        relay.onEvent = { [weak self] in self?.handle($0) }
        relay.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.isConnected = connected
            if !connected { self.failPendingSends() }
        }
        if let identity { relay.start(identity: identity) }
    }

    // MARK: - Account

    func register(username: String) async throws {
        let name = username.lowercased()
        let key = Curve25519.KeyAgreement.PrivateKey()
        let token = try await RelayClient.register(username: name,
                                                   publicKey: key.publicKey.rawRepresentation.base64EncodedString())
        let id = Identity(username: name, token: token, privateKey: key)
        id.save()
        LocalStore.clear()
        messages = []; publicKeys = [:]; readAt = [:]
        sessionProblem = nil
        identity = id
        relay.start(identity: id)
    }

    /// There is no server-side recovery: this removes your identity from the device for good.
    func signOut() {
        calls.hangUp()
        relay.stop()
        Identity.clear()
        LocalStore.clear()
        identity = nil
        messages = []; publicKeys = [:]; readAt = [:]
    }

    func appBecameActive() { relay.reconnectNow() }

    // MARK: - Conversations

    var conversations: [Conversation] {
        Dictionary(grouping: messages, by: \.peer)
            .compactMap { peer, msgs -> Conversation? in
                guard let last = msgs.max(by: { $0.date < $1.date }) else { return nil }
                let cutoff = readAt[peer] ?? .distantPast
                let unread = msgs.filter { !$0.outgoing && $0.date > cutoff }.count
                return Conversation(peer: peer, last: last, unread: unread)
            }
            .sorted { $0.last.date > $1.last.date }
    }

    func messages(with peer: String) -> [Message] {
        messages.filter { $0.peer == peer }.sorted { $0.date < $1.date }
    }

    func markRead(_ peer: String) {
        readAt[peer] = Date()
        persist()
        objectWillChange.send()
    }

    /// True if `name` exists on the server (and caches its public key).
    func userExists(_ name: String) async -> Bool {
        await lookup(name) != nil
    }

    func safetyNumber(with peer: String) -> String? {
        guard let identity,
              let b64 = publicKeys[peer], let raw = Data(base64Encoded: b64),
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { return nil }
        return E2E.safetyNumber(identity.publicKey, theirs)
    }

    // MARK: - Sending

    func send(_ text: String, to peer: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let msg = Message(id: UUID().uuidString, peer: peer, outgoing: true, text: trimmed, date: Date(), status: .sending)
        messages.append(msg)
        persist()
        Task { await transmit(msg) }
    }

    func retry(_ msg: Message) {
        guard msg.outgoing, msg.status == .failed else { return }
        setStatus(msg.id, .sending)
        Task { await transmit(msg) }
    }

    private func transmit(_ msg: Message) async {
        guard let identity, relay.isConnected,
              let theirs = await publicKey(for: msg.peer),
              let body = try? E2E.encrypt(msg.text, from: identity.privateKey, to: theirs) else {
            setStatus(msg.id, .failed)
            return
        }
        relay.send(["t": "msg", "to": msg.peer, "id": msg.id, "body": body])
    }

    private func setStatus(_ id: String, _ status: Message.Status) {
        guard let i = messages.firstIndex(where: { $0.id == id && $0.outgoing }) else { return }
        messages[i].status = status
        persist()
    }

    private func failPendingSends() {
        for i in messages.indices where messages[i].outgoing && messages[i].status == .sending {
            messages[i].status = .failed
        }
        persist()
    }

    // MARK: - Receiving

    private func receive(sid: Int, from: String, id: String, body: String, ts: Date) async {
        let ack = { self.relay.send(["t": "recv", "sid": sid]) }

        // Already have it (the server re-delivers until we ack).
        if messages.contains(where: { $0.id == id && $0.peer == from && !$0.outgoing }) { ack(); return }

        // No key for the sender yet (offline?). Don't ack - the server will deliver again.
        guard let identity, let theirs = await publicKey(for: from) else { return }

        let text = (try? E2E.decrypt(body, using: identity.privateKey, from: theirs)) ?? "🔒 This message couldn't be decrypted."
        messages.append(Message(id: id, peer: from, outgoing: false, text: text, date: ts, status: .sent))
        persist()
        ack()
    }

    // MARK: - Public keys

    private func publicKey(for username: String) async -> Curve25519.KeyAgreement.PublicKey? {
        let b64: String?
        if let cached = publicKeys[username] { b64 = cached } else { b64 = await lookup(username) }
        guard let b64, let raw = Data(base64Encoded: b64) else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    }

    private func lookup(_ username: String) async -> String? {
        if let cached = publicKeys[username] { return cached }
        guard relay.isConnected else { return nil }
        return await withCheckedContinuation { cont in
            lookupWaiters[username, default: []].append(cont)
            relay.send(["t": "lookup", "username": username])
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self.resolveLookup(username, nil)   // no-op if already answered
            }
        }
    }

    private func resolveLookup(_ username: String, _ key: String?) {
        guard let waiters = lookupWaiters.removeValue(forKey: username) else { return }
        waiters.forEach { $0.resume(returning: key) }
    }

    // MARK: - Server events

    private func handle(_ event: ServerEvent) {
        switch event {
        case .ready:
            break
        case .message(let sid, let from, let id, let body, let ts):
            Task { await receive(sid: sid, from: from, id: id, body: body, ts: ts) }
        case .sent(let id):
            setStatus(id, .sent)
        case .user(let name, let pubkey):
            if let pubkey { publicKeys[name] = pubkey; persist() }
            resolveLookup(name, pubkey)
        case .call(let from, let callId, let kind, let data):
            calls.handleSignal(from: from, callId: callId, kind: kind, data: data)
        case .error(let code, let id):
            if let id { setStatus(id, .failed) }
            switch code {
            case "auth_failed": sessionProblem = "The server didn't recognise this account."
            case "signed_in_elsewhere": sessionProblem = "This account was opened on another device. Return to the app to take it back."
            default: break
            }
        }
    }

    private func persist() {
        LocalStore.save(Snapshot(messages: messages, publicKeys: publicKeys, readAt: readAt))
    }
}
