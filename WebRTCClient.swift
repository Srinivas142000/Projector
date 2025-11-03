import Foundation
import WebRTC
import SocketIO

class WebRTCClient: NSObject {
    private let rtcAudioSession = RTCAudioSession.sharedInstance()
    private let audioQueue = DispatchQueue(label: "audio")
    private let videoQueue = DispatchQueue(label: "video")
    
    private var peerConnection: RTCPeerConnection?
    private var videoCapturer: RTCCameraVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    private var remoteVideoTrack: RTCVideoTrack?
    
    private let factory: RTCPeerConnectionFactory
    private let socketManager: SocketManager
    private var socket: SocketIOClient
    
    var delegate: WebRTCClientDelegate?
    private var roomId: String
    private var serverURL: String
    
    // ICE servers configuration
    private let config: RTCConfiguration = {
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])
        ]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        return config
    }()
    
    init(serverURL: String, roomId: String) {
        self.serverURL = serverURL
        self.roomId = roomId
        
        // Initialize WebRTC factory
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
        
        // Initialize Socket.IO
        guard let url = URL(string: serverURL) else {
            fatalError("Invalid server URL")
        }
        socketManager = SocketManager(socketURL: url, config: [.log(false), .compress])
        socket = socketManager.defaultSocket
        
        super.init()
        
        setupSocketHandlers()
    }
    
    func connect() {
        socket.connect()
    }
    
    func disconnect() {
        socket.disconnect()
        peerConnection?.close()
        peerConnection = nil
    }
    
    private func setupSocketHandlers() {
        socket.on(clientEvent: .connect) { [weak self] data, ack in
            print("Socket connected")
            self?.socket.emit("join-room", self?.roomId ?? "")
            self?.delegate?.didConnect()
        }
        
        socket.on(clientEvent: .disconnect) { [weak self] data, ack in
            print("Socket disconnected")
            self?.delegate?.didDisconnect()
        }
        
        socket.on("user-connected") { [weak self] data, ack in
            guard let self = self,
                  let userId = data[0] as? String else { return }
            print("User connected: \(userId)")
            Task {
                await self.createOffer(to: userId)
            }
        }
        
        socket.on("offer") { [weak self] data, ack in
            guard let self = self,
                  let dict = data[0] as? [String: Any],
                  let offerDict = dict["offer"] as? [String: Any],
                  let senderId = dict["sender"] as? String else { return }
            
            print("Received offer from: \(senderId)")
            Task {
                await self.handleOffer(offerDict, from: senderId)
            }
        }
        
        socket.on("answer") { [weak self] data, ack in
            guard let self = self,
                  let dict = data[0] as? [String: Any],
                  let answerDict = dict["answer"] as? [String: Any] else { return }
            
            print("Received answer")
            Task {
                await self.handleAnswer(answerDict)
            }
        }
        
        socket.on("ice-candidate") { [weak self] data, ack in
            guard let self = self,
                  let dict = data[0] as? [String: Any],
                  let candidateDict = dict["candidate"] as? [String: Any] else { return }
            
            print("Received ICE candidate")
            Task {
                await self.handleIceCandidate(candidateDict)
            }
        }
    }
    
    func startCapture() {
        configureAudioSession()
        setupLocalTracks()
        setupPeerConnection()
    }
    
    private func configureAudioSession() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            self.rtcAudioSession.lockForConfiguration()
            do {
                try self.rtcAudioSession.setCategory(.playAndRecord, mode: .videoChat, options: [])
                try self.rtcAudioSession.setActive(true)
            } catch {
                print("Error configuring audio session: \(error)")
            }
            self.rtcAudioSession.unlockForConfiguration()
        }
    }
    
    private func setupLocalTracks() {
        // Audio track
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: audioConstraints)
        localAudioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        
        // Video track
        let videoSource = factory.videoSource()
        videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
        localVideoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
        
        // Start camera capture
        startCameraCapture()
    }
    
    private func startCameraCapture() {
        guard let capturer = videoCapturer else { return }
        
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let frontCamera = devices.first(where: { $0.position == .front }) else {
            print("No front camera available")
            return
        }
        
        let formats = RTCCameraVideoCapturer.supportedFormats(for: frontCamera)
        guard let format = formats.last else { return }
        
        let fps = format.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30
        
        capturer.startCapture(with: frontCamera, format: format, fps: Int(fps)) { error in
            if let error = error {
                print("Error starting camera: \(error)")
            }
        }
    }
    
    private func setupPeerConnection() {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        
        // Add tracks to peer connection
        if let audioTrack = localAudioTrack {
            peerConnection?.add(audioTrack, streamIds: ["stream0"])
        }
        
        if let videoTrack = localVideoTrack {
            peerConnection?.add(videoTrack, streamIds: ["stream0"])
        }
    }
    
    private func createOffer(to userId: String) async {
        guard let peerConnection = peerConnection else { return }
        
        do {
            let offer = try await peerConnection.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            try await peerConnection.setLocalDescription(offer)
            
            let offerDict: [String: Any] = [
                "type": offer.type.rawValue,
                "sdp": offer.sdp
            ]
            
            socket.emit("offer", [
                "target": userId,
                "offer": offerDict
            ])
        } catch {
            print("Error creating offer: \(error)")
        }
    }
    
    private func handleOffer(_ offerDict: [String: Any], from senderId: String) async {
        guard let peerConnection = peerConnection,
              let type = offerDict["type"] as? String,
              let sdp = offerDict["sdp"] as? String else { return }
        
        let rtcType = RTCSdpType(rawValue: type) ?? .offer
        let sessionDescription = RTCSessionDescription(type: rtcType, sdp: sdp)
        
        do {
            try await peerConnection.setRemoteDescription(sessionDescription)
            
            let answer = try await peerConnection.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            try await peerConnection.setLocalDescription(answer)
            
            let answerDict: [String: Any] = [
                "type": answer.type.rawValue,
                "sdp": answer.sdp
            ]
            
            socket.emit("answer", [
                "target": senderId,
                "answer": answerDict
            ])
        } catch {
            print("Error handling offer: \(error)")
        }
    }
    
    private func handleAnswer(_ answerDict: [String: Any]) async {
        guard let peerConnection = peerConnection,
              let type = answerDict["type"] as? String,
              let sdp = answerDict["sdp"] as? String else { return }
        
        let rtcType = RTCSdpType(rawValue: type) ?? .answer
        let sessionDescription = RTCSessionDescription(type: rtcType, sdp: sdp)
        
        do {
            try await peerConnection.setRemoteDescription(sessionDescription)
        } catch {
            print("Error setting remote description: \(error)")
        }
    }
    
    private func handleIceCandidate(_ candidateDict: [String: Any]) async {
        guard let peerConnection = peerConnection,
              let sdp = candidateDict["candidate"] as? String,
              let sdpMLineIndex = candidateDict["sdpMLineIndex"] as? Int32,
              let sdpMid = candidateDict["sdpMid"] as? String else { return }
        
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        
        do {
            try await peerConnection.add(candidate)
        } catch {
            print("Error adding ICE candidate: \(error)")
        }
    }
    
    deinit {
        disconnect()
        RTCCleanupSSL()
    }
}

// MARK: - RTCPeerConnectionDelegate
extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("Signaling state changed: \(stateChanged.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("Stream added")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("Stream removed")
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("Negotiation needed")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("ICE connection state: \(newState.rawValue)")
        
        DispatchQueue.main.async { [weak self] in
            switch newState {
            case .connected:
                self?.delegate?.didConnect()
            case .disconnected, .failed, .closed:
                self?.delegate?.didDisconnect()
            default:
                break
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("ICE gathering state: \(newState.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let candidateDict: [String: Any] = [
            "candidate": candidate.sdp,
            "sdpMLineIndex": candidate.sdpMLineIndex,
            "sdpMid": candidate.sdpMid ?? ""
        ]
        
        socket.emit("ice-candidate", [
            "target": "", // Will be broadcast to all in room
            "candidate": candidateDict
        ])
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        print("ICE candidates removed")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("Data channel opened")
    }
}

// MARK: - Delegate Protocol
protocol WebRTCClientDelegate: AnyObject {
    func didConnect()
    func didDisconnect()
}