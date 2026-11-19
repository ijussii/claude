import Foundation
import AVFoundation
import WebRTC

enum CallPhase: Equatable {
    case idle
    case outgoingRinging
    case incomingRinging
    case connecting
    case connected
}

/// One-to-one voice calls. Audio travels peer-to-peer over WebRTC (so over Wi-Fi when both
/// phones are on it); the relay server only carries the small signaling messages below:
///
///   caller                       callee
///   invite  ───────────────────▶ rings
///           ◀─────────────────── accept            (or reject)
///   sdp(offer) ────────────────▶
///           ◀─────────────────── sdp(answer)
///   ice ◀──────────────────────▶ ice
///   end ◀──────────────────────▶ end
@MainActor
final class CallManager: NSObject, ObservableObject {
    @Published private(set) var phase: CallPhase = .idle
    @Published private(set) var peer = ""
    @Published private(set) var isMuted = false
    @Published private(set) var isSpeaker = false
    @Published private(set) var connectedAt: Date?
    @Published var notice: String?

    private let relay: RelayClient
    private var callId = ""
    private var pc: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var pendingCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false
    private var ringTimeout: Task<Void, Never>?
    private var connectTimeout: Task<Void, Never>?

    private static let factory = RTCPeerConnectionFactory()

    init(relay: RelayClient) {
        self.relay = relay
        super.init()
    }

    // MARK: - User actions

    func startCall(to peer: String) async {
        guard phase == .idle else { return }
        guard await Self.micPermission() else {
            notice = "Allow microphone access in Settings to make calls."
            return
        }
        guard phase == .idle else { return }   // state may have changed while the permission sheet was up
        self.peer = peer
        callId = UUID().uuidString
        phase = .outgoingRinging
        signal("invite")
        armRingTimeout()
    }

    func accept() async {
        guard phase == .incomingRinging else { return }
        guard await Self.micPermission() else {
            notice = "Allow microphone access in Settings to answer calls."
            decline()
            return
        }
        guard phase == .incomingRinging else { return }   // caller may have hung up meanwhile
        ringTimeout?.cancel()
        phase = .connecting
        configureAudioSession()
        createPeerConnection()
        signal("accept")
    }

    func decline() {
        guard phase != .idle else { return }
        signal("reject")
        reset()
    }

    func hangUp() {
        guard phase != .idle else { return }
        signal("end")
        reset()
    }

    func toggleMute() {
        isMuted.toggle()
        audioTrack?.isEnabled = !isMuted
    }

    func toggleSpeaker() {
        isSpeaker.toggle()
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(isSpeaker ? .speaker : .none)
    }

    // MARK: - Signaling in

    func handleSignal(from: String, callId id: String, kind: String, data: [String: Any]?) {
        if kind == "invite" {
            guard phase == .idle else {
                // Busy: politely refuse without disturbing the current call.
                relay.send(["t": "call", "to": from, "callId": id, "kind": "reject"])
                return
            }
            peer = from
            callId = id
            phase = .incomingRinging
            armRingTimeout()
            return
        }

        guard phase != .idle, id == callId, from == peer else { return }

        switch kind {
        case "accept":
            guard phase == .outgoingRinging else { return }
            ringTimeout?.cancel()
            phase = .connecting
            configureAudioSession()
            createPeerConnection()
            makeOffer()
        case "reject":
            finish(notice: "\(peer) declined the call.")
        case "unavailable":
            finish(notice: "\(peer) isn't online right now.")
        case "end":
            finish(notice: phase == .incomingRinging ? "Missed call from \(peer)." : nil)
        case "sdp":
            handleSDP(data)
        case "ice":
            handleICE(data)
        default:
            break
        }
    }

    // MARK: - Signaling out

    private func signal(_ kind: String, _ data: [String: Any]? = nil) {
        var message: [String: Any] = ["t": "call", "to": peer, "callId": callId, "kind": kind]
        if let data { message["data"] = data }
        relay.send(message)
    }

    private func sendSDP(_ sdp: RTCSessionDescription) {
        signal("sdp", ["type": sdp.type == .offer ? "offer" : "answer", "sdp": sdp.sdp])
    }

    // MARK: - WebRTC

    private func createPeerConnection() {
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: Config.iceServers)]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])
        pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)

        let source = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = Self.factory.audioTrack(with: source, trackId: "audio0")
        track.isEnabled = !isMuted
        audioTrack = track
        pc?.add(track, streamIds: ["stream0"])

        connectTimeout?.cancel()
        connectTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, self.phase == .connecting else { return }
            self.signal("end")
            self.finish(notice: "Couldn't connect the call.")
        }
    }

    private func makeOffer() {
        let constraints = RTCMediaConstraints(mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue],
                                              optionalConstraints: nil)
        pc?.offer(for: constraints) { [weak self] sdp, error in
            Task { @MainActor in
                guard let self, let pc = self.pc else { return }
                guard let sdp, error == nil else { self.failCall(); return }
                pc.setLocalDescription(sdp) { error in
                    Task { @MainActor in
                        if error != nil { self.failCall() } else { self.sendSDP(sdp) }
                    }
                }
            }
        }
    }

    private func makeAnswer() {
        let constraints = RTCMediaConstraints(mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue],
                                              optionalConstraints: nil)
        pc?.answer(for: constraints) { [weak self] sdp, error in
            Task { @MainActor in
                guard let self, let pc = self.pc else { return }
                guard let sdp, error == nil else { self.failCall(); return }
                pc.setLocalDescription(sdp) { error in
                    Task { @MainActor in
                        if error != nil { self.failCall() } else { self.sendSDP(sdp) }
                    }
                }
            }
        }
    }

    private func handleSDP(_ data: [String: Any]?) {
        guard let type = data?["type"] as? String, let text = data?["sdp"] as? String, let pc else { return }
        let description = RTCSessionDescription(type: type == "offer" ? .offer : .answer, sdp: text)
        pc.setRemoteDescription(description) { [weak self] error in
            Task { @MainActor in
                guard let self, self.pc === pc else { return }
                if error != nil { self.failCall(); return }
                self.hasRemoteDescription = true
                for candidate in self.pendingCandidates { pc.add(candidate) { _ in } }
                self.pendingCandidates.removeAll()
                if description.type == .offer { self.makeAnswer() }
            }
        }
    }

    private func handleICE(_ data: [String: Any]?) {
        guard let sdp = data?["candidate"] as? String else { return }
        let index = Int32((data?["sdpMLineIndex"] as? Int) ?? 0)
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: data?["sdpMid"] as? String)
        if hasRemoteDescription, let pc {
            pc.add(candidate) { _ in }
        } else {
            pendingCandidates.append(candidate)   // arrived before the remote description was applied
        }
    }

    // MARK: - Lifecycle helpers

    private func failCall() {
        signal("end")
        finish(notice: "The call failed.")
    }

    private func armRingTimeout() {
        ringTimeout?.cancel()
        ringTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, let self else { return }
            switch self.phase {
            case .outgoingRinging:
                self.signal("end")
                self.finish(notice: "\(self.peer) didn't answer.")
            case .incomingRinging:
                self.finish(notice: "Missed call from \(self.peer).")
            default:
                break
            }
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        try? session.setActive(true)
    }

    private func finish(notice message: String?) {
        reset()
        if let message { notice = message }
    }

    private func reset() {
        ringTimeout?.cancel(); ringTimeout = nil
        connectTimeout?.cancel(); connectTimeout = nil
        pc?.close()
        pc = nil
        audioTrack = nil
        pendingCandidates.removeAll()
        hasRemoteDescription = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isMuted = false
        isSpeaker = false
        connectedAt = nil
        peer = ""
        callId = ""
        phase = .idle
    }

    private static func micPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}

// MARK: - RTCPeerConnectionDelegate (called on WebRTC's own threads)

extension CallManager: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        var payload: [String: Any] = ["candidate": candidate.sdp, "sdpMLineIndex": Int(candidate.sdpMLineIndex)]
        if let mid = candidate.sdpMid { payload["sdpMid"] = mid }
        Task { @MainActor in
            guard self.pc === peerConnection else { return }
            self.signal("ice", payload)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            guard self.pc === peerConnection else { return }   // ignore callbacks from a previous call
            switch newState {
            case .connected, .completed:
                if self.phase == .connecting {
                    self.connectTimeout?.cancel()
                    self.connectedAt = Date()
                    self.phase = .connected
                }
            case .failed:
                self.signal("end")
                self.finish(notice: "The call connection was lost.")
            default:
                break   // .disconnected is often transient on Wi-Fi; wait for .failed
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
