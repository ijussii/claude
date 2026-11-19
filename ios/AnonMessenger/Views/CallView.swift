import SwiftUI

struct CallView: View {
    @EnvironmentObject var calls: CallManager

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemIndigo), Color(.black)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 110))
                    .foregroundStyle(.white.opacity(0.85))
                Text(calls.peer).font(.largeTitle.bold()).foregroundStyle(.white)
                status.font(.title3).foregroundStyle(.white.opacity(0.8))
                Spacer()
                controls.padding(.bottom, 40)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch calls.phase {
        case .outgoingRinging: Text("Calling…")
        case .incomingRinging: Text("Incoming call")
        case .connecting: Text("Connecting…")
        case .connected:
            if let start = calls.connectedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let s = max(0, Int(ctx.date.timeIntervalSince(start)))
                    Text(String(format: "%02d:%02d", s / 60, s % 60)).monospacedDigit()
                }
            }
        case .idle: EmptyView()
        }
    }

    @ViewBuilder private var controls: some View {
        if calls.phase == .incomingRinging {
            HStack(spacing: 70) {
                circle("phone.down.fill", .red, "Decline") { calls.decline() }
                circle("phone.fill", .green, "Accept") { Task { await calls.accept() } }
            }
        } else {
            HStack(spacing: 40) {
                toggle("mic.slash.fill", "Mute", on: calls.isMuted) { calls.toggleMute() }
                circle("phone.down.fill", .red, "End") { calls.hangUp() }
                toggle("speaker.wave.3.fill", "Speaker", on: calls.isSpeaker) { calls.toggleSpeaker() }
            }
        }
    }

    private func circle(_ icon: String, _ color: Color, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title).foregroundStyle(.white)
                .frame(width: 72, height: 72).background(Circle().fill(color))
        }
        .accessibilityLabel(label)
    }

    private func toggle(_ icon: String, _ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2)
                .foregroundStyle(on ? .black : .white)
                .frame(width: 60, height: 60)
                .background(Circle().fill(on ? Color.white : Color.white.opacity(0.2)))
        }
        .accessibilityLabel(label)
    }
}
