import SwiftUI
import WebRTC

// Legacy VideoView - not actively used, see VideoViewWrapper in ContentView.swift
struct VideoView: UIViewRepresentable {
    
    let videoRenderer: RTCMTLVideoView = {
        let renderer = RTCMTLVideoView(frame: .zero)
        renderer.videoContentMode = .scaleAspectFill
        return renderer
    }()
    
    // Just a container to hold the view
    func makeUIView(context: Context) -> RTCMTLVideoView {
        return videoRenderer
    }
    
    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        // No updates needed typically, constraints are handled by SwiftUI layout
    }
}
