import SwiftUI

struct NewChatView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onPick: (String) -> Void

    @State private var username = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("their username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: username) { _, v in username = v.lowercased(); error = nil }
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await start() }
                    } label: {
                        if busy { ProgressView() } else { Text("Start chat") }
                    }
                    .disabled(!AppModel.isValidUsername(username) || busy)
                }
            }
            .navigationTitle("New chat")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func start() async {
        guard username != model.identity?.username else { error = "That's you."; return }
        busy = true; defer { busy = false }
        guard model.isConnected else { error = "Not connected to the server yet."; return }
        if await model.userExists(username) {
            dismiss()
            onPick(username)
        } else {
            error = "No user called “\(username)”."
        }
    }
}
