import Foundation

struct Config {
    // IMPORTANT: Replace this with your Mac's IP address if running on a real device.
    // e.g., "ws://192.168.1.10:8080"
    static let signalingServerUrl = URL(string: "ws://192.168.18.228:8080")!
    
    static let stunServerUrl = "stun:turn-dev.eazy.co.id:3478"
    static let turnServerUrl = "turn:turn-dev.eazy.co.id:3478"
    static let turnUsername = "dummy_user"
    static let turnPassword = "dummy_pass"
}
