//
//  ContentView.swift
//  VideoCallAppGravi1
//
//  Created by Luthfi Abdurrahim on 02/01/26.
//

import SwiftUI
import WebRTC
import AVFoundation

struct ContentView: View {
    
    @StateObject private var viewModel = MainViewModel()
    
    var body: some View {
        VStack(spacing: 16) {
            // Status bar at top
            VStack(spacing: 4) {
                Text(viewModel.statusMessage)
                    .font(.headline)
                    .foregroundColor(viewModel.isConnected ? .green : .orange)
                
                if viewModel.hasRemoteVideo {
                    Text("📹 Remote video active")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            .padding(.top)
            
            // Video views
            HStack(spacing: 12) {
                VStack {
                    Text("Local")
                        .font(.caption)
                        .foregroundColor(.gray)
                    VideoViewWrapper(renderer: viewModel.localRenderer, name: "LOCAL", onViewReady: {
                        viewModel.attachLocalRenderer()
                    })
                        .frame(width: 150, height: 200)
                        .background(Color.black)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.blue, lineWidth: 2)
                        )
                }
                
                VStack {
                    Text("Remote")
                        .font(.caption)
                        .foregroundColor(.gray)
                    VideoViewWrapper(renderer: viewModel.remoteRenderer, name: "REMOTE")
                        .frame(width: 150, height: 200)
                        .background(Color.black)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(viewModel.hasRemoteVideo ? Color.green : Color.gray, lineWidth: 2)
                        )
                }
            }
            .padding()
            
            Spacer()
            
            // Control buttons
            VStack(spacing: 12) {
                HStack(spacing: 20) {
                    Button(action: { viewModel.connectSignaling() }) {
                        HStack {
                            Image(systemName: "wifi")
                            Text("Connect")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(viewModel.hasSignaling ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .disabled(viewModel.hasSignaling)
                    
                    if viewModel.hasSignaling {
                        Button(action: { viewModel.offer() }) {
                            HStack {
                                Image(systemName: "phone.arrow.up.right.fill")
                                Text("Call")
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                    }
                }
                
                Text("Server: \(Config.signalingServerUrl.absoluteString)")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            .padding(.bottom)
        }
        .onAppear {
            viewModel.requestPermissionsAndConnect()
        }
    }
}

// Wrapper using UIViewControllerRepresentable for better Metal view handling in SwiftUI
// RTCMTLVideoView works better when hosted in a proper UIViewController
struct VideoViewWrapper: UIViewControllerRepresentable {
    let renderer: RTCMTLVideoView
    let onViewReady: (() -> Void)?
    @Binding var hasFrames: Bool
    let name: String
    
    init(renderer: RTCMTLVideoView, name: String = "Unknown", onViewReady: (() -> Void)? = nil, hasFrames: Binding<Bool> = .constant(false)) {
        self.renderer = renderer
        self.name = name
        self.onViewReady = onViewReady
        self._hasFrames = hasFrames
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = VideoHostingViewController()
        vc.renderer = renderer
        vc.onViewReady = onViewReady
        vc.coordinator = context.coordinator
        context.coordinator.viewController = vc
        renderer.delegate = context.coordinator
        print("📺 VideoViewWrapper[\(name)]: makeUIViewController called")
        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Force layout when SwiftUI updates
        uiViewController.view.setNeedsLayout()
        uiViewController.view.layoutIfNeeded()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer, hasFrames: $hasFrames, name: name)
    }
    
    class Coordinator: NSObject, RTCVideoViewDelegate {
        private weak var renderer: RTCMTLVideoView?
        weak var viewController: VideoHostingViewController?
        private var hasFrames: Binding<Bool>
        private var hasReceivedFirstFrame = false
        private let rendererName: String
        private var frameCount = 0
        private var lastLogTime = Date()
        
        init(renderer: RTCMTLVideoView, hasFrames: Binding<Bool>, name: String = "Unknown") {
            self.renderer = renderer
            self.hasFrames = hasFrames
            self.rendererName = name
            super.init()
            print("📺 Coordinator created for \(name) renderer")
        }
        
        func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            frameCount += 1
            
            // Log first frame immediately
            if !hasReceivedFirstFrame {
                hasReceivedFirstFrame = true
                print("📺 🎉🎉🎉 [\(rendererName)] FIRST VIDEO FRAME RECEIVED! Size: \(size.width)x\(size.height)")
            }
            
            // Log every 30 frames (approximately once per second)
            if frameCount % 30 == 0 {
                let now = Date()
                let elapsed = now.timeIntervalSince(lastLogTime)
                let fps = elapsed > 0 ? 30.0 / elapsed : 0
                print("📺 [\(rendererName)] RENDERING: \(frameCount) frames, ~\(Int(fps)) fps, size: \(size.width)x\(size.height)")
                lastLogTime = now
            }

            DispatchQueue.main.async { [weak self] in
                self?.hasFrames.wrappedValue = true
                guard let renderer = self?.renderer else { return }

                // Force Metal view to redraw
                renderer.setNeedsLayout()
                renderer.layoutIfNeeded()
                renderer.setNeedsDisplay()

                // Update Metal layer drawable size to match video aspect ratio
                if let metalLayer = renderer.layer as? CAMetalLayer {
                    let scale = UIScreen.main.scale
                    metalLayer.drawableSize = CGSize(width: renderer.bounds.width * scale,
                                                     height: renderer.bounds.height * scale)
                    metalLayer.contentsScale = scale
                }
            }
        }
    }
}

// UIViewController that properly hosts the RTCMTLVideoView
class VideoHostingViewController: UIViewController {
    var renderer: RTCMTLVideoView?
    var onViewReady: (() -> Void)?
    weak var coordinator: VideoViewWrapper.Coordinator?
    private var hasCalledOnViewReady = false
    private var refreshTimer: Timer?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isOpaque = true
        
        guard let renderer = renderer else { return }
        
        renderer.translatesAutoresizingMaskIntoConstraints = false
        renderer.backgroundColor = .black
        renderer.isOpaque = true
        view.addSubview(renderer)
        
        NSLayoutConstraint.activate([
            renderer.topAnchor.constraint(equalTo: view.topAnchor),
            renderer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            renderer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            renderer.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        // Properly configure Metal layer for rendering
        if let metalLayer = renderer.layer as? CAMetalLayer {
            let scale = UIScreen.main.scale
            metalLayer.contentsScale = scale
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = false
            metalLayer.presentsWithTransaction = false
            print("📺 Configured Metal layer in viewDidLoad, scale: \(scale)")
        }
        
        print("📺 VideoHostingViewController: viewDidLoad, added renderer to view hierarchy")
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // Update Metal layer drawable size to match current bounds with proper scaling
        if let renderer = renderer,
           let metalLayer = renderer.layer as? CAMetalLayer {
            let scale = UIScreen.main.scale
            let drawableSize = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
            if metalLayer.drawableSize != drawableSize {
                metalLayer.drawableSize = drawableSize
                print("📺 Updated Metal drawable size to: \(drawableSize)")
            }
        }
        
        // Only call onViewReady once, after we have a valid frame
        if !hasCalledOnViewReady && view.frame.width > 0 && view.frame.height > 0 && view.frame.width < 300 {
            hasCalledOnViewReady = true
            print("📺 VideoHostingViewController: Calling onViewReady callback with frame: \(view.frame)")
            onViewReady?()
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        print("📺 VideoHostingViewController: viewDidAppear, frame: \(view.frame)")
        
        // Force layout when view appears
        forceRefresh()
        
        // Ensure onViewReady is called
        if !hasCalledOnViewReady {
            hasCalledOnViewReady = true
            print("📺 VideoHostingViewController: Calling onViewReady from viewDidAppear")
            onViewReady?()
        }
        
        // Start a refresh timer to periodically force Metal to render
        // This helps work around Metal rendering issues on some devices
        startRefreshTimer()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    func forceRefresh() {
        renderer?.setNeedsLayout()
        renderer?.layoutIfNeeded()
        renderer?.setNeedsDisplay()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }
    
    private func startRefreshTimer() {
        // Refresh every 100ms for the first 5 seconds to ensure Metal renders
        var refreshCount = 0
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            self?.forceRefresh()
            refreshCount += 1
            if refreshCount > 50 { // Stop after 5 seconds
                timer.invalidate()
                print("📺 Stopped refresh timer after \(refreshCount) refreshes")
            }
        }
    }
}

class MainViewModel: ObservableObject {
    
    @Published var statusMessage: String = "Initializing..."
    @Published var hasSignaling: Bool = false
    @Published var hasRemoteVideo: Bool = false
    @Published var isConnected: Bool = false
    
    // Store remote track reference to prevent deallocation
    private var remoteVideoTrack: RTCVideoTrack?
    
    private let signalClient: SignalingClient
    private let webRTCClient: WebRTCClient
    
    // Renderers - using RTCMTLVideoView (Metal) hosted in UIViewController for proper rendering
    let localRenderer: RTCMTLVideoView = {
        let frame = CGRect(x: 0, y: 0, width: 150, height: 200)
        let view = RTCMTLVideoView(frame: frame)
        view.videoContentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.backgroundColor = .black
        
        // CRITICAL: Set the drawable size on Metal layer for proper rendering
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.drawableSize = frame.size
            metalLayer.contentsScale = UIScreen.main.scale
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = false
            print("📺 Configured Metal layer for local renderer: \(metalLayer.drawableSize)")
        }
        
        // CRITICAL: Set rotation override to ensure proper orientation
        view.rotationOverride = NSNumber(value: 0)
        
        print("📺 Created LOCAL RTCMTLVideoView renderer with frame: \(frame)")
        return view
    }()
    
    let remoteRenderer: RTCMTLVideoView = {
        let frame = CGRect(x: 0, y: 0, width: 150, height: 200)
        let view = RTCMTLVideoView(frame: frame)
        view.videoContentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.backgroundColor = .black
        
        // CRITICAL: Set the drawable size on Metal layer for proper rendering
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.drawableSize = frame.size
            metalLayer.contentsScale = UIScreen.main.scale
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = false
            print("📺 Configured Metal layer for remote renderer: \(metalLayer.drawableSize)")
        }
        
        // CRITICAL: Set rotation override to ensure proper orientation
        view.rotationOverride = NSNumber(value: 0)
        
        print("📺 Created REMOTE RTCMTLVideoView renderer with frame: \(frame)")
        return view
    }()
    
    init() {
        print("🚀 MainViewModel initializing...")
        self.signalClient = SignalingClient(url: Config.signalingServerUrl)
        self.webRTCClient = WebRTCClient()
        
        // Setup delegates
        self.signalClient.delegate = self
        self.webRTCClient.delegate = self
        
        // NOTE: Do NOT attach renderer here - wait until view is in hierarchy
        // The onViewReady callback will call attachLocalRenderer()
        
        self.statusMessage = "Ready"
    }
    
    // Called when the local video view is ready (in the view hierarchy)
    func attachLocalRenderer() {
        print("📺 attachLocalRenderer called")
        self.webRTCClient.renderLocalVideo(to: self.localRenderer)
        
        // Start camera capture now that the view is ready
        print("📹 View is ready, starting camera capture...")
        self.webRTCClient.startCapture()
    }
    
    func requestPermissionsAndConnect() {
        print("🔐 Requesting camera and microphone permissions...")
        
        // Request camera permission
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            print("📹 Camera permission: \(granted ? "✅ granted" : "❌ denied")")
            
            // Request microphone permission
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                print("🎤 Microphone permission: \(micGranted ? "✅ granted" : "❌ denied")")
                
                // Connect to signaling after permissions
                DispatchQueue.main.async {
                    if granted && micGranted {
                        self?.statusMessage = "Permissions granted. Connecting..."
                        self?.connectSignaling()
                    } else {
                        self?.statusMessage = "⚠️ Please grant camera & mic permissions"
                    }
                }
            }
        }
    }
    
    func connectSignaling() {
        print("🔌 Connecting to signaling server...")
        self.signalClient.connect()
        self.statusMessage = "Connecting..."
    }
    
    func offer() {
        print("📞 Creating offer...")
        self.statusMessage = "Creating offer..."
        self.webRTCClient.offer { [weak self] sdp in
            print("📤 Sending offer SDP...")
            self?.signalClient.send(sdp: sdp)
            DispatchQueue.main.async {
                self?.statusMessage = "Offer sent, waiting for answer..."
            }
        }
    }
    
    func answer() {
        // Answer is automatically generated when receiving an offer
    }
}

extension MainViewModel: SignalingClientDelegate {
    func signalClientDidConnect(_ signalClient: SignalingClient) {
        print("✅ Connected to signaling server")
        DispatchQueue.main.async {
            self.statusMessage = "Connected to Signaling"
            self.hasSignaling = true
        }
    }
    
    func signalClientDidDisconnect(_ signalClient: SignalingClient) {
        print("❌ Disconnected from signaling server")
        DispatchQueue.main.async {
            self.statusMessage = "Disconnected from Signaling"
            self.hasSignaling = false
            self.isConnected = false
        }
    }
    
    func signalClient(_ signalClient: SignalingClient, didReceiveRemoteSdp sdp: RTCSessionDescription) {
        print("📥 Received remote SDP: \(sdp.type == .offer ? "OFFER" : "ANSWER")")
        
        DispatchQueue.main.async {
            self.statusMessage = "Received \(sdp.type == .offer ? "offer" : "answer")..."
        }
        
        self.webRTCClient.set(remoteSdp: sdp) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ Failed to set remote description: \(error)")
                DispatchQueue.main.async {
                    self.statusMessage = "Error: \(error.localizedDescription)"
                }
                return
            }
            
            print("✅ Remote SDP set successfully")
            
            // If we received an offer (and didn't ignore it), we should answer
            if sdp.type == .offer {
                print("📞 Creating answer...")
                self.webRTCClient.answer { [weak self] answerSdp in
                    print("📤 Sending answer SDP...")
                    self?.signalClient.send(sdp: answerSdp)
                    DispatchQueue.main.async {
                        self?.statusMessage = "Answer sent"
                    }
                }
            }
        }
    }
    
    func signalClient(_ signalClient: SignalingClient, didReceiveCandidate candidate: RTCIceCandidate) {
        print("📥 Received remote ICE candidate")
        self.webRTCClient.set(remoteCandidate: candidate)
    }
    
    func signalClient(_ signalClient: SignalingClient, didReceiveRole role: String) {
        print("🎭 Received role assignment: \(role)")
        let isPolite = (role == "polite")
        self.webRTCClient.isPolite = isPolite
        
        DispatchQueue.main.async {
            self.statusMessage = "Role: \(role.uppercased())"
            print("🎭 WebRTCClient isPolite set to: \(isPolite)")
        }
    }
}

extension MainViewModel: WebRTCClientDelegate {
    func webRTCClient(_ client: WebRTCClient, didDiscoverLocalCandidate candidate: RTCIceCandidate) {
        print("📤 Sending local ICE candidate")
        self.signalClient.send(candidate: candidate)
    }
    
    func webRTCClient(_ client: WebRTCClient, didChangeConnectionState state: RTCIceConnectionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected, .completed:
                self.statusMessage = "🎉 WebRTC Connected!"
                self.isConnected = true
            case .disconnected:
                self.statusMessage = "WebRTC Disconnected"
                self.isConnected = false
            case .failed:
                self.statusMessage = "❌ WebRTC Failed"
                self.isConnected = false
            case .closed:
                self.statusMessage = "WebRTC Closed"
                self.isConnected = false
            case .checking:
                self.statusMessage = "Connecting peers..."
            case .new, .count:
                break
            @unknown default:
                break
            }
        }
    }
    
    func webRTCClient(_ client: WebRTCClient, didReceiveData data: Data) {
        print("📊 Received data: \(data.count) bytes")
    }
    
    func webRTCClient(_ client: WebRTCClient, didReceiveRemoteVideoTrack track: RTCVideoTrack) {
        print("📺 🎉 REMOTE VIDEO TRACK CALLBACK - Attaching to renderer!")
        print("📺 Track ID: \(track.trackId)")
        print("📺 Track enabled: \(track.isEnabled)")
        print("📺 Track state (should be live): \(track.readyState.rawValue)")
        
        // Store strong reference to track to prevent deallocation
        self.remoteVideoTrack = track
        
        DispatchQueue.main.async {
            // First remove any existing renderer to avoid issues
            track.remove(self.remoteRenderer)
            
            // Ensure track is enabled
            track.isEnabled = true
            
            // Log renderer state before adding
            print("📺 Remote renderer frame before add: \(self.remoteRenderer.frame)")
            print("📺 Remote renderer bounds: \(self.remoteRenderer.bounds)")
            print("📺 Remote renderer is in view hierarchy: \(self.remoteRenderer.superview != nil)")
            
            // Add the renderer to the track
            track.add(self.remoteRenderer)
            self.hasRemoteVideo = true
            print("✅ Remote renderer attached successfully!")
            
            // Force layout refresh multiple times with delays
            for delay in [0.0, 0.1, 0.5, 1.0, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self else { return }
                    self.remoteRenderer.setNeedsLayout()
                    self.remoteRenderer.layoutIfNeeded()
                    self.remoteRenderer.setNeedsDisplay()
                    
                    // Also update Metal layer
                    if let metalLayer = self.remoteRenderer.layer as? CAMetalLayer {
                        let scale = UIScreen.main.scale
                        let size = CGSize(width: self.remoteRenderer.bounds.width * scale,
                                          height: self.remoteRenderer.bounds.height * scale)
                        if size.width > 0 && size.height > 0 {
                            metalLayer.drawableSize = size
                        }
                    }
                    
                    if delay == 2.0 {
                        print("📺 Completed all delayed layout refreshes")
                    }
                }
            }
            print("📺 Scheduled multiple layout refresh cycles")
        }
    }
}
