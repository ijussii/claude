import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    LabeledContent("Username", value: model.identity?.username ?? "")
                    LabeledContent("Server", value: model.isConnected ? "Connected" : "Offline")
                }
                Section {
                    Button("Delete account from this device", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Your username and keys exist only on this device. Deleting them cannot be undone, and nobody — including the server — can restore your messages or account.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete this account from the device?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { dismiss(); model.signOut() }
            }
        }
    }
}
