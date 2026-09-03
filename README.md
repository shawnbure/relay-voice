# Relay Voice

Relay is a self-hosted communications inbox and softphone built with Telnyx, Cloudflare Workers, React, and SwiftUI. It keeps SMS, MMS, calls, and voicemail in one timeline per phone number and provides both a responsive web client and a native iPhone client.

> [!IMPORTANT]
> Relay is an early-stage project, not a turnkey telephone service. Operators are responsible for their Telnyx account, messaging registration, emergency-calling obligations, abuse prevention, data retention, and regulatory compliance. Do not rely on Relay for emergency calls.

## Features

- Unified call, SMS, MMS, and voicemail history
- Browser calling through the Telnyx WebRTC SDK
- Native iOS calling with SwiftUI, CallKit, PushKit, and DTMF
- Passkey authentication and revocable iOS device credentials
- Real-time updates over Cloudflare Durable Object WebSockets
- Multi-tenant D1 schema and R2 media storage

## Repository layout

```text
apps/api    Cloudflare Worker API, Telnyx webhooks, D1 migrations
apps/web    React/Vite progressive web application
apps/ios    Native SwiftUI iPhone application
docs        Architecture and design notes
```

## Prerequisites

- Node.js 22 or newer
- Cloudflare Workers, D1, R2, and a public HTTPS hostname
- A Telnyx API key, webhook public key, phone number, messaging profile, outbound voice profile, and Credential Connection
- Xcode 16 or newer for iOS
- Apple Developer Program membership for production PushKit/APNs delivery

## Local development

```sh
git clone https://github.com/OWNER/relay-voice.git
cd relay-voice
npm install
cp apps/api/.dev.vars.example apps/api/.dev.vars
cd apps/api
npx wrangler d1 migrations apply DB --local
cd ../..
```

Replace the examples in `apps/api/.dev.vars`, then run the API and web client in separate terminals:

```sh
npm run dev:api
npm run dev
```

The web client runs at `http://localhost:5173`; the Worker runs at `http://localhost:8787`. The local bearer-token bypass only works with `ENVIRONMENT=development`. Never commit `.dev.vars`.

## Deploy to Cloudflare

1. Authenticate and create storage:

   ```sh
   npx wrangler login
   cd apps/api
   npx wrangler d1 create relay-voice
   npx wrangler r2 bucket create relay-voice-media
   ```

2. Replace the all-zero `database_id` in `apps/api/wrangler.jsonc` with the returned D1 ID.
3. Set `ENVIRONMENT` to `production` and `WEB_ORIGIN` to your public HTTPS origin. Keep `workers_dev: true` or configure your own Cloudflare custom domain.
4. Store secrets interactively:

   ```sh
   npx wrangler secret put TELNYX_API_KEY
   npx wrangler secret put TELNYX_PUBLIC_KEY
   ```

5. Apply migrations and deploy:

   ```sh
   npx wrangler d1 migrations apply DB --remote
   cd ../..
   npm run build
   npm run deploy -w @relay/api
   ```

6. Open the deployed site and create the owner passkey. Public registration closes after the first passkey is registered.

See Cloudflare's current documentation for [D1 creation](https://developers.cloudflare.com/d1/wrangler-commands/), [R2 bindings](https://developers.cloudflare.com/r2/get-started/workers-api/), and [custom domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/).

## Configure Telnyx

Relay stores provider resource IDs in D1—not in source code.

1. Buy or port a Telnyx number with voice and messaging capabilities.
2. Create a messaging profile, assign the number, and configure this webhook:

   ```text
   https://relay.example.com/v1/webhooks/telnyx
   ```

3. Create an outbound voice profile, Credential Connection, and telephony credential.
4. Configure voice and messaging call-control events to use the same webhook.
5. Insert the resulting IDs after creating the owner account:

   ```sql
   INSERT INTO phone_numbers
     (id, tenant_id, e164, telnyx_number_id, messaging_profile_id, connection_id)
   VALUES
     ('phone_1', '<TENANT_ID>', '+15551234567', '<TELNYX_NUMBER_ID>',
      '<MESSAGING_PROFILE_ID>', '<VOICE_APPLICATION_OR_CONNECTION_ID>');

   INSERT INTO telephony_credentials
     (id, tenant_id, user_id, telnyx_credential_id)
   VALUES
     ('credential_1', '<TENANT_ID>', '<USER_ID>', '<TELNYX_TELEPHONY_CREDENTIAL_ID>');
   ```

Find the generated owner IDs with:

```sh
cd apps/api
npx wrangler d1 execute DB --remote --command \
  "SELECT tenant_id, user_id FROM memberships WHERE role='owner';"
```

Telnyx requirements differ by region and number type. Follow the current [Telnyx documentation](https://developers.telnyx.com/) before carrying production traffic.

## Run the iOS client

1. Replace `com.example.relay` in `apps/ios/project.yml` with your own bundle identifier.
2. Replace the example `RELAY_API_BASE_URL` with your deployed HTTPS origin.
3. Generate and open the project:

   ```sh
   cd apps/ios
   xcodegen generate
   open Relay.xcodeproj
   ```

4. Select your Apple development team, enable automatic signing, connect an iPhone, and run.
5. Create a mobile token with authenticated `POST /v1/mobile/token`, then add it to the app Keychain through your own secure onboarding flow.

The current iOS client is owner-oriented and does not yet provide a public account-linking screen. Production background ringing requires the Push Notifications capability, VoIP background mode, an APNs VoIP credential, and matching Telnyx push configuration. CallKit's incoming-call interface is required for PushKit VoIP wakeups.

## Verify changes

```sh
npm test
npm run typecheck
npm run build
```

## Security and contributions

Read [SECURITY.md](SECURITY.md) before exposing Relay to the internet. Issues and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Relay is available under the [MIT License](LICENSE).
