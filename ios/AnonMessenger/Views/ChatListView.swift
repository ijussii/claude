import SwiftUI

struct ChatListView: View {
    @EnvironmentObject var model: AppModel
    @State private var path: [String] = []
    @State private var showNew = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(model.conversations) { convo in
                    NavigationLink(value: convo.peer) { row(convo) }
                }
            }
            .overlay {
                if model.conversations.isEmpty {
                    ContentUnavailableView("No chats yet",
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Tap the compose button and enter a username to start talking."))
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: String.self) { ChatView(peer: $0) }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !model.isConnected {
                    Text("Connecting…")
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(.yellow.opacity(0.3))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "person.crop.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .sheet(isPresented: $showNew) {
                NewChatView { peer in path.append(peer) }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private func row(_ convo: Conversation) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(convo.peer).font(.headline)
                Text((convo.last.outgoing ? "You: " : "") + convo.last.text)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if convo.unread > 0 {
                Text("\(convo.unread)")
                    .font(.caption.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.blue))
            }
        }
    }
}
