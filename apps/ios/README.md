# Relay for iPhone

The native SwiftUI client uses the Relay Cloudflare API for conversations, SMS/MMS, voicemail, settings, and device authentication. Voice calls use the Telnyx iOS WebRTC SDK with CallKit and PushKit integration.

## Configure and run

1. Install XcodeGen.
2. Replace `com.example.relay` and `https://relay.example.com` in `project.yml` with your Apple bundle identifier and deployed Relay API origin.
3. Generate the Xcode project:

   ```sh
   xcodegen generate
   open Relay.xcodeproj
   ```

4. Select your Apple development team and enable automatic signing.
5. For production incoming calls, enable Push Notifications and VoIP background mode, then configure the matching APNs VoIP credential in Telnyx.
6. Install a revocable Relay mobile API token using a secure account-linking flow.

The repository contains no Apple team ID, Relay deployment URL, mobile token, Telnyx identifier, or personal signing configuration.
