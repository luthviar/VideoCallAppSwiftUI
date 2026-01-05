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
    private var customCameraCapturer: CustomCameraCapturer? // Custom capturer for reliable capture
    private var debugRemoteRenderer: DebugVideoRenderer? // Debug renderer to track remote frame delivery
    private var debugLocalRenderer: DebugVideoRenderer? // Debug renderer to track local frame delivery

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

        // Video - use custom capturer for reliable frame delivery
        let videoSource = ConnectionFactory.factory.videoSource()
        self.localVideoSource = videoSource

        #if targetEnvironment(simulator)
        self.videoCapturer = RTCFileVideoCapturer(delegate: videoSource)
        print("⚠️ Running on simulator - camera not available")
        #else
        // Use custom camera capturer that manually handles AVCaptureSession
        // This is more reliable than RTCCameraVideoCapturer on some iOS versions
        let customCapturer = CustomCameraCapturer(videoSource: videoSource)
        self.customCameraCapturer = customCapturer
        print("📹 Created CUSTOM camera capturer for reliable frame delivery")
        #endif

        let videoTrack = ConnectionFactory.factory.videoTrack(with: videoSource, trackId: "video0")
        videoTrack.isEnabled = true
        self.localVideoTrack = videoTrack

        // Add debug renderer to LOCAL track to verify frames are reaching the track
        let debugLocal = DebugVideoRenderer(label: "LOCAL")
        self.debugLocalRenderer = debugLocal
        videoTrack.add(debugLocal)
        print("📹 Debug renderer attached to LOCAL video track")

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
            startCustomCameraCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    print("✅ Camera permission granted")
                    DispatchQueue.main.async {
                        self?.startCustomCameraCapture()
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

    private func startCustomCameraCapture() {
        guard let capturer = customCameraCapturer else {
            print("❌ Custom camera capturer not initialized!")
            return
        }

        capturer.startCapture()
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
            
            // Add debug renderer to check if frames are arriving
            let debugRenderer = DebugVideoRenderer(label: "REMOTE")
            self.debugRemoteRenderer = debugRenderer
            videoTrack.add(debugRenderer)
            print("📹 Debug renderer attached to remote track to monitor frame delivery")
            
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

// MARK: - Custom Camera Capturer using AVFoundation directly
// This is more reliable than RTCCameraVideoCapturer on some iOS versions
class CustomCameraCapturer: RTCVideoCapturer {
    private let videoSource: RTCVideoSource
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let sessionQueue = DispatchQueue(label: "com.videocall.camera.session", qos: .userInteractive)
    private let outputQueue = DispatchQueue(label: "com.videocall.camera.output", qos: .userInteractive)

    private var frameCount = 0
    private var lastLogTime = Date()
    private var hasLoggedFirstFrame = false
    private var isCapturing = false

    init(videoSource: RTCVideoSource) {
        self.videoSource = videoSource
        // Initialize RTCVideoCapturer with the video source as delegate
        super.init(delegate: videoSource)
        print("📹 CustomCameraCapturer initialized (extends RTCVideoCapturer)")
    }

    func startCapture() {
        sessionQueue.async { [weak self] in
            self?.setupAndStartCapture()
        }
    }

    private func setupAndStartCapture() {
        print("📹 [CustomCapturer] Setting up AVCaptureSession...")

        // Create capture session
        let session = AVCaptureSession()
        session.beginConfiguration()

        // Set session preset for optimal performance
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
            print("📹 [CustomCapturer] Set session preset to VGA 640x480")
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
            print("📹 [CustomCapturer] Set session preset to medium")
        }

        // Find front camera
        guard let camera = findFrontCamera() else {
            print("❌ [CustomCapturer] No front camera found!")
            session.commitConfiguration()
            return
        }
        print("📹 [CustomCapturer] Using camera: \(camera.localizedName)")

        // Create and add camera input
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
                print("📹 [CustomCapturer] Added camera input")
            } else {
                print("❌ [CustomCapturer] Cannot add camera input!")
                session.commitConfiguration()
                return
            }
        } catch {
            print("❌ [CustomCapturer] Error creating camera input: \(error)")
            session.commitConfiguration()
            return
        }

        // Create and configure video output
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
            print("📹 [CustomCapturer] Added video output")

            // Configure video orientation
            if let connection = output.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                    print("📹 [CustomCapturer] Set video orientation to portrait")
                }
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                    print("📹 [CustomCapturer] Enabled video mirroring for front camera")
                }
            }
        } else {
            print("❌ [CustomCapturer] Cannot add video output!")
            session.commitConfiguration()
            return
        }

        session.commitConfiguration()
        self.captureSession = session
        self.videoOutput = output

        print("📹 [CustomCapturer] Starting capture session...")
        session.startRunning()

        // Verify session is running
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if let session = self?.captureSession {
                let isRunning = session.isRunning
                print("📹 [CustomCapturer] Session running check: \(isRunning ? "✅ YES" : "❌ NO")")
                if isRunning {
                    self?.isCapturing = true
                    print("📹 [CustomCapturer] ✅ Capture session started successfully!")
                }
            }
        }

        // Delayed frame count check
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            let count = self.frameCount
            if count > 0 {
                print("📹 [CustomCapturer] ✅ CAPTURE VERIFIED: \(count) frames after 2 seconds!")
            } else {
                print("📹 [CustomCapturer] ⚠️ WARNING: 0 frames after 2 seconds!")
                print("📹 [CustomCapturer] Session running: \(self.captureSession?.isRunning ?? false)")
                print("📹 [CustomCapturer] Output: \(self.videoOutput != nil ? "exists" : "nil")")
            }
        }

        // 5 second check
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            print("📹 [CustomCapturer] 5-second frame count: \(self.frameCount)")
        }
    }

    private func findFrontCamera() -> AVCaptureDevice? {
        // Try discovery session first (iOS 10+)
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        )

        if let device = discoverySession.devices.first {
            print("📹 [CustomCapturer] Found front camera via discovery session")
            return device
        }

        // Fallback to default device
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            print("📹 [CustomCapturer] Found front camera via default")
            return device
        }

        // Last resort: any camera
        print("📹 [CustomCapturer] ⚠️ No front camera, trying any camera...")
        return AVCaptureDevice.default(for: .video)
    }

    func stopCapture() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            self?.isCapturing = false
            print("📹 [CustomCapturer] Stopped capture session")
        }
    }

    var totalFrameCount: Int {
        return frameCount
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CustomCameraCapturer: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Get pixel buffer from sample buffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("📹 [CustomCapturer] ⚠️ No pixel buffer in sample!")
            return
        }

        frameCount += 1

        // Get timestamp
        let timeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeStampNs = Int64(CMTimeGetSeconds(timeStamp) * Double(NSEC_PER_SEC))

        // Log first frame
        if !hasLoggedFirstFrame {
            hasLoggedFirstFrame = true
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            print("📹 [CustomCapturer] 🎬⭐ FIRST FRAME CAPTURED! Size: \(width)x\(height)")
            lastLogTime = Date()
        }

        // Log every 30 frames
        if frameCount % 30 == 0 {
            let now = Date()
            let elapsed = now.timeIntervalSince(lastLogTime)
            let fps = elapsed > 0 ? 30.0 / elapsed : 0
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            print("📹 [CustomCapturer] 🎬 FRAMES: \(frameCount) total, ~\(Int(fps)) fps, \(width)x\(height)")
            lastLogTime = now
        }

        // Create RTCCVPixelBuffer from the pixel buffer
        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)

        // Create RTCVideoFrame with the pixel buffer
        let rtcFrame = RTCVideoFrame(
            buffer: rtcPixelBuffer,
            rotation: ._0,
            timeStampNs: timeStampNs
        )

        // Send frame to the video source via the delegate (self is the capturer)
        // This properly routes through RTCVideoCapturer's delegate mechanism
        self.delegate?.capturer(self, didCapture: rtcFrame)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        print("📹 [CustomCapturer] ⚠️ Frame dropped!")
    }
}

// MARK: - Debug Video Renderer to track frame delivery
// This renderer logs when frames arrive to help diagnose rendering issues
class DebugVideoRenderer: NSObject, RTCVideoRenderer {
    private let label: String
    private var frameCount = 0
    private var lastLogTime = Date()
    private var hasLoggedFirstFrame = false
    
    init(label: String) {
        self.label = label
        super.init()
        print("📺 DebugVideoRenderer[\(label)] initialized")
    }
    
    func setSize(_ size: CGSize) {
        print("📺 🎉🎉🎉 DebugVideoRenderer[\(label)] setSize called: \(size.width)x\(size.height) - FRAMES WILL ARRIVE!")
    }
    
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame = frame else { return }
        frameCount += 1

        // Log the FIRST frame immediately
        if !hasLoggedFirstFrame {
            hasLoggedFirstFrame = true
            print("📺 ⭐⭐⭐ DebugVideoRenderer[\(label)] FIRST FRAME! Size: \(frame.width)x\(frame.height)")
            lastLogTime = Date()
        }

        // Log every 30 frames
        if frameCount % 30 == 0 {
            let now = Date()
            let elapsed = now.timeIntervalSince(lastLogTime)
            let fps = elapsed > 0 ? 30.0 / elapsed : 0
            print("📺 🎬 DebugVideoRenderer[\(label)] FRAMES: \(frameCount) total, ~\(Int(fps)) fps, \(frame.width)x\(frame.height)")
            lastLogTime = now
        }
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

