import Foundation
import WebRTC
import AVFoundation

protocol WebRTCClientDelegate: AnyObject {
    func webRTCClient(_ client: WebRTCClient, didDiscoverLocalCandidate candidate: RTCIceCandidate)
    func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState)
    func webRTCClient(_ client: WebRTCClient, didReceiveData data: Data)
    func webRTCClient(_ client: WebRTCClient, didReceiveRemoteVideoTrack track: RTCVideoTrack)
}

final class WebRTCClient: NSObject {

    // The IceServers provided by the user
    private static let iceServers: [String] = [
        Config.stunServerUrl,
        Config.turnServerUrl
    ]

    private var peerConnection: RTCPeerConnection?

    // Media
    private let mediaConstrains = [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                                   kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue]
    private var videoCapturer: RTCVideoCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private var remoteVideoTrack: RTCVideoTrack?
    private var localVideoSource: RTCVideoSource?
    private var sourceAdapter: VideoSourceAdapter? // Keep strong reference

    weak var delegate: WebRTCClientDelegate?
    
    // Perfect Negotiation pattern properties
    var isPolite: Bool = true  // Will be set by signaling server
    private var makingOffer: Bool = false
    private var ignoreOffer: Bool = false

    override init() {
        super.init()
        print("🚀 WebRTCClient initializing...")
        setup()
    }

    // MARK: - Setup
    private func setup() {
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: [Config.stunServerUrl]),
            RTCIceServer(urlStrings: [Config.turnServerUrl], username: Config.turnUsername, credential: Config.turnPassword)
        ]

        // Unified plan is the modern standard
        config.sdpSemantics = .unifiedPlan

        // Enable SRTP
        config.enableDscp = true

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        self.peerConnection = ConnectionFactory.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        print("✅ PeerConnection created")

        self.setupLocalMedia()
    }

    private func setupLocalMedia() {
        print("📹 Setting up local media...")

        // Audio
        let audioConstrains = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = ConnectionFactory.factory.audioSource(with: audioConstrains)
        let audioTrack = ConnectionFactory.factory.audioTrack(with: audioSource, trackId: "audio0")
        audioTrack.isEnabled = true

        self.peerConnection?.add(audioTrack, streamIds: ["stream0"])
        print("🎤 Audio track added to peer connection")

        // Video
        let videoSource = ConnectionFactory.factory.videoSource()
        self.localVideoSource = videoSource

        #if targetEnvironment(simulator)
        self.videoCapturer = RTCFileVideoCapturer(delegate: videoSource)
        print("⚠️ Running on simulator - camera not available")
        #else
        // Create an adapter to track frame delivery
        let adapter = VideoSourceAdapter(videoSource: videoSource)
        self.sourceAdapter = adapter
        self.videoCapturer = RTCCameraVideoCapturer(delegate: adapter)
        print("📹 Created camera capturer with VIDEO SOURCE ADAPTER for frame tracking")
        #endif

        // Adapt output format to ensure we don't send 4K video
        // This is often the cause of black screens if the renderer/encoder can't handle high res
        videoSource.adaptOutputFormat(toWidth: 640, height: 480, fps: 30)
        print("📹 Video source adapted to 640x480 @ 30fps")

        let videoTrack = ConnectionFactory.factory.videoTrack(with: videoSource, trackId: "video0")
        videoTrack.isEnabled = true
        self.localVideoTrack = videoTrack

        self.peerConnection?.add(videoTrack, streamIds: ["stream0"])
        print("📹 Video track added to peer connection, isEnabled: \(videoTrack.isEnabled)")

        // Request camera permission and start capture
        #if !targetEnvironment(simulator)
        requestCameraPermissionAndStartCapture()
        #endif
    }

    private func requestCameraPermissionAndStartCapture() {
        print("🔐 Requesting camera permission...")

        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        print("🔐 Current camera authorization status: \(cameraStatus.rawValue)")

        switch cameraStatus {
        case .authorized:
            print("✅ Camera already authorized")
            if let cameraCapturer = self.videoCapturer as? RTCCameraVideoCapturer {
                self.startCameraCapture(with: cameraCapturer)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    print("✅ Camera permission granted")
                    DispatchQueue.main.async {
                        if let cameraCapturer = self?.videoCapturer as? RTCCameraVideoCapturer {
                            self?.startCameraCapture(with: cameraCapturer)
                        }
                    }
                } else {
                    print("❌ Camera permission denied by user")
                }
            }
        case .denied, .restricted:
            print("❌ Camera permission denied or restricted. Please enable in Settings.")
        @unknown default:
            print("❌ Unknown camera authorization status")
        }
    }

    private func startCameraCapture(with capturer: RTCCameraVideoCapturer) {
        let devices = RTCCameraVideoCapturer.captureDevices()
        print("📹 Available cameras: \(devices.count)")

        guard let frontCamera = devices.first(where: { $0.position == .front }) ?? devices.first else {
            print("❌ No camera found!")
            return
        }

        print("📹 Using camera: \(frontCamera.localizedName)")

        let formats = RTCCameraVideoCapturer.supportedFormats(for: frontCamera)
        print("📹 Found \(formats.count) formats")

        // Find the format closest to 640x480, which is widely compatible
        let targetWidth: Int32 = 640
        let targetHeight: Int32 = 480

        // Select a format that supports the target resolution
        var selectedFormat: AVCaptureDevice.Format?

        // Try to verify we aren't picking a weird format
        selectedFormat = formats.first { format in
             let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
             // Simple check for reliable VGA-like resolution
             return dimensions.width == targetWidth && dimensions.height == targetHeight
        }

        // Fallback or detailed search
        if selectedFormat == nil {
             selectedFormat = formats.min { (f1, f2) -> Bool in
                let d1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
                let d2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription)
                let diff1 = abs(d1.width - targetWidth) + abs(d1.height - targetHeight)
                let diff2 = abs(d2.width - targetWidth) + abs(d2.height - targetHeight)
                return diff1 < diff2
            }
        }

        guard let format = selectedFormat else {
            print("❌ No suitable format found!")
            return
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        print("📹 Selected format: \(dimensions.width)x\(dimensions.height)")

        let fps = 30
        print("📹 Starting capture at \(fps) FPS...")
        print("📹 Video source state before capture: \(String(describing: self.localVideoSource?.state.rawValue))")

        capturer.startCapture(with: frontCamera, format: format, fps: fps) { [weak self] error in
            if let error = error {
                print("❌ Camera capture failed: \(error.localizedDescription)")
            } else {
                print("✅ Camera capture started successfully! (Format: \(dimensions.width)x\(dimensions.height) @ \(fps)fps)")

                // Schedule a delayed check to verify frames are flowing
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    if let adapter = self?.sourceAdapter {
                        let count = adapter.totalFrameCount
                        if count > 0 {
                            print("📹 ✅ CAPTURE VERIFICATION: \(count) frames captured after 2 seconds - camera is working!")
                        } else {
                            print("📹 ⚠️⚠️⚠️ CAPTURE WARNING: 0 frames captured after 2 seconds! Camera may not be delivering frames!")
                            print("📹 ⚠️ Checking capturer state...")
                            print("📹 Video source: \(self?.localVideoSource != nil ? "exists" : "nil")")
                            print("📹 Source adapter: \(self?.sourceAdapter != nil ? "exists" : "nil")")
                            print("📹 Capturer: \(self?.videoCapturer != nil ? "exists" : "nil")")
                        }
                    }
                }

                // Second check at 5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                    if let adapter = self?.sourceAdapter {
                        let count = adapter.totalFrameCount
                        print("📹 5-second frame count: \(count)")
                    }
                }
            }
        }
    }
    
    // MARK: - Signaling
    func offer(completion: @escaping (_ sdp: RTCSessionDescription) -> Void) {
        self.makingOffer = true
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstrains, optionalConstraints: nil)
        self.peerConnection?.offer(for: constrains, completionHandler: { [weak self] (sdp, error) in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ Error creating offer: \(error)")
                self.makingOffer = false
                return
            }
            guard let sdp = sdp else {
                print("❌ No SDP in offer")
                self.makingOffer = false
                return
            }
            
            print("📤 Created offer SDP")
            self.peerConnection?.setLocalDescription(sdp, completionHandler: { [weak self] (error) in
                guard let self = self else { return }
                self.makingOffer = false
                
                if let error = error {
                    print("❌ Error setting local description: \(error)")
                    return
                }
                print("✅ Local description set")
                completion(sdp)
            })
        })
    }
    
    func answer(completion: @escaping (_ sdp: RTCSessionDescription) -> Void) {
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstrains, optionalConstraints: nil)
        self.peerConnection?.answer(for: constrains, completionHandler: { (sdp, error) in
            if let error = error {
                print("❌ Error creating answer: \(error)")
                return
            }
            guard let sdp = sdp else {
                print("❌ No SDP in answer")
                return
            }
            
            print("📤 Created answer SDP")
            self.peerConnection?.setLocalDescription(sdp, completionHandler: { (error) in
                if let error = error {
                    print("❌ Error setting local description: \(error)")
                    return
                }
                print("✅ Local description set")
                completion(sdp)
            })
        })
    }
    
    func set(remoteSdp: RTCSessionDescription, completion: @escaping (Error?) -> Void) {
        print("📥 Setting remote SDP (type: \(remoteSdp.type.rawValue))")
        
        guard let peerConnection = self.peerConnection else {
            completion(NSError(domain: "WebRTCClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No peer connection"]))
            return
        }
        
        // Perfect Negotiation: Detect offer collision
        let offerCollision = (remoteSdp.type == .offer) && 
            (makingOffer || peerConnection.signalingState != .stable)
        
        // If we're impolite and there's a collision, ignore the incoming offer
        ignoreOffer = !isPolite && offerCollision
        
        if ignoreOffer {
            print("⚠️ [Perfect Negotiation] Ignoring offer - we are IMPOLITE and there's a collision")
            print("⚠️ makingOffer: \(makingOffer), signalingState: \(peerConnection.signalingState.rawValue)")
            completion(nil) // Not an error, just ignoring
            return
        }
        
        // If we're polite and there's a collision, we need to rollback first
        if offerCollision && isPolite {
            print("🔄 [Perfect Negotiation] POLITE peer collision detected - rolling back local offer")
            print("🔄 makingOffer: \(makingOffer), signalingState: \(peerConnection.signalingState.rawValue)")
            
            // Rollback by setting local description to rollback type
            let rollback = RTCSessionDescription(type: .rollback, sdp: "")
            peerConnection.setLocalDescription(rollback) { [weak self] rollbackError in
                if let rollbackError = rollbackError {
                    print("❌ Rollback failed: \(rollbackError)")
                    // Continue anyway, some implementations don't need explicit rollback
                } else {
                    print("✅ Rollback successful, now setting remote offer")
                }
                
                // Now set the remote description
                self?.setRemoteDescriptionInternal(remoteSdp, completion: completion)
            }
        } else {
            // No collision, just set the remote description normally
            setRemoteDescriptionInternal(remoteSdp, completion: completion)
        }
    }
    
    private func setRemoteDescriptionInternal(_ remoteSdp: RTCSessionDescription, completion: @escaping (Error?) -> Void) {
        self.peerConnection?.setRemoteDescription(remoteSdp, completionHandler: { error in
            if let error = error {
                print("❌ Error setting remote description: \(error)")
            } else {
                print("✅ Remote description set successfully")
            }
            completion(error)
        })
    }
    
    func set(remoteCandidate: RTCIceCandidate) {
        print("📥 Adding remote ICE candidate: \(remoteCandidate.sdpMid ?? "nil")")
        self.peerConnection?.add(remoteCandidate)
    }
    
    // MARK: - Rendering
    func renderRemoteVideo(to renderer: RTCVideoRenderer) {
        print("📺 Attaching remote renderer...")
        if let track = self.remoteVideoTrack {
            track.add(renderer)
            print("✅ Remote renderer attached to existing track")
        } else {
            print("⚠️ No remote video track yet - renderer will be attached when track arrives")
        }
    }
    
    func renderLocalVideo(to renderer: RTCVideoRenderer) {
        print("📺 Attaching local renderer...")
        if let track = self.localVideoTrack {
            track.add(renderer)
            print("✅ Local renderer attached, track enabled: \(track.isEnabled)")
        } else {
            print("❌ No local video track available!")
        }
    }
    
    // Expose local video track for external access
    func getLocalVideoTrack() -> RTCVideoTrack? {
        return self.localVideoTrack
    }
}

// MARK: - RTCPeerConnectionDelegate
extension WebRTCClient: RTCPeerConnectionDelegate {
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("📡 Signaling State Changed: \(stateChanged.rawValue)")
    }
    
    // IMPORTANT: This is the modern callback for unified plan - more reliable than didAdd stream
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        print("📥 RTP Receiver added")
        print("📥 Track kind: \(rtpReceiver.track?.kind ?? "nil")")
        print("📥 Track ID: \(rtpReceiver.track?.trackId ?? "nil")")
        print("📥 Streams count: \(streams.count)")
        
        if let videoTrack = rtpReceiver.track as? RTCVideoTrack {
            print("📹 ✅ REMOTE VIDEO TRACK RECEIVED!")
            print("📹 Video track enabled: \(videoTrack.isEnabled)")
            print("📹 Video track ready state: \(videoTrack.readyState.rawValue)")
            
            // Ensure track is enabled
            videoTrack.isEnabled = true
            
            self.remoteVideoTrack = videoTrack
            

            
            DispatchQueue.main.async {
                self.delegate?.webRTCClient(self, didReceiveRemoteVideoTrack: videoTrack)
            }
        } else if let audioTrack = rtpReceiver.track as? RTCAudioTrack {
            print("🎤 Remote audio track received")
            print("🎤 Audio track enabled: \(audioTrack.isEnabled)")
            // Ensure audio is enabled
            audioTrack.isEnabled = true
        }
    }
    
    // Keep this for backwards compatibility, but the above method is preferred
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("📥 Stream added (legacy callback): \(stream.streamId)")
        print("📥 Video tracks in stream: \(stream.videoTracks.count)")
        print("📥 Audio tracks in stream: \(stream.audioTracks.count)")
        
        // Only use this as fallback if didAdd receiver didn't fire
        if self.remoteVideoTrack == nil, let track = stream.videoTracks.first {
            print("📹 Remote video track found via legacy callback")
            self.remoteVideoTrack = track
            DispatchQueue.main.async {
                self.delegate?.webRTCClient(self, didReceiveRemoteVideoTrack: track)
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("📤 Stream removed: \(stream.streamId)")
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("🔄 Should negotiate")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("🧊 ICE Connection State: \(newState.rawValue)")
        switch newState {
        case .checking:
            print("🧊 ICE: Checking...")
        case .connected:
            print("🧊 ✅ ICE: Connected!")
        case .completed:
            print("🧊 ✅ ICE: Completed!")
        case .failed:
            print("🧊 ❌ ICE: Failed!")
        case .disconnected:
            print("🧊 ⚠️ ICE: Disconnected")
        case .closed:
            print("🧊 ICE: Closed")
        case .new, .count:
            break
        @unknown default:
            break
        }
        self.delegate?.webRTCClient(self, didChangeConnectionState: newState)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("🧊 ICE Gathering State: \(newState.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("🧊 Generated ICE candidate: \(candidate.sdpMid ?? "nil")")
        self.delegate?.webRTCClient(self, didDiscoverLocalCandidate: candidate)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        print("🧊 ICE candidates removed: \(candidates.count)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("📊 Data channel opened: \(dataChannel.label)")
    }
}

// MARK: - Video Source Adapter for Frame Tracking
// This adapter sits between the camera capturer and video source to track frame delivery
class VideoSourceAdapter: NSObject, RTCVideoCapturerDelegate {
    private let videoSource: RTCVideoSource
    private var frameCount = 0
    private var lastLogTime = Date()
    private var hasLoggedFirstFrame = false
    
    init(videoSource: RTCVideoSource) {
        self.videoSource = videoSource
        super.init()
        print("📹 VideoSourceAdapter initialized")
    }
    
    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        frameCount += 1
        
        // Log the FIRST frame immediately
        if !hasLoggedFirstFrame {
            hasLoggedFirstFrame = true
            print("📹 🎬⭐ FIRST LOCAL FRAME CAPTURED! Size: \(frame.width)x\(frame.height)")
            lastLogTime = Date()
        }
        
        // Log every 30 frames (approximately once per second at 30fps)
        if frameCount % 30 == 0 {
            let now = Date()
            let elapsed = now.timeIntervalSince(lastLogTime)
            let fps = elapsed > 0 ? 30.0 / elapsed : 0
            print("📹 🎬 FRAMES FLOWING: \(frameCount) total, ~\(Int(fps)) fps, size: \(frame.width)x\(frame.height)")
            lastLogTime = now
        }
        
        // Forward the frame to the actual video source
        videoSource.capturer(capturer, didCapture: frame)
    }
    
    var totalFrameCount: Int {
        return frameCount
    }
}



// Global factory
class ConnectionFactory {
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        print("🏭 RTCPeerConnectionFactory created with video encoder/decoder")
        return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
    }()
}

