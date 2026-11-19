import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var calls: CallManager

    var body: some View {
        Group {
            if model.identity == nil { SignUpView() } else { ChatListView() }
        }
        .fullScreenCover(isPresented: Binding(get: { calls.phase != .idle }, set: { _ in })) {
            CallView()
                .environmentObject(model)
                .environmentObject(calls)
        }
        .alert("Call", isPresented: Binding(get: { calls.notice != nil }, set: { if !$0 { calls.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(calls.notice ?? "")
        }
        .alert("Connection", isPresented: Binding(get: { model.sessionProblem != nil }, set: { if !$0 { model.sessionProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.sessionProblem ?? "")
        }
    }
}
