import Foundation

struct Config {
    // ===============================================
    // TOGGLE: Set to true to use VPS server for internet calls
    //         Set to false to use local WiFi connection
    // ===============================================
    static let useVPSServer = true
    
    // ===============================================
    // LOCAL WIFI MODE SETTINGS
    // Use this when both devices are on the same WiFi network
    // Replace with your Mac's local IP address
    // ===============================================
    static let localSignalingServerUrl = "ws://192.168.18.228:8080"
    
    // ===============================================
    // VPS MODE SETTINGS
    // Use this for video calls over the internet (different networks)
    // Replace with your VPS server's public IP or domain
    // Example: "wss://your-vps-domain.com:8080" or "ws://123.45.67.89:8080"
    // Note: Use "wss://" for secure WebSocket if your VPS has SSL configured
    // ===============================================
    // static let vpsSignalingServerUrl = "ws://YOUR_VPS_IP_OR_DOMAIN:8080"
    static let vpsSignalingServerUrl = "ws://ktor.reza.web.id/nodejs/"
    
    // ===============================================
    // COMPUTED PROPERTY: Automatically selects the correct server URL
    // ===============================================
    static var signalingServerUrl: URL {
        let urlString = useVPSServer ? vpsSignalingServerUrl : localSignalingServerUrl
        guard let url = URL(string: urlString) else {
            fatalError("Invalid signaling server URL: \(urlString)")
        }
        return url
    }
    
    // ===============================================
    // STUN/TURN SERVER SETTINGS (Required for NAT traversal)
    // These are already configured in Secrets.swift
    // ===============================================
    static let stunServerUrl = Secrets.stunServerUrl
    static let turnServerUrl = Secrets.turnServerUrl
    static let turnUsername = Secrets.turnUsername
    static let turnPassword = Secrets.turnPassword
}
