import SwiftUI

struct SignUpView: View {
    @EnvironmentObject var model: AppModel
    @State private var username = ""
    @State private var server = Config.relayURLString
    @State private var busy = false
    @State private var error: String?

    private var valid: Bool { AppModel.isValidUsername(username) && Config.isValidRelay(server) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .onChange(of: username) { _, v in username = v.lowercased() }
                } header: {
                    Text("Pick a username")
                } footer: {
                    Text("3–20 characters: a–z, 0–9, underscore. No email, phone number or password is ever asked for. There is no account recovery: if this device's data is lost, so is the account.")
                }

                Section("Server") {
                    TextField("wss://your-server", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Create account").bold() }
                            Spacer()
                        }
                    }
                    .disabled(!valid || busy)
                }
            }
            .navigationTitle("Welcome")
        }
    }

    private func create() async {
        busy = true; error = nil
        defer { busy = false }
        Config.relayURLString = server
        do {
            try await model.register(username: username)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
