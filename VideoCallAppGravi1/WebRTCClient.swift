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
    private var captureSessionObserver: NSObjectProtocol?
    private var restartAttempts: Int = 0
    private let maxRestartAttempts: Int = 2

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
    
    deinit {
        if let observer = captureSessionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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

        // Video - use forScreenCast:false to indicate this is a camera source
        let videoSource = ConnectionFactory.factory.videoSource(forScreenCast: false)
        self.localVideoSource = videoSource
        print("📹 Created video source, state: \(videoSource.state.rawValue)")

        #if targetEnvironment(simulator)
        self.videoCapturer = RTCFileVideoCapturer(delegate: videoSource)
        print("⚠️ Running on simulator - camera not available")
        #else
        // Create an adapter to track frame delivery
        let adapter = VideoSourceAdapter(videoSource: videoSource)
        self.sourceAdapter = adapter
        self.videoCapturer = RTCCameraVideoCapturer(delegate: adapter)
        print("📹 Created camera capturer with VIDEO SOURCE ADAPTER for frame tracking")
        print("📹 Adapter: \(adapter)")
        print("📹 Capturer: \(String(describing: self.videoCapturer))")
        #endif

        // NOTE: Don't call adaptOutputFormat here - it can conflict with the capture format
        // The format will be determined when startCapture is called
        
        let videoTrack = ConnectionFactory.factory.videoTrack(with: videoSource, trackId: "video0")
        videoTrack.isEnabled = true
        self.localVideoTrack = videoTrack
        print("📹 Created video track: \(videoTrack.trackId), enabled: \(videoTrack.isEnabled)")

        self.peerConnection?.add(videoTrack, streamIds: ["stream0"])
        print("📹 Video track added to peer connection, isEnabled: \(videoTrack.isEnabled)")

        // NOTE: Don't start camera capture here - wait until startCapture() is called
        // This allows the view to be ready before starting the camera
        print("📹 Local media setup complete - call startCapture() to begin camera capture")
    }
    
    // Public method to start camera capture - call this after the view is ready
    func startCapture() {
        print("📹 startCapture() called - initiating camera capture")
        #if !targetEnvironment(simulator)
        requestCameraPermissionAndStartCapture()
        #else
        print("⚠️ Running on simulator - camera not available")
        #endif
    }

    private func requestCameraPermissionAndStartCapture() {
        print("🔐 Requesting camera permission...")

        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        print("🔐 Current camera authorization status: \(cameraStatus.rawValue)")

        switch cameraStatus {
        case .authorized:
            print("✅ Camera already authorized")
            // IMPORTANT: Always start camera capture on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let cameraCapturer = self.videoCapturer as? RTCCameraVideoCapturer {
                    print("📹 Starting camera capture on main thread (authorized path)")
                    self.startCameraCapture(with: cameraCapturer)
                } else {
                    print("❌ videoCapturer is not RTCCameraVideoCapturer: \(String(describing: self.videoCapturer))")
                }
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    print("✅ Camera permission granted")
                    DispatchQueue.main.async {
                        if let cameraCapturer = self?.videoCapturer as? RTCCameraVideoCapturer {
                            print("📹 Starting camera capture on main thread (just-granted path)")
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

        guard let camera = devices.first(where: { $0.position == .front }) ?? devices.first else {
            print("❌ No camera found!")
            return
        }

        print("📹 Using camera: \(camera.localizedName)")
        print("📹 Camera's current active format: \(camera.activeFormat)")
        
        let currentDimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        print("📹 Camera's current resolution: \(currentDimensions.width)x\(currentDimensions.height)")
        
        // Check if device supports multi-cam
        let supportsMultiCam = AVCaptureMultiCamSession.isMultiCamSupported
        print("📹 Device supports MultiCam: \(supportsMultiCam)")

        // Get formats that WebRTC says are supported
        let formats = RTCCameraVideoCapturer.supportedFormats(for: camera)
        print("📹 Found \(formats.count) WebRTC-supported formats")
        
        // Log formats to understand what's available
        print("📹 Available formats (first 10):")
        for (index, format) in formats.prefix(10).enumerated() {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            var maxFps: Float64 = 0
            for range in format.videoSupportedFrameRateRanges {
                maxFps = max(maxFps, range.maxFrameRate)
            }
            let multiCamSupported = format.isMultiCamSupported
            print("📹   [\(index)]: \(dimensions.width)x\(dimensions.height) @ \(Int(maxFps))fps (multiCam: \(multiCamSupported))")
        }
        
        // CRITICAL: Filter to only formats that support MultiCam if the device uses it
        var candidateFormats = formats
        if supportsMultiCam {
            let multiCamFormats = formats.filter { $0.isMultiCamSupported }
            if !multiCamFormats.isEmpty {
                candidateFormats = multiCamFormats
                print("📹 Filtered to \(multiCamFormats.count) MultiCam-compatible formats")
            } else {
                print("📹 ⚠️ No MultiCam-compatible formats found, using all formats")
            }
        }
        
        // Strategy: Find a format with moderate resolution that's known to work
        // Prefer 1280x720 or 640x480 as these are standard and well-supported
        let preferredResolutions: [(Int32, Int32)] = [
            (1280, 720),   // HD
            (960, 540),    // qHD
            (640, 480),    // VGA
            (1920, 1080),  // Full HD (might work on newer devices)
            (640, 360),    // nHD
            (352, 288),    // CIF
        ]
        
        var selectedFormat: AVCaptureDevice.Format?
        var selectedFps: Int = 30
        
        // Try each preferred resolution in order
        for (targetWidth, targetHeight) in preferredResolutions {
            for format in candidateFormats {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                
                if dimensions.width == targetWidth && dimensions.height == targetHeight {
                    // Check FPS support
                    var maxFps: Float64 = 0
                    for range in format.videoSupportedFrameRateRanges {
                        maxFps = max(maxFps, range.maxFrameRate)
                    }
                    
                    if maxFps >= 15 {
                        selectedFormat = format
                        selectedFps = min(Int(maxFps), 30)
                        print("📹 ✅ Found matching format: \(targetWidth)x\(targetHeight) @ \(selectedFps)fps, multiCam: \(format.isMultiCamSupported)")
                        break
                    }
                }
            }
            if selectedFormat != nil { break }
        }
        
        // If no preferred resolution found, pick a reasonable format
        if selectedFormat == nil {
            print("📹 ⚠️ No preferred resolution found, selecting best available...")
            for format in candidateFormats {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                
                // Skip very large or very small formats
                if dimensions.width > 1920 || dimensions.width < 320 {
                    continue
                }
                
                var maxFps: Float64 = 0
                for range in format.videoSupportedFrameRateRanges {
                    maxFps = max(maxFps, range.maxFrameRate)
                }
                
                if maxFps >= 15 {
                    selectedFormat = format
                    selectedFps = min(Int(maxFps), 30)
                    print("📹 Selected fallback format: \(dimensions.width)x\(dimensions.height) @ \(selectedFps)fps")
                    break
                }
            }
        }

        guard let format = selectedFormat else {
            print("❌ No suitable format found!")
            // Last resort: try the first format
            if let firstFormat = candidateFormats.first {
                let dimensions = CMVideoFormatDescriptionGetDimensions(firstFormat.formatDescription)
                print("📹 Using first format as last resort: \(dimensions.width)x\(dimensions.height)")
                startCaptureWithFormat(capturer: capturer, camera: camera, format: firstFormat, fps: 30)
            }
            return
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        print("📹 Final selected format: \(dimensions.width)x\(dimensions.height) @ \(selectedFps)fps")
        
        startCaptureWithFormat(capturer: capturer, camera: camera, format: format, fps: selectedFps)
    }
    
    private func startCaptureWithFormat(capturer: RTCCameraVideoCapturer, camera: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        
        print("📹 Starting capture...")
        print("📹 Video source state: \(String(describing: self.localVideoSource?.state.rawValue))")
        print("📹 Capturer: \(capturer)")
        print("📹 Format dimensions: \(dimensions.width)x\(dimensions.height)")
        
        // CRITICAL: Pre-configure the device's active format BEFORE starting capture
        // This helps avoid the "active format is unsupported" error with AVCaptureMultiCamSession
        do {
            try camera.lockForConfiguration()
            camera.activeFormat = format
            
            // Set frame rate
            let frameDuration = CMTimeMake(value: 1, timescale: Int32(fps))
            camera.activeVideoMinFrameDuration = frameDuration
            camera.activeVideoMaxFrameDuration = frameDuration
            
            camera.unlockForConfiguration()
            print("📹 ✅ Pre-configured camera with format: \(dimensions.width)x\(dimensions.height) @ \(fps)fps")
        } catch {
            print("📹 ⚠️ Failed to pre-configure camera: \(error)")
            // Continue anyway, the capturer might handle it
        }
        
        // Add notification observers for capture session state
        setupCaptureSessionObservers(for: capturer)

        capturer.startCapture(with: camera, format: format, fps: fps) { [weak self] error in
            if let error = error {
                print("❌ Camera capture failed: \(error.localizedDescription)")
                print("❌ Error details: \(error)")
            } else {
                print("✅ Camera capture started successfully! (Format: \(dimensions.width)x\(dimensions.height) @ \(fps)fps)")
                
                // Immediately check capture session state
                DispatchQueue.main.async {
                    print("📹 CaptureSession isRunning: \(capturer.captureSession.isRunning)")
                    print("📹 CaptureSession isInterrupted: \(capturer.captureSession.isInterrupted)")
                }

                // Schedule a delayed check to verify frames are flowing
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self else {
                        print("📹 ⚠️ Self was deallocated!")
                        return
                    }
                    self.verifyCameraCapture(capturer: capturer)
                }

                // Second check at 5 seconds - but don't auto-restart infinitely
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                    guard let self = self else { return }
                    if let adapter = self.sourceAdapter {
                        let count = adapter.totalFrameCount
                        print("📹 5-second frame count: \(count)")
                        if count == 0 && self.restartAttempts < self.maxRestartAttempts {
                            self.restartAttempts += 1
                            print("📹 ⚠️ Still 0 frames at 5 seconds - attempting restart \(self.restartAttempts)/\(self.maxRestartAttempts)...")
                            self.restartCameraCapture()
                        } else if count == 0 {
                            print("📹 ❌ Camera capture failed after \(self.maxRestartAttempts) restart attempts")
                            print("📹 ❌ This may be a device compatibility issue with AVCaptureMultiCamSession")
                        }
                    }
                }
            }
        }
    }
    
    private func setupCaptureSessionObservers(for capturer: RTCCameraVideoCapturer) {
        let session = capturer.captureSession
        
        // Observe capture session start
        captureSessionObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionDidStartRunning,
            object: session,
            queue: .main
        ) { _ in
            print("📹 🟢 AVCaptureSession DID START RUNNING")
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionDidStopRunning,
            object: session,
            queue: .main
        ) { _ in
            print("📹 🔴 AVCaptureSession DID STOP RUNNING")
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session,
            queue: .main
        ) { notification in
            if let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int {
                print("📹 ⚠️ AVCaptureSession WAS INTERRUPTED - reason: \(reason)")
            } else {
                print("📹 ⚠️ AVCaptureSession WAS INTERRUPTED")
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: session,
            queue: .main
        ) { _ in
            print("📹 🟢 AVCaptureSession INTERRUPTION ENDED")
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: .main
        ) { notification in
            if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error {
                print("📹 ❌ AVCaptureSession RUNTIME ERROR: \(error)")
            } else {
                print("📹 ❌ AVCaptureSession RUNTIME ERROR")
            }
        }
    }
    
    private func verifyCameraCapture(capturer: RTCCameraVideoCapturer) {
        if let adapter = self.sourceAdapter {
            let count = adapter.totalFrameCount
            if count > 0 {
                print("📹 ✅ CAPTURE VERIFICATION: \(count) frames captured after 2 seconds - camera is working!")
            } else {
                print("📹 ⚠️⚠️⚠️ CAPTURE WARNING: 0 frames captured after 2 seconds! Camera may not be delivering frames!")
                print("📹 ⚠️ Checking capturer state...")
                print("📹 Video source: \(self.localVideoSource != nil ? "exists" : "nil")")
                print("📹 Source adapter: \(self.sourceAdapter != nil ? "exists" : "nil")")
                print("📹 Capturer: \(self.videoCapturer != nil ? "exists" : "nil")")
                print("📹 RTCCameraVideoCapturer captureSession: \(String(describing: capturer.captureSession))")
                print("📹 CaptureSession isRunning: \(capturer.captureSession.isRunning)")
                print("📹 CaptureSession isInterrupted: \(capturer.captureSession.isInterrupted)")
                print("📹 CaptureSession inputs: \(capturer.captureSession.inputs.count)")
                print("📹 CaptureSession outputs: \(capturer.captureSession.outputs.count)")
                
                // List inputs and outputs
                for (index, input) in capturer.captureSession.inputs.enumerated() {
                    print("📹   Input[\(index)]: \(input)")
                }
                for (index, output) in capturer.captureSession.outputs.enumerated() {
                    print("📹   Output[\(index)]: \(output)")
                }
            }
        } else {
            print("📹 ⚠️ Source adapter is nil!")
        }
    }
    
    // Public method to restart camera capture if needed
    func restartCameraCapture() {
        print("📹 🔄 RESTARTING CAMERA CAPTURE...")
        guard let capturer = self.videoCapturer as? RTCCameraVideoCapturer else {
            print("📹 ❌ No camera capturer to restart")
            return
        }
        
        // Stop current capture
        capturer.stopCapture()
        
        // Wait a moment then restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startCameraCapture(with: capturer)
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
    private let initTime = Date()
    
    init(videoSource: RTCVideoSource) {
        self.videoSource = videoSource
        super.init()
        print("📹 VideoSourceAdapter initialized at \(initTime)")
        print("📹 VideoSourceAdapter video source: \(videoSource)")
    }
    
    deinit {
        print("📹 ⚠️⚠️⚠️ VideoSourceAdapter DEALLOCATED! Frame count was: \(frameCount)")
    }
    
    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        frameCount += 1
        
        // Log the FIRST frame immediately
        if !hasLoggedFirstFrame {
            hasLoggedFirstFrame = true
            let elapsed = Date().timeIntervalSince(initTime)
            print("📹 🎬⭐ FIRST LOCAL FRAME CAPTURED! Size: \(frame.width)x\(frame.height), \(String(format: "%.2f", elapsed))s after adapter init")
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

