# Changelog

Notable changes to Relay, newest first. Each entry says what changed for people using Relay, and what operators must do to deploy it.

## November 2026: Mac App, Multiple Numbers, Real Sign-In

This release turns the native client into a full app for iPhone, iPad, and Mac. It adds real account sign-in, lets one workspace use several phone numbers, and fixes incoming calls on iPhone.

### Highlights

- **Relay for Mac.** The iPhone app now also runs on the Mac through Mac Catalyst. It has a wide-window layout, its own ringing, and Open at Login.
- **Real sign-in.** Sign in with email and password, or with the passkey you already use on the web. The app can be locked with Face ID or Touch ID.
- **Multiple phone numbers.** Attach several numbers you already own in Telnyx. Each number has its own inbox, call history, and voicemail.
- **A Voicemail tab**, and **Ring On** switches that let you choose which devices ring.
- **More reliable iPhone calls.** Answering a call that woke a locked iPhone no longer freezes. Every signed-in device can ring at once.

### Sign-in and security

- **Email and password sign-in in the app.** The iPhone and Mac apps open on a sign-in screen. A successful sign-in returns a revocable device token (`POST /v1/auth/mobile/login`). Attempts are rate limited the same way web sign-in is. The app no longer needs a token added by hand to the Keychain.
- **Passkey sign-in in the app.** **Sign In With Passkey** uses the passkey already saved for the website. The server publishes `/.well-known/apple-app-site-association`, which allows the app to use the site's passkeys. A new endpoint, `POST /v1/auth/mobile/passkey`, verifies the assertion with the same code as web passkey login.
- **Sign Out** asks for confirmation, then revokes the device token on the server. It also removes the device's push registration, so the device stops ringing and stops receiving alerts.
- **Change Password** in Settings → Account sets the password used by the apps and the web.
- **App lock with Face ID or Touch ID.** **Require Face ID** is in Settings → Account and is on by default. Relay asks again only after it has been away for 15 minutes, including when iOS has relaunched it in the background. It uses Face ID or Touch ID first and falls back to the device passcode or Mac password only if that fails. The app now includes the Face ID usage description. Without it, iOS had skipped Face ID and asked for the passcode on every open.
- **Keyboard:** Tab moves between the email and password fields on the Mac.
- An expired or revoked token signs the app out cleanly instead of leaving it stuck.

### Multiple phone numbers ("lines")

- Owners add numbers that are already in the Telnyx account from **Settings → Phone Numbers → Add Number**, with an optional label such as "Work". Labels can be renamed later. Relay does not buy numbers.
- **All Numbers: one combined inbox (the default).** Conversations and voicemail from every number appear in a single list. The round icon at the left of each conversation shows its number's icon and color (voicemail rows show a small badge).
- **An icon for each number.** In Settings → Phone Numbers, tap a number to choose its icon from twelve colored symbols (Work, Home, and so on), and to change its label. A number without a chosen icon shows a numbered circle.
- **Switch to a single number at any time.** Tap the title at the top of Conversations and choose **All Numbers** or one number. With one number chosen, conversations, search, unread dots, the archive, call history, and voicemail follow that number. The app badge still counts every number.
- **Replies come from the right number.** Messages and call-backs from a conversation or voicemail use that conversation's number, even in All Numbers. The Keypad's **From** menu sets the **Default** number used as caller ID for new calls and messages, without leaving All Numbers.
- **You can see which number was called.** When a workspace has more than one number, the incoming-call screen and notifications say "To Work" (or the number). Tapping a notification switches to the matching number before opening the conversation.

### Calls

- **Answering a call that woke the iPhone works.** Previously, a call that arrived by VoIP push showed the call screen, but tapping Answer did nothing. That happened because the call details only arrive after the app tells Telnyx to answer. Answer and Decline now go through the Telnyx SDK's CallKit methods, which wait for the call and then connect it.
- **Every device can ring at once.** Combined with Telnyx **Simultaneous Ringing** (see "Operator steps" below), the iPhone, the Mac app, and web browsers ring together. Whichever device answers first takes the call.
- **Ring On, per device.** Settings → Ring On has separate switches for **iPhone**, **Desktop App** (the Mac app), and **Web Browsers**. The native apps now honor these switches, which they did not before. A switched-off device ignores incoming calls, and a switched-off iPhone also stops receiving call pushes. Outgoing calls still work from every device.
- **Call alerts break through Focus.** Incoming-call alerts are time-sensitive. A missed-call alert replaces the ringing alert for the same call, and old unread alerts are not redelivered as a backlog.

### Voicemail

- **New Voicemail tab.** It lists voicemails for the selected number, newest first. Each entry shows the caller's name (from Relay or your contacts), the time and the length, with **Play** and **Call Back** buttons. Pull to refresh. Tapping a voicemail opens that caller's full history.
- Settings → Voicemail can turn missed-call answering on or off, play the current greeting, and record a new one.

### Mac app

- **Same app, built for Mac** with Mac Catalyst, using its own entitlements file (`Relay/RelayMac.entitlements`).
- **Tabs across the top** instead of a sidebar, so the content gets the full window width.
- **Split views on every tab:**
  - **Conversations:** a scrollable list on the left, with the open thread (messages, calls, voicemail, and the reply box) on the right. The open conversation is highlighted.
  - **Keypad:** your contacts are listed on the left, one row per number with **Message** and **Call** buttons, and the list can be searched by name or digits. The keypad is on the right.
  - **Voicemail:** voicemails on the left, with the caller's history on the right.
  - **Settings:** the setting groups on the left (Phone Numbers, Ring On, Voicemail, Account), with the chosen group on the right.
  - iPad uses the same layouts in a wide window. iPhone keeps its single-column layout.
- **Ringing without CallKit.** Macs have no CallKit call screen and no VoIP push wakeups, so the Mac app plays its own ring and shows its own incoming-call screen. It manages the audio itself.
- **Open at Login** (Settings → Account) starts Relay when you log in. The app also asks macOS not to nap it, so it stays connected and can ring.

### Notifications

- **The Mac app now shows banners for calls and messages.** Relay used to hide the incoming-call banner whenever a call was ringing, and hide message banners for the open conversation, even when its window was behind other apps. It now hides them only when the call screen or that conversation is actually in front.
- **Copy Code for sign-in texts.** When a text looks like a one-time code ("Your verification code is 342583"), the banner is time-sensitive and has a **Copy Code** button. Clicking the banner also copies the code. Order numbers and amounts are ignored.
- **Notification status in Settings.** Settings → Ring On shows whether notifications are on. If they are off, **Turn On Notifications** asks for permission or opens the system notification settings.

### Small improvements

- Server error messages shown in the app read as normal sentences.
- Screen titles, buttons, and section headers use consistent Title Case.
- The camera option for attachments is hidden on devices without a camera (Mac).

### API changes

| Endpoint | Change |
| --- | --- |
| `POST /v1/auth/mobile/login` | New. Email and password sign-in for the apps. Returns a device token. |
| `POST /v1/auth/mobile/passkey` | New. Passkey sign-in for the apps. Takes the challenge from `POST /v1/auth/login/options`. |
| `POST /v1/auth/mobile/logout` | New. Revokes the bearer token and removes that installation's push device. |
| `GET /.well-known/apple-app-site-association` | New. Lists `<TEAM_ID>.<BUNDLE_ID>` under `webcredentials` so the app can use the site's passkeys. |
| `GET /v1/voicemails?line=` | New. Voicemail list for one number, or all numbers. |
| `PUT /v1/phone-numbers/label` | New. Sets a number's `label` and `icon` (an SF Symbol name). Fields left out are kept. Owner or admin. |
| `GET /v1/me` | Now includes `phones` (`id`, `e164`, `label`, `icon`). |
| `GET /v1/settings`, `PUT /v1/settings` | New `receiveDesktop` field. Older clients that leave it out keep the saved value. |
| `GET /v1/conversations`, `/v1/activity`, `/v1/messages`, `/v1/calls`, `/v1/unread`, `POST /v1/conversations/read`, `DELETE /v1/conversations` | Accept `line=<E.164>`. Empty means every number. |
| `POST /v1/messages` | Accepts `from` to choose the sending number. |
| `POST /v1/admin/phone-number` | Allows more than one number per workspace and accepts an optional `label`. |

### Database migrations

Apply these in order with `npx wrangler d1 migrations apply DB --remote`:

- `0014_multiple_lines.sql` adds `phone_numbers.label` and `notification_items.line`. It assigns existing unread items to the workspace's first number.
- `0015_ring_on_desktop.sql` adds `call_preferences.receive_desktop`, which defaults to on.
- `0016_line_icons.sql` adds `phone_numbers.icon`.

### Operator steps

1. **Worker configuration.** Set `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, and `APNS_KEY_ID`, and keep `APNS_PRIVATE_KEY` as a secret. The passkey association file is built from `APNS_TEAM_ID` and `APNS_BUNDLE_ID`. In `wrangler.jsonc`, `assets.run_worker_first` must include `/.well-known/apple-app-site-association`.
2. **Telnyx Credential Connection** (the one holding the WebRTC credential, not the Call Control application):
   - On the **Inbound** tab, turn on **Simultaneous Ringing**. Without it, Telnyx sends each call to only one signed-in device.
   - On the **WebRTC** tab, attach the iOS VoIP push credential (the APNs VoIP certificate and private key). Without it, the iPhone cannot ring while Relay is closed.
3. **Apple Developer portal.** Enable **Associated Domains** on the app's identifier so passkeys work. Set `RELAY_PASSKEY_DOMAIN` in `apps/ios/project.yml` to your Relay hostname. Xcode must be signed in to the team account so automatic signing can add the capability.
4. **Mac builds.** Build with `-destination 'platform=macOS,variant=Mac Catalyst'`. Use the same bundle identifier as iPhone (`DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER` is off).

### Known limits

- The Mac app can only ring while it is running, because macOS has no VoIP push wakeups. Turn on Open at Login to keep it ready.
- After the association file is first deployed, Apple can take up to an hour to let the app use the site's passkeys.
