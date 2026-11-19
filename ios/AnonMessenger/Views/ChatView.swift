import SwiftUI

struct ChatView: View {
    let peer: String
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var calls: CallManager
    @State private var draft = ""
    @State private var showSafety = false

    var body: some View {
        let msgs = model.messages(with: peer)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(msgs) { m in
                            Bubble(message: m) { model.retry(m) }.id(m.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: msgs.last?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
                .onAppear { if let id = msgs.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            inputBar
        }
        .navigationTitle(peer)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Task { await calls.startCall(to: peer) } } label: { Image(systemName: "phone.fill") }
                    .disabled(!model.isConnected || calls.phase != .idle)
                Button { showSafety = true } label: { Image(systemName: "lock.shield") }
            }
        }
        .alert("Safety number", isPresented: $showSafety) {
            Button("OK", role: .cancel) {}
        } message: {
            Text((model.safetyNumber(with: peer) ?? "Not available yet.")
                 + "\n\nMessages are end-to-end encrypted. If \(peer) sees the same number on their phone, nobody has tampered with your keys.")
        }
        .onAppear { model.markRead(peer) }
        .onChange(of: msgs.count) { _, _ in model.markRead(peer) }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
            Button {
                model.send(draft, to: peer)
                draft = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}

private struct Bubble: View {
    let message: Message
    let onRetry: () -> Void

    var body: some View {
        HStack {
            if message.outgoing { Spacer(minLength: 48) }
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundStyle(message.outgoing ? .white : .primary)
                    .background(RoundedRectangle(cornerRadius: 16)
                        .fill(message.outgoing ? Color.blue : Color(.secondarySystemBackground)))
                if message.outgoing && message.status != .sent {
                    if message.status == .failed {
                        Button("Not sent — tap to retry", action: onRetry)
                            .font(.caption2).foregroundStyle(.red)
                    } else {
                        Text("Sending…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !message.outgoing { Spacer(minLength: 48) }
        }
    }
}
