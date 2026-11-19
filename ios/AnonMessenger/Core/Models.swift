import Foundation

struct Message: Codable, Identifiable, Hashable {
    enum Status: String, Codable { case sending, sent, failed }

    let id: String
    let peer: String          // the other person's username
    let outgoing: Bool
    let text: String
    let date: Date
    var status: Status
}

struct Conversation: Identifiable {
    var id: String { peer }
    let peer: String
    let last: Message
    let unread: Int
}

/// Everything persisted on-device (the server keeps nothing once a message is delivered).
struct Snapshot: Codable {
    var messages: [Message] = []
    var publicKeys: [String: String] = [:]   // username -> base64 X25519 public key
    var readAt: [String: Date] = [:]         // username -> last time the chat was open
}

enum LocalStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snapshot.json")
    }

    static func load() -> Snapshot {
        guard let data = try? Data(contentsOf: url) else { return Snapshot() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .millisecondsSince1970
        return (try? dec.decode(Snapshot.self, from: data)) ?? Snapshot()
    }

    static func save(_ snap: Snapshot) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? enc.encode(snap) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}
