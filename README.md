# Video Call App Walkthrough

![Video Call App Preview](videocall.jpeg)

## 1. Start the Signaling Server

You need to run the signaling server on your computer (which acts as the server for both devices).

1.  Open Terminal.
2.  Navigate to the server directory:
    ```bash
    cd ~/VideoCallAppSwiftUI/server
    ```
3.  Install dependencies (if you haven't already):
    ```bash
    npm install
    ```
4.  Start the server:
    ```bash
    node index.js
    ```
    You should see: `Signaling server started on port 8080`.

## 2. Configure the iOS App

1.  Open Terminal and navigate to the project directory:
    ```bash
    cd ~/VideoCallAppSwiftUI
    ```
2.  **Install CocoaPods** (if not installed):
    ```bash
    sudo gem install cocoapods
    ```
3.  **Install WebRTC Dependency**:
    ```bash
    pod install
    ```
4.  **Open the Workspace** (NOT the .xcodeproj):
    ```bash
    open VideoCallAppGravi1.xcworkspace
    ```
5.  **Add Permissions**:
    - Open `Info.plist`.
    - Add `Privacy - Camera Usage Description`: "We need camera access for video calls."
    - Add `Privacy - Microphone Usage Description`: "We need microphone access for video calls."
    - (Optional) If you want to run on local network without HTTPS/WSS, you might need `App Transport Security Settings` -> `Allow Arbitrary Loads` = YES.
6.  **Update Config**:
    - Open [VideoCallAppGravi1/Config.swift](file:///~/VideoCallAppGravi1/Config.swift).
    - Find your computer's local IP address (e.g., Option+Click WiFi icon).
    - Update `static let signalingServerUrl = URL(string: "ws://YOUR_IP_ADDRESS:8080")!`.

## 3. Run on Devices

1.  Connect "iPhone A" to your Mac.
2.  Select it as the run destination in Xcode.
3.  Run the app. Accept camera/mic permissions.
4.  Connect "iPhone B" to your Mac.
5.  Select it as the run destination.
6.  Run the app. Accept permissions.

## 4. Make a Call

1.  On both phones, tap **"Connect Signaling"**. You should see "Connected to Signaling" at the bottom.
2.  On **iPhone A**, tap **"Offer"**.
3.  You should see "Sent Offer".
4.  **iPhone B** automatically receives the offer, sends an answer, and the connection starts.
5.  You should see the local video on the left and the remote video on the right.

> [!NOTE]
> If video doesn't appear immediately, check the console logs in Xcode for any ICE connection failures or network issues. Ensure both devices are on the same WiFi network as the server.
