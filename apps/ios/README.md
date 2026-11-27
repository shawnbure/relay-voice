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
6. Sign in in the app with the Relay account email and password, or tap **Sign In With Passkey** to use the passkey saved for the website. Either returns a revocable device token (`POST /v1/auth/mobile/login` or `POST /v1/auth/mobile/passkey`); Sign Out in Settings revokes it (`POST /v1/auth/mobile/logout`).
7. For passkeys, set `RELAY_PASSKEY_DOMAIN` in `project.yml` to your Relay hostname and enable **Associated Domains** on the App ID. The Worker serves `/.well-known/apple-app-site-association` from `APNS_TEAM_ID` and `APNS_BUNDLE_ID`; Apple can take up to an hour to pick it up after the first deploy.

## App lock

**Require Face ID** (Settings → Account, on by default) locks a signed-in app. It asks again only after 15 minutes away, including when iOS relaunched the app in the meantime, and uses Face ID or Touch ID before falling back to the device passcode or Mac password.

## Calls and Ring On

Settings → Ring On has separate switches for **iPhone**, **Desktop App** (the Mac app), and **Web Browsers**. A switched-off device ignores incoming calls; a switched-off iPhone also stops taking VoIP pushes. Outgoing calls work everywhere.

For every device to ring together, turn on **Simultaneous Ringing** on the Telnyx Credential Connection's Inbound tab. For iPhones to ring while Relay is closed, attach the APNs VoIP push credential on that connection's WebRTC tab. Calls that wake the iPhone by push are answered and declined through the Telnyx SDK (`answerFromCallkit` / `endCallFromCallkit`), which waits for the call's invite before connecting.

## Voicemail

The Voicemail tab lists voicemails for the selected number (`GET /v1/voicemails?line=`), with play and call-back buttons. Settings → Voicemail turns missed-call answering on or off and records the greeting.

The repository contains no Apple team ID, Relay deployment URL, mobile token, Telnyx identifier, or personal signing configuration.

## Multiple numbers

A workspace can have several numbers ("lines"). Owners add numbers already in the Telnyx account from Settings → Phone Numbers (`POST /v1/admin/phone-number`), optionally with a label. Each line has its own inbox: the conversation title switches lines, and conversations, unread dots, replies, and keypad caller ID follow the selected line (API `line=` query parameter / `from` field). The app badge counts every line. Apply API migrations `0014_multiple_lines.sql` and `0015_ring_on_desktop.sql`.

## Mac

The Mac app is the same target built with Mac Catalyst (`platform=macOS,variant=Mac Catalyst`) and uses `Relay/RelayMac.entitlements`. Macs have no CallKit call screen or VoIP push wakeups, so the Mac app handles and rings for calls itself while it is running; message, missed-call, and voicemail alerts still arrive by APNs. Turn on **Open at Login** in Settings → Account to keep it running; it also opts out of App Nap.

Tabs sit across the top, and in a wide window (Mac or iPad) every tab is a split view: conversations beside the open thread, contacts (with Call and Message buttons) beside the keypad, voicemail beside the caller's history, and setting groups beside their options. iPhone keeps the single-column layout.

## Message, missed-call, and voicemail notifications

The app registers a normal APNs token independently of its Telnyx VoIP token. Configure `APNS_KEY_ID`, `APNS_TEAM_ID`, and `APNS_BUNDLE_ID` on the Worker, and upload the Apple `.p8` key with `wrangler secret put APNS_PRIVATE_KEY < /private/path/AuthKey.p8`. Never commit the key. Debug builds register with the APNs sandbox; distribution builds use production. The signing entitlement and Apple key must support the matching environment and bundle ID.

Apply API migration `0009_push_notifications.sql`. Incoming SMS/MMS, unanswered calls, and ready voicemail create server unread items and APNs alert deliveries. A one-minute Worker cron retries transient failures; invalid device tokens are removed. Reading on either interface clears shared workspace unread items and sends a badge-only update. Archiving also marks a thread read; new activity returns it to the inbox. Historical activity is not backfilled as unread.

iOS suspends background sockets. APNs alerts and badges do not require the app to stay connected; CallKit/PushKit handles live incoming-call wakeups through Telnyx separately. Users must allow notifications and badges in iOS Settings. APNs acceptance is not proof the alert appeared: device connectivity, Focus, and notification permissions affect presentation.
