import Foundation
import WebRTC

protocol SignalingClientDelegate: AnyObject {
    func signalClientDidConnect(_ signalClient: SignalingClient)
    func signalClientDidDisconnect(_ signalClient: SignalingClient)
    func signalClient(_ signalClient: SignalingClient, didReceiveRemoteSdp sdp: RTCSessionDescription)
    func signalClient(_ signalClient: SignalingClient, didReceiveCandidate candidate: RTCIceCandidate)
    func signalClient(_ signalClient: SignalingClient, didReceiveRole role: String)
}

final class SignalingClient: NSObject {
    
    private var webSocket: URLSessionWebSocketTask?
    private let url: URL
    weak var delegate: SignalingClientDelegate?
    
    init(url: URL) {
        self.url = url
    }
    
    func connect() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let webSocket = session.webSocketTask(with: url)
        self.webSocket = webSocket
        webSocket.resume()
        
        // WebSocket is connected when resume is called successfully
        print("🔌 WebSocket connecting to \(url)")
        self.delegate?.signalClientDidConnect(self)
        
        readMessage()
    }
    
    func close() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
    }
    
    func send(sdp rtcSdp: RTCSessionDescription) {
        let typeString: String
        switch rtcSdp.type {
        case .offer: typeString = "offer"
        case .answer: typeString = "answer"
        case .prAnswer: typeString = "prAnswer" // usually not sent this way but good to handle
        @unknown default: return
        }
        
        let message = SignalingMessage(type: typeString, sdp: rtcSdp.sdp, sdpMLineIndex: nil, sdpMid: nil)
        
        do {
            let data = try JSONEncoder().encode(message)
            let socketMessage = URLSessionWebSocketTask.Message.data(data)
            webSocket?.send(socketMessage) { error in
                if let error = error {
                    print("Error sending SDP: \(error)")
                }
            }
        } catch {
            print("Could not encode SDP: \(error)")
        }
    }
    
    func send(candidate rtcIceCandidate: RTCIceCandidate) {
        let message = SignalingMessage(type: "candidate", sdp: rtcIceCandidate.sdp, sdpMLineIndex: rtcIceCandidate.sdpMLineIndex, sdpMid: rtcIceCandidate.sdpMid)
        do {
            let data = try JSONEncoder().encode(message)
            let socketMessage = URLSessionWebSocketTask.Message.data(data)
            webSocket?.send(socketMessage) { error in
                if let error = error {
                    print("Error sending candidate: \(error)")
                }
            }
        } catch {
            print("Could not encode candidate: \(error)")
        }
    }
    
    private func readMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.handleMessage(from: data)
                case .string(let string):
                    if let data = string.data(using: .utf8) {
                        self.handleMessage(from: data)
                    }
                @unknown default:
                    print("Unknown message type")
                }
                self.readMessage() // Keep listening
            case .failure(let error):
                print("WebSocket receive error: \(error)")
                self.delegate?.signalClientDidDisconnect(self)
            }
        }
    }
    
    private func handleMessage(from data: Data) {
        do {
            let message = try JSONDecoder().decode(SignalingMessage.self, from: data)
            
            if message.type == "role", let role = message.role {
                print("📨 Received role assignment: \(role)")
                self.delegate?.signalClient(self, didReceiveRole: role)
            } else if message.type == "offer" || message.type == "answer", let sdp = message.sdp {
                let rtcSdp = RTCSessionDescription(type: message.type == "offer" ? .offer : .answer, sdp: sdp)
                self.delegate?.signalClient(self, didReceiveRemoteSdp: rtcSdp)
            } else if message.type == "candidate", let sdp = message.sdp, let sdpMLineIndex = message.sdpMLineIndex, let sdpMid = message.sdpMid {
                let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
                self.delegate?.signalClient(self, didReceiveCandidate: candidate)
            }
        } catch {
            print("Could not decode message: \(error)")
        }
    }
}

struct SignalingMessage: Codable {
    let type: String
    let sdp: String?
    let sdpMLineIndex: Int32?
    let sdpMid: String?
    let role: String?       // For role assignment messages
    let clientId: Int?      // For role assignment messages
    
    // Custom initializer with default nil values for role and clientId
    init(type: String, sdp: String?, sdpMLineIndex: Int32?, sdpMid: String?, role: String? = nil, clientId: Int? = nil) {
        self.type = type
        self.sdp = sdp
        self.sdpMLineIndex = sdpMLineIndex
        self.sdpMid = sdpMid
        self.role = role
        self.clientId = clientId
    }
}

// MARK: - URLSessionWebSocketDelegate
extension SignalingClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ WebSocket connected!")
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("❌ WebSocket closed with code: \(closeCode)")
        self.delegate?.signalClientDidDisconnect(self)
    }
}
