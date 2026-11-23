# Relay for iPhone, iPad, and Mac

The native SwiftUI client (also built for Mac with Mac Catalyst) uses the Relay Cloudflare API for conversations, SMS/MMS, voicemail, settings, and device authentication. Voice calls use the Telnyx iOS WebRTC SDK with CallKit and PushKit integration.

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
6. Sign in in the app with the Relay account email and password. The app receives a revocable device token (`POST /v1/auth/mobile/login`); Sign Out in Settings revokes it.

The repository contains no Apple team ID, Relay deployment URL, mobile token, Telnyx identifier, or personal signing configuration.

## Multiple numbers

A workspace can have several numbers ("lines"). Owners add numbers already in the Telnyx account from Settings → Phone Numbers (`POST /v1/admin/phone-number`), optionally with a label. Each line has its own inbox: the conversation title switches lines, and conversations, unread dots, replies, and keypad caller ID follow the selected line (API `line=` query parameter / `from` field). The app badge counts every line. Apply API migration `0014_multiple_lines.sql`.

## Mac

The Mac app is the same target built with Mac Catalyst (`platform=macOS,variant=Mac Catalyst`) and uses `Relay/RelayMac.entitlements`. Macs have no CallKit call screen or VoIP push wakeups, so the Mac app handles and rings for calls itself while it is running; message, missed-call, and voicemail alerts still arrive by APNs.

## Message, missed-call, and voicemail notifications

The app registers a normal APNs token independently of its Telnyx VoIP token. Configure `APNS_KEY_ID`, `APNS_TEAM_ID`, and `APNS_BUNDLE_ID` on the Worker, and upload the Apple `.p8` key with `wrangler secret put APNS_PRIVATE_KEY < /private/path/AuthKey.p8`. Never commit the key. Debug builds register with the APNs sandbox; distribution builds use production. The signing entitlement and Apple key must support the matching environment and bundle ID.

Apply API migration `0009_push_notifications.sql`. Incoming SMS/MMS, unanswered calls, and ready voicemail create server unread items and APNs alert deliveries. A one-minute Worker cron retries transient failures; invalid device tokens are removed. Reading on either interface clears shared workspace unread items and sends a badge-only update. Archiving also marks a thread read; new activity returns it to the inbox. Historical activity is not backfilled as unread.

iOS suspends background sockets. APNs alerts and badges do not require the app to stay connected; CallKit/PushKit handles live incoming-call wakeups through Telnyx separately. Users must allow notifications and badges in iOS Settings. APNs acceptance is not proof the alert appeared: device connectivity, Focus, and notification permissions affect presentation.
